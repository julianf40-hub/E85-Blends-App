// 85Blends 2.4.0 — Referral client API HTTP receiver.
//
// Deno-specific entry point (Deno.serve, Deno.env, `npm:` imports via the shared modules it pulls
// in) — NOT executable/testable under Node, same as revenuecat-webhook/index.ts. Deliberately
// thin: every decision with real logic to get right (request validation, next-milestone math,
// error mapping, response shape) lives in supabase/functions/_shared/*.ts, each unit-tested under
// Node — see each module's own header comment and supabase/functions/_shared/*.test.ts.
//
// THE ONLY CLIENT PATH into the private.referral_* foundation (private.referral_participants /
// referral_participant_aliases / referral_attributions / referral_rewards, plus this revision's
// own private.referral_client_installations / referral_apply_attempts) — the iOS app never talks
// to any of those tables/functions directly, and none of them are exposed through PostgREST (see
// supabase/README.md). Reaches Postgres the same way revenuecat-webhook already does: a direct
// SUPABASE_DB_URL connection (see _shared/database.ts's createDatabaseClient, reused as-is here),
// not the PostgREST Data API.
//
// AUTHENTICATION — two independent gates, both required on every request:
//   A. a valid client-safe Supabase API key (a modern publishable key from SUPABASE_PUBLISHABLE_KEYS,
//      or the legacy SUPABASE_ANON_KEY — see _shared/referral-api-env.ts) — a PUBLIC, project-scoped
//      credential, the same value already shipped inside the iOS app. This is a first-gate
//      routing/project-identity check, NOT app attestation and NOT proof of a human/user — it does
//      not identify which installation is calling.
//   B. a valid (client_installation_id, installation_secret) pair — THIS is the actual possession
//      credential that identifies a specific installation (see authenticateInstallation below).
// verify_jwt = false (see supabase/config.toml) because 85Blends does not use Supabase Auth
// sessions; gate A above replaces the platform JWT gate that setting would otherwise remove.
//
// OUT OF SCOPE for this revision (see the referral-api task spec): reward redemption, granting
// Pro, marking any reward `fulfilled`, and any RevenueCat entitlement mutation. This function only
// ever reads reward state and writes participant/alias/attribution rows — never touches
// private.referral_rewards.status beyond what private.process_referral_subscription_event already
// does on its own (this function never calls that function at all).

import { createDatabaseClient, type Sql } from "../_shared/database.ts";
import { resolveReferralApiEnvConfig } from "../_shared/referral-api-env.ts";
import { extractBearerToken, matchesAnyApiKey } from "../_shared/referral-api-auth.ts";
import { constantTimeEqual } from "../_shared/hmac.ts";
import { sha256Hex } from "../_shared/hash.ts";
import { logWebhookEvent } from "../_shared/logging.ts";
import {
  parseApiRequest,
  isValidReferralCodeFormat,
  type BootstrapRequest,
  type StatusRequest,
  type ApplyCodeRequest,
} from "../_shared/referral-api-validation.ts";
import { buildReferralStatusResponse, type ReferralStatusResponse } from "../_shared/referral-api-response.ts";
import { mapReferralFunctionError } from "../_shared/referral-api-errors.ts";
import type { RewardMilestoneRow } from "../_shared/referral-milestones.ts";

const APPLY_RATE_LIMIT_MAX_ATTEMPTS = 5;
const APPLY_RATE_LIMIT_WINDOW_SECONDS = 60;

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

function errorResponse(status: number, code: string): Response {
  return jsonResponse(status, { error: code });
}

async function hashSecret(secret: string): Promise<string> {
  return sha256Hex(new TextEncoder().encode(secret));
}

/** Thrown inside a `sql.begin()` callback to roll it back for a reason that is NOT a Postgres
 *  exception from a private.* function — mapReferralFunctionError would never recognize these, so
 *  index.ts's callers check `instanceof` before falling through to that generic mapping. */
class InstallationTakeoverConflictError extends Error {}

type AuthResult = { ok: true; participantId: string } | { ok: false; response: Response };

/** Authenticates an already-bootstrapped installation: looks up its stored secret hash and
 *  compares (constant-time) against SHA-256 of the supplied secret. Used by `status`, `apply_code`,
 *  and bootstrap's own "does this installation already exist" check. Never distinguishes "unknown
 *  installation" from "wrong secret" in its response — both collapse to the same generic 401,
 *  matching this codebase's existing auth.ts philosophy. */
async function authenticateInstallation(
  sql: Sql,
  clientInstallationId: string,
  installationSecret: string,
): Promise<AuthResult> {
  const rows = await sql<{ installation_secret_hash: string; participant_id: string }[]>`
    select c.installation_secret_hash, p.id as participant_id
    from private.referral_client_installations c
    join private.referral_participants p on p.installation_id = c.installation_id
    where c.installation_id = ${clientInstallationId}
  `;

  if (rows.length === 0) {
    return { ok: false, response: errorResponse(401, "invalid_installation_credentials") };
  }

  const suppliedHash = await hashSecret(installationSecret);
  if (!constantTimeEqual(suppliedHash, rows[0].installation_secret_hash)) {
    return { ok: false, response: errorResponse(401, "invalid_installation_credentials") };
  }

  return { ok: true, participantId: rows[0].participant_id };
}

/** Loads and assembles this participant's client-safe status payload — the shared read path used
 *  by `status`, and by `bootstrap`/`apply_code`'s success responses so all three actions always
 *  report referral progress identically. See referral-api-response.ts for the field-by-field
 *  "never expose private identifiers" contract this builds. */
async function loadStatusResponse(sql: Sql, participantId: string): Promise<ReferralStatusResponse> {
  const [participantRow] = await sql<{ referral_code: string }[]>`
    select referral_code from private.referral_participants where id = ${participantId}
  `;

  const [counts] = await sql<{ qualified_count: string; pending_count: string }[]>`
    select
      count(*) filter (where status = 'qualified')::text as qualified_count,
      count(*) filter (where status = 'pending')::text as pending_count
    from private.referral_attributions
    where referrer_participant_id = ${participantId}
  `;

  const rewardRows = await sql<{ milestone_number: number; status: string }[]>`
    select milestone_number, status
    from private.referral_rewards
    where referrer_participant_id = ${participantId}
  `;

  const [ownAttributionRow] = await sql<{ referral_code_used: string; status: string }[]>`
    select referral_code_used, status
    from private.referral_attributions
    where referred_participant_id = ${participantId}
  `;

  const rewards: RewardMilestoneRow[] = rewardRows.map((row) => ({
    milestoneNumber: row.milestone_number,
    status: row.status as "earned" | "fulfilled" | "revoked",
  }));

  return buildReferralStatusResponse({
    referralCode: participantRow.referral_code,
    qualifiedReferralCount: Number(counts.qualified_count),
    pendingReferralCount: Number(counts.pending_count),
    rewards,
    ownAttribution: ownAttributionRow
      ? { referralCodeUsed: ownAttributionRow.referral_code_used, status: ownAttributionRow.status }
      : null,
  });
}

async function handleBootstrap(sql: Sql, request: BootstrapRequest): Promise<Response> {
  const [existingCredential] = await sql<{ installation_secret_hash: string }[]>`
    select installation_secret_hash from private.referral_client_installations
    where installation_id = ${request.clientInstallationId}
  `;

  if (existingCredential) {
    const suppliedHash = await hashSecret(request.installationSecret);
    if (!constantTimeEqual(suppliedHash, existingCredential.installation_secret_hash)) {
      // Takeover rule: never overwrite an existing installation's secret. See this module's
      // header and the referral-api task spec's "IMPORTANT TAKEOVER RULE."
      return errorResponse(401, "invalid_installation_credentials");
    }
  }

  const secretHash = await hashSecret(request.installationSecret);

  let participantId: string;
  try {
    participantId = await sql.begin(async (tx) => {
      const [participantRow] = await tx<{ participant_id: string }[]>`
        select participant_id from private.create_or_get_referral_participant(
          ${request.clientInstallationId}::uuid,
          ${request.revenueCatAppUserId},
          ${request.revenueCatEnvironment}
        )
      `;

      if (existingCredential) {
        // app_version: update it when the request supplied one; `coalesce` preserves whatever was
        // already stored when it didn't (request.appVersion is null for "not supplied" — see
        // referral-api-validation.ts — never for "clear it", there is no way to clear it).
        await tx`
          update private.referral_client_installations
          set last_seen_at = now(),
              app_version = coalesce(${request.appVersion}, app_version)
          where installation_id = ${request.clientInstallationId}
        `;
      } else {
        // Insert-if-absent, then verify — the same two-phase pattern already established
        // elsewhere in this codebase for the identical class of problem (see this migration's own
        // header comment). Closes a genuine concurrent-first-bootstrap race: if a different
        // request for this SAME new installation_id committed first, our insert becomes a no-op
        // and the verify-read below will see THEIR hash, not ours — correctly reported as a
        // takeover conflict rather than a false success.
        await tx`
          insert into private.referral_client_installations (installation_id, installation_secret_hash, app_version)
          values (${request.clientInstallationId}, ${secretHash}, ${request.appVersion})
          on conflict (installation_id) do nothing
        `;
        const [verifyRow] = await tx<{ installation_secret_hash: string }[]>`
          select installation_secret_hash from private.referral_client_installations
          where installation_id = ${request.clientInstallationId}
        `;
        if (!verifyRow || verifyRow.installation_secret_hash !== secretHash) {
          throw new InstallationTakeoverConflictError();
        }
      }

      return participantRow.participant_id;
    });
  } catch (error) {
    if (error instanceof InstallationTakeoverConflictError) {
      return errorResponse(401, "invalid_installation_credentials");
    }
    const message = error instanceof Error ? error.message : String(error);
    const mapping = mapReferralFunctionError(message);
    if (mapping.code === "internal_error") {
      logWebhookEvent("error", "referral-api bootstrap failure", { message: message.slice(0, 200) });
    }
    return errorResponse(mapping.httpStatus, mapping.code);
  }

  const status = await loadStatusResponse(sql, participantId);
  return jsonResponse(200, { ...status, created: !existingCredential });
}

async function handleStatus(sql: Sql, request: StatusRequest): Promise<Response> {
  const auth = await authenticateInstallation(sql, request.clientInstallationId, request.installationSecret);
  if (!auth.ok) return auth.response;

  const status = await loadStatusResponse(sql, auth.participantId);
  return jsonResponse(200, status);
}

async function handleApplyCode(sql: Sql, request: ApplyCodeRequest): Promise<Response> {
  const auth = await authenticateInstallation(sql, request.clientInstallationId, request.installationSecret);
  if (!auth.ok) return auth.response;

  if (!isValidReferralCodeFormat(request.referralCode)) {
    return errorResponse(400, "invalid_referral_code");
  }

  const [existingAttribution] = await sql<{ referral_code_used: string }[]>`
    select referral_code_used
    from private.referral_attributions
    where referred_participant_id = ${auth.participantId}
  `;

  if (existingAttribution) {
    // Immutability (Phase 10): never call apply_referral_code again once an attribution exists.
    // Same code re-submitted is an idempotent success; a different code is a hard conflict.
    if (existingAttribution.referral_code_used === request.referralCode) {
      const status = await loadStatusResponse(sql, auth.participantId);
      return jsonResponse(200, { status: "already_applied", ...status });
    }
    return errorResponse(409, "referral_already_applied");
  }

  // Fast-path UX check only — private.apply_referral_code remains the authoritative enforcement
  // of self-referral (see the migration's own comment: "do not reimplement its core invariants").
  const [ownParticipant] = await sql<{ referral_code: string }[]>`
    select referral_code from private.referral_participants where id = ${auth.participantId}
  `;
  if (ownParticipant?.referral_code === request.referralCode) {
    return errorResponse(409, "self_referral_not_allowed");
  }

  // Abuse hardening (Phase 12): logs this as a genuine NEW-code attempt BEFORE ever calling
  // apply_referral_code, so a rejected/nonexistent code still counts against the probing limit —
  // see the migration's referral_apply_attempts table comment. This step always commits
  // independently of whatever apply_referral_code does next (a separate statement below, not
  // nested in this same transaction) — otherwise a failed probe would roll back its own attempt
  // log and never actually count, defeating the limit's purpose entirely.
  const rateLimited = await sql.begin(async (tx) => {
    // Advisory lock scoped to this transaction, serializing concurrent apply_code calls from the
    // same installation so the count-check and the insert it gates stay atomic under concurrency.
    await tx`select pg_advisory_xact_lock(hashtext('referral_apply:' || ${request.clientInstallationId}::text))`;

    // `${APPLY_RATE_LIMIT_WINDOW_SECONDS} * interval '1 second'` (a parameterized number times a
    // fixed literal interval), NOT `interval '${...} seconds'` — postgres.js binds every
    // interpolation as a query parameter, and a parameter placeholder cannot sit inside a quoted
    // SQL string literal like `interval '...'`.
    const [{ count }] = await tx<{ count: string }[]>`
      select count(*)::text as count from private.referral_apply_attempts
      where installation_id = ${request.clientInstallationId}
        and attempted_at >= now() - (${APPLY_RATE_LIMIT_WINDOW_SECONDS} * interval '1 second')
    `;
    if (Number(count) >= APPLY_RATE_LIMIT_MAX_ATTEMPTS) {
      return true;
    }

    await tx`
      insert into private.referral_apply_attempts (installation_id)
      values (${request.clientInstallationId})
    `;
    return false;
  });

  if (rateLimited) {
    return errorResponse(429, "rate_limited");
  }

  try {
    await sql`select private.apply_referral_code(${auth.participantId}::uuid, ${request.referralCode})`;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const mapping = mapReferralFunctionError(message);

    if (mapping.code === "referral_already_applied") {
      // Race: a concurrent apply_code call for this SAME participant committed between our
      // pre-check above and this insert attempt. Re-resolve authoritatively rather than trusting
      // the now-stale pre-check.
      const [raceRow] = await sql<{ referral_code_used: string }[]>`
        select referral_code_used from private.referral_attributions
        where referred_participant_id = ${auth.participantId}
      `;
      if (raceRow?.referral_code_used === request.referralCode) {
        const status = await loadStatusResponse(sql, auth.participantId);
        return jsonResponse(200, { status: "already_applied", ...status });
      }
      return errorResponse(409, "referral_already_applied");
    }

    if (mapping.code === "internal_error") {
      logWebhookEvent("error", "referral-api apply_code failure", { message: message.slice(0, 200) });
    }
    return errorResponse(mapping.httpStatus, mapping.code);
  }

  const status = await loadStatusResponse(sql, auth.participantId);
  return jsonResponse(200, { status: "applied", ...status });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  const envResult = resolveReferralApiEnvConfig((name) => Deno.env.get(name));
  if (!envResult.ok) {
    logWebhookEvent("error", "referral-api missing required configuration", {
      missing: envResult.missing.join(","),
    });
    return errorResponse(503, "service_unavailable");
  }
  const env = envResult.config;

  // Gate A — a client-safe (public, project-scoped, non-secret) API key, required independent of
  // installation auth. See this module's header comment. Accepted if it matches ANY configured
  // key (publishable and/or legacy anon) — never logged, whichever it is.
  const apiKey = req.headers.get("apikey") ?? extractBearerToken(req.headers.get("authorization"));
  if (!matchesAnyApiKey(apiKey, env.clientApiKeys)) {
    return errorResponse(401, "invalid_api_key");
  }

  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }

  const parsed = parseApiRequest(rawBody);
  if (!parsed.ok) {
    return errorResponse(400, parsed.code);
  }

  const sql = createDatabaseClient(env.supabaseDbUrl);
  try {
    switch (parsed.request.action) {
      case "bootstrap":
        return await handleBootstrap(sql, parsed.request);
      case "status":
        return await handleStatus(sql, parsed.request);
      case "apply_code":
        return await handleApplyCode(sql, parsed.request);
    }
  } catch (error) {
    logWebhookEvent("error", "referral-api unexpected failure", {
      message: error instanceof Error ? error.message.slice(0, 200) : "unknown",
    });
    return errorResponse(500, "internal_error");
  } finally {
    // Guarded exactly like revenuecat-webhook/index.ts: a connection-close failure here must
    // never replace an already-computed, otherwise-valid response with an unhandled error.
    await sql.end({ timeout: 5 }).catch(() => {});
  }
});
