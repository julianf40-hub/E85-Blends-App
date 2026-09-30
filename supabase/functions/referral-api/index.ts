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
// 85Blends 2.4.0 Referral Reward Redemption: this function now ALSO exposes `claim_reward` — the
// one client path that issues a real Apple subscription Offer Code against an earned reward (see
// handleClaimReward below, and private.claim_referral_reward in
// supabase/migrations/20260928000000_referral_reward_redemption_foundation.sql). It still never
// GRANTS Pro or marks a reward `fulfilled` directly — that only ever happens via
// supabase/functions/revenuecat-webhook, once a real RevenueCat transaction confirms redemption
// (see this feature's own task spec, rule 3/4: issuing a code is never itself fulfillment). This
// function also still never calls private.process_referral_subscription_event.

import { createDatabaseClient, type Sql } from "../_shared/database.ts";
import { resolveReferralApiEnvConfig, type ReferralApiEnvConfig } from "../_shared/referral-api-env.ts";
import { hasMatchingClientApiKey } from "../_shared/referral-api-auth.ts";
import { constantTimeEqual } from "../_shared/hmac.ts";
import { sha256Hex } from "../_shared/hash.ts";
import { logWebhookEvent } from "../_shared/logging.ts";
import {
  parseApiRequest,
  isValidReferralCodeFormat,
  type BootstrapRequest,
  type StatusRequest,
  type ApplyCodeRequest,
  type ClaimRewardRequest,
} from "../_shared/referral-api-validation.ts";
import {
  buildReferralStatusResponse,
  type ReferralStatusResponse,
  type IssuedRewardCodeSummary,
} from "../_shared/referral-api-response.ts";
import { mapReferralFunctionError, buildSafeErrorLogMetadata } from "../_shared/referral-api-errors.ts";
import type { RewardMilestoneRow } from "../_shared/referral-milestones.ts";
import { fetchCustomerSubscriptions } from "../_shared/revenuecat-api.ts";
import { toApiEnvironment, type RevenueCatSubscription, type RevenueCatWebhookEnvironment } from "../_shared/revenuecat-types.ts";
import { resolveActiveProAndProduct } from "../_shared/referral-active-product.ts";

/** Best-effort extraction of a Postgres SQLSTATE from a caught error, for SAFE structured
 *  logging only (see buildSafeErrorLogMetadata) — never for response classification, which stays
 *  on mapReferralFunctionError's message-based matching. The `postgres` npm driver sets `.code`
 *  to the raw 5-character SQLSTATE on a PostgresError; any other shape yields `undefined`, which
 *  buildSafeErrorLogMetadata already treats as "omit." */
function sqlStateOf(error: unknown): unknown {
  return error && typeof error === "object" ? (error as { code?: unknown }).code : undefined;
}

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

type AuthResult =
  | { ok: true; participantId: string; environment: RevenueCatWebhookEnvironment }
  | { ok: false; response: Response };

/** Authenticates an already-bootstrapped installation: looks up its stored secret hash and
 *  compares (constant-time) against SHA-256 of the supplied secret. Used by `status`, `apply_code`,
 *  and bootstrap's own "does this installation already exist" check. Never distinguishes "unknown
 *  installation" from "wrong secret" in its response — both collapse to the same generic 401,
 *  matching this codebase's existing auth.ts philosophy.
 *
 *  85Blends 2.4.0 Referral Reward Redemption, SECOND correctness hardening pass: also resolves and
 *  returns THIS installation's own `current_environment` (private.referral_client_installations —
 *  see the migration's Section 1e) — the environment its most recent successful bootstrap reported.
 *  Every caller (`status`/`apply_code`/`claim_reward`) now derives environment from here, never by
 *  scanning every alias this participant has ever accumulated (the first hardening pass's own
 *  `resolveClaimEnvironment`, removed by this pass — see this file's git history). A row whose
 *  `current_environment` is somehow unresolvable fails closed with the same `environment_unresolvable`
 *  code `claim_reward` already used — expected to be unreachable in practice (every row that can pass
 *  the credential check below was created by a successful bootstrap, which always records
 *  `current_environment` in the SAME transaction — see handleBootstrap) but never guessed/defaulted
 *  on an environment-isolation-integrity path. */
async function authenticateInstallation(
  sql: Sql,
  clientInstallationId: string,
  installationSecret: string,
): Promise<AuthResult> {
  const rows = await sql<{ installation_secret_hash: string; participant_id: string; current_environment: string | null }[]>`
    select c.installation_secret_hash, p.id as participant_id, c.current_environment
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

  const currentEnvironment = rows[0].current_environment;
  if (currentEnvironment !== "SANDBOX" && currentEnvironment !== "PRODUCTION") {
    return { ok: false, response: errorResponse(409, "environment_unresolvable") };
  }

  return { ok: true, participantId: rows[0].participant_id, environment: currentEnvironment };
}

/** Loads and assembles this participant's client-safe status payload — the shared read path used
 *  by `status`, and by `bootstrap`/`apply_code`/`claim_reward`'s success responses so every action
 *  always reports referral progress identically. See referral-api-response.ts for the field-by-field
 *  "never expose private identifiers" contract this builds.
 *
 *  `environment` — 85Blends 2.4.0 Referral Reward Redemption, SECOND correctness hardening pass:
 *  THIS installation's own current environment (see authenticateInstallation/handleBootstrap), used
 *  to scope both the reward-milestone rows and the issued-code lookup below. Reward/code rows now
 *  carry `environment` (see the migration's Section 1b), so an installation that has, across its
 *  lifetime, been bootstrapped in more than one environment can never have a stale/other-environment
 *  reward or code leak into its CURRENT status response. `qualified_count`/`pending_count` stay
 *  unscoped — private.referral_attributions rows can only ever exist via the PRODUCTION-only
 *  qualification pipeline (process_referral_subscription_event's own v1 scope lock), so there is
 *  nothing to cross-contaminate there. */
async function loadStatusResponse(
  sql: Sql,
  participantId: string,
  environment: RevenueCatWebhookEnvironment,
): Promise<ReferralStatusResponse> {
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
      and environment = ${environment}
  `;

  const [ownAttributionRow] = await sql<{ referral_code_used: string; status: string }[]>`
    select referral_code_used, status
    from private.referral_attributions
    where referred_participant_id = ${participantId}
  `;

  // 85Blends 2.4.0 Referral Reward Redemption — this participant's own currently issued (not yet
  // redeemed) code, if any. See referral-api-response.ts's IssuedRewardCodeSummary header for why
  // returning the raw apple_code here is safe: this whole function only ever runs after
  // authenticateInstallation has already confirmed the CALLER owns `participantId`.
  //
  // Correctness hardening pass — REAL BUG this closes (found in review): an issued code that has
  // EXPIRED before ever being redeemed must never be exposed here as if it were still redeemable.
  // `claim_referral_reward` already auto-voids an expired issued code the moment the SAME reward is
  // claimed again, but a participant who never re-opens the redemption sheet after their code
  // expires would otherwise see a permanently stale, dead code in their own status response
  // forever. `apple_expires_at > now()` is the authoritative filter (apple_expires_at is NOT NULL —
  // every code this pool ever holds has a known expiration). SECOND HARDENING PASS: also scoped by
  // `environment` — see this function's own header.
  const [issuedCodeRow] = await sql<{
    product_id: string;
    offer_reference_name: string;
    apple_code: string;
    apple_expires_at: Date;
  }[]>`
    select product_id, offer_reference_name, apple_code, apple_expires_at
    from private.referral_reward_offer_codes
    where referrer_participant_id = ${participantId}
      and environment = ${environment}
      and status = 'issued'
      and apple_expires_at > now()
    limit 1
  `;

  const rewards: RewardMilestoneRow[] = rewardRows.map((row) => ({
    milestoneNumber: row.milestone_number,
    status: row.status as "earned" | "issued" | "fulfilled" | "revoked",
  }));

  const issuedRewardCode: IssuedRewardCodeSummary | null = issuedCodeRow
    ? {
        productId: issuedCodeRow.product_id,
        offerReferenceName: issuedCodeRow.offer_reference_name,
        appleCode: issuedCodeRow.apple_code,
        appleExpiresAt: issuedCodeRow.apple_expires_at,
      }
    : null;

  return buildReferralStatusResponse({
    referralCode: participantRow.referral_code,
    qualifiedReferralCount: Number(counts.qualified_count),
    pendingReferralCount: Number(counts.pending_count),
    rewards,
    ownAttribution: ownAttributionRow
      ? { referralCodeUsed: ownAttributionRow.referral_code_used, status: ownAttributionRow.status }
      : null,
    issuedRewardCode,
  });
}

async function handleBootstrap(sql: Sql, request: BootstrapRequest): Promise<Response> {
  // Fast-path ONLY: rejects the overwhelmingly common "known installation, wrong secret" case
  // without opening a transaction or touching participant/alias state at all. This is an
  // optimization, NOT the authoritative check — the in-transaction credential resolution below
  // is what actually guarantees correctness under concurrency (two near-simultaneous bootstrap
  // requests for the same installation_id can both reach this point having seen no row here yet).
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
  let credentialCreated: boolean;
  try {
    const result = await sql.begin(async (tx) => {
      // private.referral_client_installations.installation_id carries a FOREIGN KEY to
      // private.referral_participants.installation_id — the participant row MUST exist before
      // any credential row can reference it, which is why this call always comes first, even
      // though it means a wrong-secret loser's alias mutation (below) executes before its
      // credential check fails. That is safe: a throw anywhere in this callback rolls back
      // EVERYTHING it did, participant/alias mutation included — see database.ts's own comment
      // ("Throwing is what makes postgres.js roll back everything the callback did") — so "zero
      // loser-side persistent mutation" is guaranteed by transactional atomicity, not by
      // execution order.
      const [participantRow] = await tx<{ participant_id: string }[]>`
        select participant_id from private.create_or_get_referral_participant(
          ${request.clientInstallationId}::uuid,
          ${request.revenueCatAppUserId},
          ${request.revenueCatEnvironment}
        )
      `;

      // Race-accurate credential resolution: never trust the pre-transaction read above alone —
      // a concurrent request (same OR different secret) may have created this row in the
      // meantime. Whichever transaction's INSERT actually lands the row is the only one where
      // `credentialCreated` is true. Postgres's own row-level locking for
      // INSERT ... ON CONFLICT guarantees a losing insert only resolves (with zero rows) once
      // the winner's transaction has durably committed — see the migration's own
      // create_or_get_referral_participant hardening comment for the identical reasoning.
      const insertedRows = await tx<{ installation_id: string }[]>`
        insert into private.referral_client_installations (installation_id, installation_secret_hash)
        values (${request.clientInstallationId}, ${secretHash})
        on conflict (installation_id) do nothing
        returning installation_id
      `;
      const credentialCreated = insertedRows.length > 0;

      if (!credentialCreated) {
        const [existingRow] = await tx<{ installation_secret_hash: string }[]>`
          select installation_secret_hash from private.referral_client_installations
          where installation_id = ${request.clientInstallationId}
        `;
        if (!existingRow) {
          // Unreachable per the row-locking guarantee above — never assume away a defensive
          // check on an identity-integrity path.
          throw new InstallationTakeoverConflictError();
        }
        if (!constantTimeEqual(secretHash, existingRow.installation_secret_hash)) {
          // Takeover rule, enforced authoritatively (not just the fast-path check above): rolls
          // back this entire transaction, including the participant/alias step — never
          // overwrites the existing credential. See this module's header and the referral-api
          // task spec's "IMPORTANT TAKEOVER RULE."
          throw new InstallationTakeoverConflictError();
        }
        // Secret matches: a legitimate same-secret concurrent or repeat bootstrap. Proceed to
        // the common update below exactly as if this transaction had created the row itself.
      }

      // Common update — reached only when this transaction created the credential row OR
      // verified it already carries the SAME secret (never for a mismatch, which threw above).
      // Updates app_version whenever the request supplied one, and otherwise preserves whatever
      // was already stored, so a same-secret concurrent request never "loses" its app_version
      // merely because a different request happened to win the INSERT race.
      //
      // 85Blends 2.4.0 Referral Reward Redemption, SECOND correctness hardening pass:
      // current_environment/current_app_user_id are ALWAYS overwritten with THIS bootstrap
      // request's own values (never coalesced with the prior stored value, unlike app_version) —
      // this row must always reflect the MOST RECENT bootstrap's identity, which is the entire
      // point (see the migration's Section 1e and authenticateInstallation's own header).
      await tx`
        update private.referral_client_installations
        set last_seen_at = now(),
            app_version = coalesce(${request.appVersion}, app_version),
            current_environment = ${request.revenueCatEnvironment},
            current_app_user_id = ${request.revenueCatAppUserId}
        where installation_id = ${request.clientInstallationId}
      `;

      return { participantId: participantRow.participant_id, credentialCreated };
    });
    participantId = result.participantId;
    credentialCreated = result.credentialCreated;
  } catch (error) {
    if (error instanceof InstallationTakeoverConflictError) {
      return errorResponse(401, "invalid_installation_credentials");
    }
    const message = error instanceof Error ? error.message : String(error);
    const mapping = mapReferralFunctionError(message);
    if (mapping.code === "internal_error") {
      logWebhookEvent("error", "referral-api bootstrap failure", buildSafeErrorLogMetadata(sqlStateOf(error)));
    }
    return errorResponse(mapping.httpStatus, mapping.code);
  }

  // `request.revenueCatEnvironment` directly — this bootstrap call just wrote it as THIS
  // installation's own current_environment (above), so re-deriving it via authenticateInstallation
  // would just read back the exact same value through an extra round trip.
  const status = await loadStatusResponse(sql, participantId, request.revenueCatEnvironment);
  return jsonResponse(200, { ...status, created: credentialCreated });
}

async function handleStatus(sql: Sql, request: StatusRequest): Promise<Response> {
  const auth = await authenticateInstallation(sql, request.clientInstallationId, request.installationSecret);
  if (!auth.ok) return auth.response;

  const status = await loadStatusResponse(sql, auth.participantId, auth.environment);
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
      const status = await loadStatusResponse(sql, auth.participantId, auth.environment);
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
        const status = await loadStatusResponse(sql, auth.participantId, auth.environment);
        return jsonResponse(200, { status: "already_applied", ...status });
      }
      return errorResponse(409, "referral_already_applied");
    }

    if (mapping.code === "internal_error") {
      logWebhookEvent("error", "referral-api apply_code failure", buildSafeErrorLogMetadata(sqlStateOf(error)));
    }
    return errorResponse(mapping.httpStatus, mapping.code);
  }

  const status = await loadStatusResponse(sql, auth.participantId, auth.environment);
  return jsonResponse(200, { status: "applied", ...status });
}

/** 85Blends 2.4.0 Referral Reward Redemption — resolves this participant's currently active Pro
 *  status AND product BACKEND-AUTHORITATIVELY, via a fresh RevenueCat REST API v2 call (never
 *  trusting a client-supplied claim — see this feature's task spec, Phase 1). Queries subscriptions
 *  for EVERY RevenueCat identity (app_user_id) this participant has ever bootstrapped with IN THE
 *  GIVEN ENVIRONMENT (see private.referral_participant_aliases) — almost always exactly one in
 *  practice, but never assumed to be — and merges the results before applying the same
 *  qualifying-subscription rule entitlement.ts's calculatePro uses, so this can never disagree with
 *  the canonical entitlement mirror about whether Pro is active.
 *
 *  `environment` is THIS installation's own `current_environment`, resolved by
 *  authenticateInstallation from private.referral_client_installations (SECOND correctness
 *  hardening pass — previously resolved by a now-removed `resolveClaimEnvironment` that scanned
 *  every alias this participant had ever accumulated and let PRODUCTION win; see that function's
 *  former header and authenticateInstallation's own comment). Scoping RevenueCat calls to whichever
 *  environment the CURRENT installation actually belongs to is what lets a SANDBOX test
 *  participant's own claim exercise this SAME real code path (including the "active Pro subscriber
 *  gets their own product" branch) during Sandbox/TestFlight verification, not just the "choose a
 *  plan" branch.
 *
 *  Returns `{ kind: "ok" }` with the resolved state, or `{ kind: "lookup_failed" }` if this
 *  participant has at least one identity in this environment but a RevenueCat API call for it
 *  failed — NEVER falls back to guessing `proIsActive: false` in that case, which could otherwise
 *  let a real active subscriber's claim be misrouted through the "choose any of the three products"
 *  path (Phase 12's "client-supplied active-product spoofing" risk, applied here to an accidental
 *  failure rather than a malicious client). A participant with ZERO identities in this environment
 *  is reported as `proIsActive: false` with no RevenueCat API call at all — there is nothing to
 *  look up. */
async function resolveAuthoritativeActiveProduct(
  sql: Sql,
  env: ReferralApiEnvConfig,
  participantId: string,
  environment: RevenueCatWebhookEnvironment,
): Promise<{ kind: "ok"; proIsActive: boolean; activeProductId: string | null } | { kind: "lookup_failed" }> {
  const apiEnvironment = toApiEnvironment(environment);
  if (!apiEnvironment) {
    // Unreachable — `environment` only ever comes from authenticateInstallation, which only ever
    // returns 'SANDBOX'/'PRODUCTION' on its ok branch — but never assumed away on an
    // environment-isolation path.
    return { kind: "lookup_failed" };
  }

  const aliasRows = await sql<{ app_user_id: string }[]>`
    select app_user_id from private.referral_participant_aliases
    where participant_id = ${participantId} and environment = ${environment}
  `;

  if (aliasRows.length === 0) {
    return { kind: "ok", proIsActive: false, activeProductId: null };
  }

  const allSubscriptions: RevenueCatSubscription[] = [];
  for (const row of aliasRows) {
    const apiResult = await fetchCustomerSubscriptions(
      { projectId: env.revenueCatProjectId, secretApiKey: env.revenueCatV2SecretApiKey },
      row.app_user_id,
      apiEnvironment,
    );
    if (apiResult.kind !== "ok") {
      logWebhookEvent("error", "referral-api claim_reward: RevenueCat lookup failed", {
        kind: apiResult.kind,
        statusCategory: apiResult.statusCategory,
      });
      return { kind: "lookup_failed" };
    }
    allSubscriptions.push(...apiResult.subscriptions);
  }

  const resolved = resolveActiveProAndProduct(allSubscriptions);
  return { kind: "ok", proIsActive: resolved.proIsActive, activeProductId: resolved.activeProductId };
}

async function handleClaimReward(sql: Sql, env: ReferralApiEnvConfig, request: ClaimRewardRequest): Promise<Response> {
  const auth = await authenticateInstallation(sql, request.clientInstallationId, request.installationSecret);
  if (!auth.ok) return auth.response;

  // SECOND HARDENING PASS: environment comes straight from authenticateInstallation's own
  // `auth.environment` (THIS installation's current_environment) — already fail-closed with
  // `environment_unresolvable` inside authenticateInstallation itself if unresolvable, so there is
  // nothing further to check here.
  const environment = auth.environment;

  const activeProduct = await resolveAuthoritativeActiveProduct(sql, env, auth.participantId, environment);
  if (activeProduct.kind === "lookup_failed") {
    return errorResponse(503, "revenuecat_lookup_failed");
  }

  type ClaimRow = {
    outcome: string;
    reward_id: string | null;
    milestone_number: number | null;
    product_id: string | null;
    offer_reference_name: string | null;
    apple_code: string | null;
    apple_expires_at: Date | null;
  };
  let claimRow: ClaimRow;
  try {
    // `activeProduct.activeProductId` may legitimately be NULL for an ACTIVE Pro subscriber when the
    // RevenueCat API response carried no resolvable Apple store identifier (see
    // _shared/referral-active-product.ts). That NULL is passed through unchanged, on purpose:
    // private.claim_referral_reward (migrations 20260929230218 + 20260930090000) is the single owner
    // of the narrow fallback that resolves it — only for a NULL product — from this participant's
    // own same-environment webhook history, reduced to the latest lifecycle state per subscription
    // (a refund/expiration invalidates), matched through every alias bound to the participant, and
    // still fails closed (`legacy_or_unsupported_product_active`) when it can't. A resolved but
    // unsupported product is passed through untouched and fails closed in the core. This function
    // never substitutes a product of its own.
    const rows = await sql<ClaimRow[]>`
      select * from private.claim_referral_reward(
        ${auth.participantId}::uuid,
        ${environment},
        ${activeProduct.proIsActive},
        ${activeProduct.activeProductId},
        ${request.requestedProductId}
      )
    `;
    claimRow = rows[0];
  } catch (error) {
    // private.claim_referral_reward never raises for an expected outcome (every legitimate result
    // is a typed row — see its own RETURNS TABLE) — a caught error here is always either a genuine
    // unexpected database failure, or this feature's migration not being deployed yet (42883/42P01,
    // the same deployment-ordering guard used elsewhere in this codebase). Neither is safe to
    // guess a response for; both map to the same generic, safe 503/500 the client already knows how
    // to treat as "temporarily unavailable, try again."
    const code = sqlStateOf(error);
    logWebhookEvent("error", "referral-api claim_reward failure", buildSafeErrorLogMetadata(code));
    if (code === "42883" || code === "42P01") {
      return errorResponse(503, "service_unavailable");
    }
    return errorResponse(500, "internal_error");
  }

  // Re-loaded AFTER the claim commits, so `issued_reward_*` here already reflects whatever this
  // claim attempt just did (a freshly issued code, an unchanged already-issued one, or nothing —
  // see loadStatusResponse's own issuedRewardCode query). Never duplicated as separate top-level
  // fields alongside `...status` below — `reward_milestone_number` is the one piece of information
  // this response needs that status alone doesn't carry (which specific milestone this claim
  // attempt concerned), so it is the only field added outside of `status`/`...status`.
  const status = await loadStatusResponse(sql, auth.participantId, environment);
  // Every SQL outcome maps 1:1 to a response `status` string — see claim_referral_reward's own
  // RETURNS TABLE comment for the full set. Deliberately always HTTP 200 here (auth/request-shape
  // failures already returned above) — mirrors apply_code's existing "200 + status field" pattern
  // for every DOMAIN outcome, never an HTTP error for a legitimate "nothing to claim right now"/
  // "no codes available" result (this feature's task spec, Section 11, test 9).
  return jsonResponse(200, {
    status: claimRow.outcome,
    reward_milestone_number: claimRow.milestone_number,
    ...status,
  });
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
  // installation auth. See this module's header comment. Accepted if EITHER the `apikey` header
  // OR the `Authorization: Bearer` token matches ANY configured key (publishable and/or legacy
  // anon) — no precedence between the two sources (see hasMatchingClientApiKey's own comment for
  // why `??` between them would be wrong). Never logged, whichever credential it is.
  const apiKeyOk = hasMatchingClientApiKey(
    req.headers.get("apikey"),
    req.headers.get("authorization"),
    env.clientApiKeys,
  );
  if (!apiKeyOk) {
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
      case "claim_reward":
        return await handleClaimReward(sql, env, parsed.request);
    }
  } catch (error) {
    logWebhookEvent("error", "referral-api unexpected failure", buildSafeErrorLogMetadata(sqlStateOf(error)));
    return errorResponse(500, "internal_error");
  } finally {
    // Guarded exactly like revenuecat-webhook/index.ts: a connection-close failure here must
    // never replace an already-computed, otherwise-valid response with an unhandled error.
    await sql.end({ timeout: 5 }).catch(() => {});
  }
});
