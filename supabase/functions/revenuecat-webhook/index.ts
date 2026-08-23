// 85Blends 2.3.0 — Phase B1. RevenueCat webhook HTTP receiver.
//
// Deno-specific entry point (Deno.serve, Deno.env, `npm:` imports via the shared modules it
// pulls in) — NOT executable/testable under Node. Deliberately thin: every decision with real
// logic to get right (auth, idempotency, customer/alias resolution, Pro calculation, RevenueCat
// API pagination/error classification) lives in supabase/functions/_shared/*.ts, each unit-tested
// under Node where it doesn't depend on Deno or a live Postgres/RevenueCat connection — see each
// module's own header comment and supabase/functions/_shared/*.test.ts.
//
// NOT DEPLOYED — see supabase/README.md and the Phase B1 final report. This file has not been
// run against a live Deno runtime in this environment (no `deno` binary available here); it has
// only been statically reviewed. Re-verify with `supabase functions serve` / a real deployment
// before relying on it.

import { resolveEnvConfig, type WebhookEnvConfig } from "../_shared/env.ts";
import { verifyWebhookAuth } from "../_shared/auth.ts";
import { sha256Hex } from "../_shared/hash.ts";
import {
  parseWebhookEvent,
  type ParsedWebhookEvent,
} from "../_shared/revenuecat-webhook-parser.ts";
import { calculatePro } from "../_shared/entitlement.ts";
import { toApiEnvironment, type RevenueCatWebhookEnvironment } from "../_shared/revenuecat-types.ts";
import { fetchCustomerSubscriptions } from "../_shared/revenuecat-api.ts";
import {
  applyRefreshPlansAndMarkProcessed,
  claimLedgerEvent,
  createDatabaseClient,
  markLedgerError,
  markLedgerHashMismatch,
  markLedgerProcessed,
  type LedgerEventInput,
  type RefreshPlan,
  type Sql,
} from "../_shared/database.ts";
import { logWebhookEvent, maskIdentifier } from "../_shared/logging.ts";

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** What to record in the ledger's nullable app_user_id/original_app_user_id/environment columns
 *  for each event kind. `originalAppUserId` here is ledger-completeness only — a faithful record
 *  of what RevenueCat's payload provided, never fabricated/derived from other identity fields
 *  (e.g. never falls back to aliasSet[0] the way `appUserId` does above it) and never read by any
 *  entitlement/identity-resolution code path (see buildRefreshPlan/handleNormalEvent/
 *  handleTransferEvent below, which all derive their own aliasSet/preferredAnchor directly from
 *  `parsed`, not from the ledger row this produces). Stays null wherever RevenueCat's payload
 *  didn't provide it — never inferred to satisfy this column. */
function ledgerIdentityFields(
  parsed: Exclude<ParsedWebhookEvent, { kind: "malformed" }>,
): { appUserId: string | null; originalAppUserId: string | null; environment: RevenueCatWebhookEnvironment | null } {
  switch (parsed.kind) {
    case "test":
      return { appUserId: null, originalAppUserId: null, environment: null };
    case "transfer":
      return { appUserId: null, originalAppUserId: parsed.originalAppUserId, environment: parsed.environment };
    case "temporary_entitlement_grant":
      return { appUserId: parsed.appUserId, originalAppUserId: null, environment: parsed.environment };
    case "normal":
      return {
        appUserId: parsed.appUserId ?? parsed.originalAppUserId ?? parsed.aliasSet[0],
        originalAppUserId: parsed.originalAppUserId,
        environment: parsed.environment,
      };
    case "insufficient":
      return { appUserId: null, originalAppUserId: null, environment: null };
  }
}

/**
 * Fetches RevenueCat's canonical subscriptions for one identity group + environment and turns the
 * result into a `RefreshPlan`, or an error string on failure. Performs no database work — safe to
 * call any number of times before any transaction opens (Phase 11 / Phase B1 review Finding 4).
 */
async function buildRefreshPlan(
  env: WebhookEnvConfig,
  params: {
    aliasSet: string[];
    environment: RevenueCatWebhookEnvironment;
    preferredAnchor: string;
    triggerEventId: string;
    queryAppUserId: string;
  },
): Promise<{ kind: "ok"; plan: RefreshPlan } | { kind: "error"; detail: string }> {
  const apiEnvironment = toApiEnvironment(params.environment);
  if (!apiEnvironment) {
    // Unreachable in practice — every caller already validated `environment` before getting here
    // — but never assume away a defensive check on a security-relevant path.
    return { kind: "error", detail: "internal: unmappable environment" };
  }

  const apiResult = await fetchCustomerSubscriptions(
    { projectId: env.revenueCatProjectId, secretApiKey: env.revenueCatV2SecretApiKey },
    params.queryAppUserId,
    apiEnvironment,
  );

  if (apiResult.kind === "retryable_error" || apiResult.kind === "config_error") {
    logWebhookEvent("error", "RevenueCat API call failed — entitlement state left unchanged", {
      environment: params.environment,
      statusCategory: apiResult.statusCategory,
      kind: apiResult.kind,
    });
    return { kind: "error", detail: `RevenueCat API ${apiResult.kind}: ${apiResult.statusCategory}` };
  }

  const entitlement = calculatePro(apiResult.subscriptions);

  return {
    kind: "ok",
    plan: {
      aliasSet: params.aliasSet,
      environment: params.environment,
      preferredAnchor: params.preferredAnchor,
      entitlement,
      triggerEventId: params.triggerEventId,
    },
  };
}

async function handleNormalEvent(
  sql: Sql,
  env: WebhookEnvConfig,
  parsed: Extract<ParsedWebhookEvent, { kind: "normal" }>,
): Promise<Response> {
  const queryAppUserId = parsed.appUserId ?? parsed.originalAppUserId ?? parsed.aliasSet[0];
  const preferredAnchor = parsed.originalAppUserId ?? parsed.appUserId ?? parsed.aliasSet[0];

  const built = await buildRefreshPlan(env, {
    aliasSet: parsed.aliasSet,
    environment: parsed.environment,
    preferredAnchor,
    triggerEventId: parsed.core.id,
    queryAppUserId,
  });

  if (built.kind === "error") {
    await markLedgerError(sql, parsed.core.id, built.detail);
    return jsonResponse(500, { error: "revenuecat_api_failure" });
  }

  // ONE transaction: resolve/insert-or-update the customer, verify/insert aliases, and mark the
  // ledger row processed, all atomically (Phase B1 review Finding 4).
  const outcome = await applyRefreshPlansAndMarkProcessed(sql, parsed.core.id, [built.plan]);

  if (outcome.kind === "conflict") {
    await markLedgerError(sql, parsed.core.id, `identity conflict: ${outcome.detail}`);
    return jsonResponse(500, { error: "identity_conflict" });
  }

  logWebhookEvent("info", "normal event processed", {
    eventId: maskIdentifier(parsed.core.id),
    type: parsed.core.type,
    environment: parsed.environment,
    proIsActive: built.plan.entitlement.proIsActive,
  });
  return jsonResponse(200, { status: "processed" });
}

/**
 * TRANSFER events carry `transferred_from[]`/`transferred_to[]` instead of a single identity —
 * per Phase 20, source and destination are refreshed as two INDEPENDENT identity groups, never
 * merged. If `environment` is absent from the event, both groups are refreshed for BOTH SANDBOX
 * and PRODUCTION (up to 4 plans total) since there is no way to know which environment(s) the
 * transfer actually affects. Design choice, not mandated by the task spec: the RevenueCat API is
 * queried using the FIRST id in each group — any ID in the group should resolve to the same
 * underlying RevenueCat customer, and the write transaction's own alias resolution (see
 * customer-resolution.ts) is what actually determines the canonical Supabase customer row, not
 * which ID happened to be queried.
 *
 * Per Phase B1 review Finding 4: ALL group/environment RevenueCat API calls happen first, with no
 * open transaction; only once every one of them has succeeded does ONE write transaction apply
 * every resulting plan and mark the ledger row processed. If any API call fails partway through,
 * NOTHING has been written to revenuecat_customers/aliases for this event yet — there is nothing
 * to roll back, only the ledger error to record.
 */
async function handleTransferEvent(
  sql: Sql,
  env: WebhookEnvConfig,
  parsed: Extract<ParsedWebhookEvent, { kind: "transfer" }>,
): Promise<Response> {
  const groups: { label: string; ids: string[] }[] = [];
  if (parsed.transferredFrom.length > 0) groups.push({ label: "source", ids: parsed.transferredFrom });
  if (parsed.transferredTo.length > 0) groups.push({ label: "destination", ids: parsed.transferredTo });

  if (groups.length === 0) {
    await markLedgerProcessed(sql, parsed.core.id, "TRANSFER event carried no transferred_from/transferred_to IDs");
    return jsonResponse(200, { status: "recorded_no_mutation" });
  }

  const environments: RevenueCatWebhookEnvironment[] = parsed.environment
    ? [parsed.environment]
    : ["SANDBOX", "PRODUCTION"];

  const plans: RefreshPlan[] = [];
  for (const group of groups) {
    for (const environment of environments) {
      const built = await buildRefreshPlan(env, {
        aliasSet: group.ids,
        environment,
        preferredAnchor: group.ids[0],
        triggerEventId: parsed.core.id,
        queryAppUserId: group.ids[0],
      });

      if (built.kind === "error") {
        await markLedgerError(
          sql,
          parsed.core.id,
          `${built.detail} refreshing TRANSFER ${group.label} group (${environment})`,
        );
        return jsonResponse(500, { error: "revenuecat_api_failure" });
      }
      plans.push(built.plan);
    }
  }

  const outcome = await applyRefreshPlansAndMarkProcessed(sql, parsed.core.id, plans);

  if (outcome.kind === "conflict") {
    await markLedgerError(sql, parsed.core.id, `identity conflict applying TRANSFER plans: ${outcome.detail}`);
    return jsonResponse(500, { error: "identity_conflict" });
  }

  logWebhookEvent("info", "transfer event processed", {
    eventId: maskIdentifier(parsed.core.id),
    sourceCount: parsed.transferredFrom.length,
    destinationCount: parsed.transferredTo.length,
    environmentKnown: parsed.environment !== null,
    planCount: plans.length,
  });
  return jsonResponse(200, { status: "processed" });
}

Deno.serve(async (req) => {
  const startedAt = Date.now();

  if (req.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  const envResult = resolveEnvConfig((name) => Deno.env.get(name));
  if (!envResult.ok) {
    // Phase 7: log only the missing VARIABLE NAMES, never a value.
    logWebhookEvent("error", "missing required server configuration", { missing: envResult.missing.join(",") });
    return jsonResponse(503, { error: "server_not_configured" });
  }
  const env = envResult.config;

  // Read the body exactly once, as raw bytes, before anything else touches it — required for
  // byte-exact HMAC verification (Phase 5). Do not call req.json() first.
  const rawBody = new Uint8Array(await req.arrayBuffer());

  const authResult = await verifyWebhookAuth({
    headers: req.headers,
    rawBody,
    config: { authHeaderSecret: env.webhookAuthHeaderSecret, hmacSecret: env.webhookHmacSecret },
    nowUnixSeconds: Math.floor(Date.now() / 1000),
  });
  if (!authResult.ok) {
    // Generic response and generic log — never reveal whether the Authorization header or the
    // HMAC signature (or both) failed (Phase 5/6).
    logWebhookEvent("warn", "webhook authentication failed", {});
    return jsonResponse(401, { error: "unauthorized" });
  }

  let envelope: unknown;
  try {
    envelope = JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    return jsonResponse(400, { error: "invalid_json" });
  }

  const parsed = parseWebhookEvent(envelope);
  if (parsed.kind === "malformed") {
    logWebhookEvent("warn", "malformed webhook body after auth passed", { reason: parsed.reason });
    return jsonResponse(400, { error: "malformed_event" });
  }

  const payloadHash = await sha256Hex(rawBody);
  const identity = ledgerIdentityFields(parsed);
  const ledgerInput: LedgerEventInput = {
    eventId: parsed.core.id,
    eventType: parsed.core.type,
    appUserId: identity.appUserId,
    originalAppUserId: identity.originalAppUserId,
    environment: identity.environment,
    eventTimestampMs: parsed.core.event_timestamp_ms,
    payloadHash,
    rawPayload: envelope,
  };

  const sql = createDatabaseClient(env.supabaseDbUrl);
  try {
    const decision = await claimLedgerEvent(sql, ledgerInput);

    if (decision.kind === "duplicate_processed") {
      logWebhookEvent("info", "duplicate event, already processed — no-op", {
        eventId: maskIdentifier(parsed.core.id),
        type: parsed.core.type,
      });
      return jsonResponse(200, { status: "duplicate_processed" });
    }
    if (decision.kind === "hash_mismatch") {
      // A row that already reached "processed" must never be regressed by a later mismatched
      // delivery — markLedgerHashMismatch itself enforces this from `previousStatus`, but the log
      // line below reflects it too so an operator reading logs isn't misled either.
      await markLedgerHashMismatch(sql, parsed.core.id, decision.previousStatus);
      logWebhookEvent("error", "event_id redelivered with a different payload_hash", {
        eventId: maskIdentifier(parsed.core.id),
        previousStatus: decision.previousStatus,
      });
      return jsonResponse(409, { error: "payload_mismatch" });
    }
    // decision.kind is "new" or "duplicate_retryable" from here on — proceed to (re)process.

    switch (parsed.kind) {
      case "test":
        await markLedgerProcessed(sql, parsed.core.id, "TEST event — no customer state written");
        logWebhookEvent("info", "test event processed", { eventId: maskIdentifier(parsed.core.id) });
        return jsonResponse(200, { status: "test_ok" });

      case "insufficient":
        await markLedgerProcessed(sql, parsed.core.id, `insufficient data for entitlement refresh: ${parsed.reason}`);
        logWebhookEvent("warn", "event recorded without entitlement mutation — insufficient data", {
          eventId: maskIdentifier(parsed.core.id),
          type: parsed.core.type,
          reason: parsed.reason,
        });
        return jsonResponse(200, { status: "recorded_no_mutation" });

      case "temporary_entitlement_grant":
        await markLedgerProcessed(
          sql,
          parsed.core.id,
          "TEMPORARY_ENTITLEMENT_GRANT — no environment-specific entitlement mutation performed",
        );
        logWebhookEvent("info", "temporary_entitlement_grant recorded without entitlement mutation", {
          eventId: maskIdentifier(parsed.core.id),
          environmentKnown: parsed.environment !== null,
        });
        return jsonResponse(200, { status: "recorded_no_mutation" });

      case "normal":
        return await handleNormalEvent(sql, env, parsed);

      case "transfer":
        return await handleTransferEvent(sql, env, parsed);
    }
  } catch (error) {
    // Never leak a stack trace or internal detail to the caller (Phase 25). Best-effort mark the
    // ledger row as errored so it stays retryable rather than stuck at "received" forever with no
    // record of why.
    logWebhookEvent("error", "unhandled processing failure", {
      eventId: maskIdentifier(parsed.core.id),
      detail: error instanceof Error ? error.message : "unknown error",
    });
    try {
      await markLedgerError(sql, parsed.core.id, "unhandled processing failure");
    } catch {
      // Best-effort only — if the database is unreachable, there's nothing more to record.
    }
    return jsonResponse(500, { error: "internal_error" });
  } finally {
    await sql.end({ timeout: 5 }).catch(() => {});
    logWebhookEvent("info", "request handled", { latencyMs: Date.now() - startedAt });
  }
});
