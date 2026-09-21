// 85Blends 2.4.0 — Generic promo campaign backend HTTP receiver.
//
// Deno-specific entry point (Deno.serve, Deno.env) — NOT executable/testable under Node, same as
// referral-api/index.ts and revenuecat-webhook/index.ts. Deliberately thin: every decision with
// real logic to get right (request validation, response shape, error mapping, redemption URL
// construction) lives in supabase/functions/_shared/promo-api-*.ts, each unit-tested under Node —
// see each module's own header comment.
//
// THE ONLY CLIENT PATH into the private.promo_* foundation (see the promo campaign foundation
// migration) — none of those tables/functions are exposed through PostgREST. Reaches Postgres the
// same way referral-api/revenuecat-webhook already do: a direct SUPABASE_DB_URL connection (see
// _shared/database.ts's createDatabaseClient, reused as-is here), never the PostgREST Data API.
//
// AUTHENTICATION — two independent gates, both required on every request, IDENTICAL in shape to
// referral-api's own (see that file's own header for the full rationale, not repeated here):
//   A. a valid client-safe Supabase API key. Reuses referral-api-env.ts's
//      resolveReferralApiEnvConfig and referral-api-auth.ts's hasMatchingClientApiKey directly —
//      the required env vars and the key-matching rule are byte-for-byte identical to referral-api's
//      own, so there is no reason for a second, parallel implementation of either. (The "referral"
//      naming on those two shared files is legacy — they were written before this generic promo
//      system existed — but they are exactly the right shared, non-feature-specific tools; renaming
//      them is out of scope for this addition and would touch referral-api's own imports.)
//   B. a valid (installation_id, installation_secret) pair, checked against
//      private.referral_client_installations — the SAME durable installation-possession credential
//      referral-api already authenticates against (see this repo's promo-foundation task spec: "Do
//      NOT create a second Keychain secret system... reuse the EXISTING durable installation
//      possession credential"). That table's name is legacy too but is already the app's one
//      shipping installation-identity/possession-credential store.
// The authenticateInstallation check below is a DELIBERATE, NECESSARY copy of referral-api/
// index.ts's own function of the same shape, not an import from it — referral-api/index.ts is
// explicitly out of scope for this addition (never modified, never even read from at runtime by
// this function), and per this codebase's own established architecture (see _shared/database.ts's
// header), a function's index.ts is allowed to hold this kind of thin, Deno-runtime-specific,
// DB-touching glue directly rather than extracting it to _shared.
//
// verify_jwt = false (see supabase/config.toml) for the identical reason as referral-api: 85Blends
// does not use Supabase Auth sessions, so this function performs its own independent
// authentication (gates A and B above) in place of the platform JWT gate that setting would
// otherwise remove.
//
// RATE LIMITING / promo_code_attempts: unlike referral-api's own referral_apply_attempts (which
// has no outcome column and can safely check-and-insert as one atomic advisory-locked step), this
// table's `outcome` column can only be known AFTER the real work (a campaign lookup or a
// private.claim_promo_campaign call) has actually happened — so the check and the insert here are
// deliberately two separate steps: isRateLimited() first (bounds how much work a hammering caller
// can trigger at all), then recordAttempt() afterward with the real outcome. This is intentionally
// a softer guarantee than referral-api's own atomic check+insert (a narrow window exists where two
// near-simultaneous requests could both pass the same isRateLimited() check before either records
// its attempt) — acceptable for an ABUSE DETERRENT, never used for anything that needs to be exact
// the way the global claim cap does (see the migration's own private.claim_promo_campaign header
// for that genuinely atomic guarantee, enforced by a real row lock, not by this rate limiter).
//
// OUT OF SCOPE for this revision (see the promo-foundation task spec): reward/redemption UI,
// RevenueCat entitlement mutation, seeding any real campaign (85BLENDS included), and any change to
// referral-api, revenuecat-webhook, or RevenueCat/App Store Connect configuration. This function
// also never marks a promo_claims row 'redeemed' — that is exclusively a FUTURE revenuecat-webhook
// integration's job (see the migration's own header, Section on webhook integration).

import { createDatabaseClient, type Sql } from "../_shared/database.ts";
import { resolveReferralApiEnvConfig } from "../_shared/referral-api-env.ts";
import { hasMatchingClientApiKey } from "../_shared/referral-api-auth.ts";
import { constantTimeEqual } from "../_shared/hmac.ts";
import { sha256Hex } from "../_shared/hash.ts";
import { logWebhookEvent } from "../_shared/logging.ts";
import {
  parsePromoApiRequest,
  isValidPromoCodeFormat,
  type ValidatePromoRequest,
  type ClaimPromoRequest,
  type StatusPromoRequest,
} from "../_shared/promo-api-validation.ts";
import {
  buildValidateResponse,
  buildClaimSuccessResponse,
  buildStatusResponse,
  type CampaignPresentationInput,
} from "../_shared/promo-api-response.ts";
import { mapClaimOutcomeToError, buildSafeErrorLogMetadata } from "../_shared/promo-api-errors.ts";

const ATTEMPT_RATE_LIMIT_MAX_ATTEMPTS = 5;
const ATTEMPT_RATE_LIMIT_WINDOW_SECONDS = 60;

function sqlStateOf(error: unknown): unknown {
  return error && typeof error === "object" ? (error as { code?: unknown }).code : undefined;
}

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

type AuthResult =
  | { ok: true; participantId: string; installationId: string }
  | { ok: false; response: Response };

/** Authenticates an installation against the EXISTING referral_client_installations credential
 *  store — see this module's own header for why this is a deliberate copy of referral-api/
 *  index.ts's own authenticateInstallation, not an import from it. Never distinguishes "unknown
 *  installation" from "wrong secret" (same generic-401 philosophy as every other credential check
 *  in this codebase). */
async function authenticateInstallation(sql: Sql, installationId: string, installationSecret: string): Promise<AuthResult> {
  const rows = await sql<{ installation_secret_hash: string; participant_id: string }[]>`
    select c.installation_secret_hash, p.id as participant_id
    from private.referral_client_installations c
    join private.referral_participants p on p.installation_id = c.installation_id
    where c.installation_id = ${installationId}
  `;

  if (rows.length === 0) {
    return { ok: false, response: errorResponse(401, "invalid_installation_credentials") };
  }

  const suppliedHash = await hashSecret(installationSecret);
  if (!constantTimeEqual(suppliedHash, rows[0].installation_secret_hash)) {
    return { ok: false, response: errorResponse(401, "invalid_installation_credentials") };
  }

  return { ok: true, participantId: rows[0].participant_id, installationId };
}

interface CampaignStateRow {
  id: string;
  status: string;
  is_before_start: boolean;
  is_after_end: boolean;
  global_claim_limit: number | null;
  display_title: string;
  display_subtitle: string | null;
  display_badge: string | null;
  display_terms: string | null;
  cta_label: string | null;
}

/** All date-window arithmetic happens IN Postgres (`now() < starts_at` / `now() > ends_at`) rather
 *  than being pulled into JS and compared there — avoids any driver timestamp-type/timezone
 *  mismatch risk, and mirrors private.claim_promo_campaign's own logic exactly rather than
 *  re-deriving it a second, potentially-inconsistent way. */
async function loadCampaignByCode(sql: Sql, normalizedPublicCode: string): Promise<CampaignStateRow | null> {
  const rows = await sql<CampaignStateRow[]>`
    select
      id, status, global_claim_limit,
      display_title, display_subtitle, display_badge, display_terms, cta_label,
      (starts_at is not null and now() < starts_at) as is_before_start,
      (ends_at is not null and now() > ends_at) as is_after_end
    from private.promo_campaigns
    where normalized_public_code = ${normalizedPublicCode}
  `;
  return rows[0] ?? null;
}

interface CampaignDisplayRow {
  id: string;
  display_title: string;
  display_subtitle: string | null;
  display_badge: string | null;
  display_terms: string | null;
  cta_label: string | null;
}

async function loadCampaignDisplayById(sql: Sql, campaignId: string): Promise<CampaignDisplayRow | null> {
  const rows = await sql<CampaignDisplayRow[]>`
    select id, display_title, display_subtitle, display_badge, display_terms, cta_label
    from private.promo_campaigns
    where id = ${campaignId}
  `;
  return rows[0] ?? null;
}

function campaignPresentation(
  campaign: { display_title: string; display_subtitle: string | null; display_badge: string | null; display_terms: string | null; cta_label: string | null },
  normalizedPublicCode: string,
): CampaignPresentationInput {
  return {
    publicCode: normalizedPublicCode,
    displayTitle: campaign.display_title,
    displaySubtitle: campaign.display_subtitle,
    displayBadge: campaign.display_badge,
    displayTerms: campaign.display_terms,
    ctaLabel: campaign.cta_label,
  };
}

interface ExistingClaimRow {
  id: string;
  product_id: string;
  status: string;
  apple_code: string | null;
}

async function loadExistingClaim(sql: Sql, campaignId: string, participantId: string): Promise<ExistingClaimRow | null> {
  const rows = await sql<ExistingClaimRow[]>`
    select c.id, c.product_id, c.status, oc.apple_code
    from private.promo_claims c
    left join private.promo_offer_codes oc on oc.id = c.offer_code_id
    where c.campaign_id = ${campaignId} and c.participant_id = ${participantId}
  `;
  return rows[0] ?? null;
}

/** See this module's own header for why this is a plain, unlocked count-check rather than an
 *  advisory-locked one — a soft abuse deterrent, never the global claim cap's own hard guarantee. */
async function isRateLimited(sql: Sql, installationId: string): Promise<boolean> {
  const [{ count }] = await sql<{ count: string }[]>`
    select count(*)::text as count from private.promo_code_attempts
    where installation_id = ${installationId}
      and attempted_at >= now() - (${ATTEMPT_RATE_LIMIT_WINDOW_SECONDS} * interval '1 second')
  `;
  return Number(count) >= ATTEMPT_RATE_LIMIT_MAX_ATTEMPTS;
}

/** Records ONE genuinely new campaign-code attempt with its real outcome — callers must only
 *  invoke this for a code that does NOT already resolve to this installation's own existing,
 *  same-product claim (see this module's own header and the migration's own promo_code_attempts
 *  table comment for why "repeated retrieval of an already-claimed campaign" is exempt). */
async function recordAttempt(sql: Sql, installationId: string, normalizedPublicCode: string, outcome: string): Promise<void> {
  await sql`
    insert into private.promo_code_attempts (installation_id, normalized_public_code, outcome)
    values (${installationId}, ${normalizedPublicCode}, ${outcome})
  `;
}

async function handleValidate(sql: Sql, request: ValidatePromoRequest): Promise<Response> {
  const auth = await authenticateInstallation(sql, request.clientInstallationId, request.installationSecret);
  if (!auth.ok) return auth.response;

  // FORMAT-invalid codes are rejected before ever touching promo_code_attempts — mirrors
  // referral-api's own isValidReferralCodeFormat precedent exactly (see this module's header).
  if (!isValidPromoCodeFormat(request.publicCode)) {
    return errorResponse(400, "invalid_campaign_code");
  }

  const campaign = await loadCampaignByCode(sql, request.publicCode);
  const existingClaim = campaign ? await loadExistingClaim(sql, campaign.id, auth.participantId) : null;

  // Repeated validate of an already-claimed campaign never consumes the abuse budget (see this
  // module's header); every other case (campaign missing, or found but not yet claimed by this
  // installation) is a genuinely new/unresolved lookup and does.
  if (!existingClaim) {
    if (await isRateLimited(sql, auth.installationId)) {
      return errorResponse(429, "rate_limited");
    }
    await recordAttempt(sql, auth.installationId, request.publicCode, campaign ? "valid" : "campaign_not_found");
  }

  if (!campaign) {
    return errorResponse(404, "campaign_not_found");
  }

  // Read-only state checks, mirroring private.claim_promo_campaign's own — but never allocate
  // anything; validate must never consume a slot (this repo's promo-foundation task spec, Phase
  // 5). Skipped once this installation already holds a claim: an existing claim is immutable
  // regardless of the campaign's later state (see the STATUS action's own identical philosophy).
  if (existingClaim === null) {
    if (campaign.status !== "active") {
      return errorResponse(409, "campaign_not_active");
    }
    if (campaign.is_before_start) {
      return errorResponse(409, "campaign_not_started");
    }
    if (campaign.is_after_end) {
      return errorResponse(409, "campaign_ended");
    }
  }

  let claimLimitReached = false;
  if (campaign.global_claim_limit !== null) {
    const [{ count }] = await sql<{ count: string }[]>`
      select count(*)::text as count from private.promo_claims where campaign_id = ${campaign.id}
    `;
    claimLimitReached = Number(count) >= campaign.global_claim_limit;
  }

  const response = buildValidateResponse({
    ...campaignPresentation(campaign, request.publicCode),
    selectedProductId: request.selectedProductId,
    claimLimitReached,
    alreadyClaimed: existingClaim !== null,
    claimedProductId: existingClaim?.product_id ?? null,
  });
  return jsonResponse(200, response);
}

interface ClaimFunctionRow {
  outcome: string;
  claim_id: string | null;
  campaign_id: string | null;
  campaign_plan_offer_id: string | null;
  offer_code_id: string | null;
  apple_code: string | null;
  product_id: string | null;
}

async function handleClaim(sql: Sql, request: ClaimPromoRequest): Promise<Response> {
  const auth = await authenticateInstallation(sql, request.clientInstallationId, request.installationSecret);
  if (!auth.ok) return auth.response;

  if (!isValidPromoCodeFormat(request.publicCode)) {
    return errorResponse(400, "invalid_campaign_code");
  }

  if (await isRateLimited(sql, auth.installationId)) {
    return errorResponse(429, "rate_limited");
  }

  let rows: ClaimFunctionRow[];
  try {
    rows = await sql<ClaimFunctionRow[]>`
      select * from private.claim_promo_campaign(
        ${auth.participantId}::uuid,
        ${auth.installationId}::uuid,
        ${request.publicCode},
        ${request.selectedProductId}
      )
    `;
  } catch (error) {
    logWebhookEvent("error", "promo-api claim failure", buildSafeErrorLogMetadata(sqlStateOf(error)));
    return errorResponse(500, "internal_error");
  }

  const [result] = rows;

  // Repeated identical claim of an already-claimed campaign never consumes the abuse budget (see
  // this module's header); every other outcome — success, plan conflict, or any failure — is
  // recorded, so the diagnostics log reflects what genuinely happened.
  if (result.outcome !== "already_claimed") {
    await recordAttempt(sql, auth.installationId, request.publicCode, result.outcome);
  }

  if (result.outcome === "claimed" || result.outcome === "already_claimed") {
    const campaign = await loadCampaignDisplayById(sql, result.campaign_id as string);
    if (!campaign || !result.claim_id || !result.apple_code || !result.product_id) {
      // Structurally unreachable — the function just returned a live claim with these fields
      // populated together — but never assume away a defensive check on a response-building path.
      logWebhookEvent("error", "promo-api claim outcome missing expected fields", {});
      return errorResponse(500, "internal_error");
    }
    const response = buildClaimSuccessResponse({
      claimId: result.claim_id,
      campaign: campaignPresentation(campaign, request.publicCode),
      selectedProductId: result.product_id,
      appleCode: result.apple_code,
    });
    return jsonResponse(200, response);
  }

  const mapping = mapClaimOutcomeToError(result.outcome);
  return errorResponse(mapping.httpStatus, mapping.code);
}

async function handleStatus(sql: Sql, request: StatusPromoRequest): Promise<Response> {
  const auth = await authenticateInstallation(sql, request.clientInstallationId, request.installationSecret);
  if (!auth.ok) return auth.response;

  // Never touches promo_code_attempts at all, under any outcome — status is authenticated,
  // installation-scoped retrieval of already-known state, never a code guess (this repo's
  // promo-foundation task spec, Phase 5/11).
  if (!isValidPromoCodeFormat(request.publicCode)) {
    return errorResponse(400, "invalid_campaign_code");
  }

  const campaign = await loadCampaignByCode(sql, request.publicCode);
  if (!campaign) {
    return errorResponse(404, "campaign_not_found");
  }

  const existingClaim = await loadExistingClaim(sql, campaign.id, auth.participantId);
  const presentation = campaignPresentation(campaign, request.publicCode);

  if (!existingClaim) {
    const response = buildStatusResponse({
      status: "not_claimed",
      campaign: presentation,
      selectedProductId: null,
      appleCode: null,
    });
    return jsonResponse(200, response);
  }

  // Retrying redemption must not allocate another code — the same stored apple_code is returned
  // every time via the same redemption URL, whether the claim is still 'claimed' or has since been
  // marked 'redeemed' by a future webhook pass (see the migration's own header).
  const response = buildStatusResponse({
    status: existingClaim.status === "redeemed" ? "redeemed" : "claimed",
    campaign: presentation,
    selectedProductId: existingClaim.product_id,
    appleCode: existingClaim.apple_code,
  });
  return jsonResponse(200, response);
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  const envResult = resolveReferralApiEnvConfig((name) => Deno.env.get(name));
  if (!envResult.ok) {
    logWebhookEvent("error", "promo-api missing required configuration", { missing: envResult.missing.join(",") });
    return errorResponse(503, "service_unavailable");
  }
  const env = envResult.config;

  // Gate A — see this module's own header. Accepted if EITHER the `apikey` header OR the
  // `Authorization: Bearer` token matches ANY configured key — no precedence between the two
  // sources (see referral-api-auth.ts's hasMatchingClientApiKey for why `??` would be wrong here).
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
    return errorResponse(400, "invalid_request_body");
  }

  const parsed = parsePromoApiRequest(rawBody);
  if (!parsed.ok) {
    return errorResponse(400, parsed.code);
  }

  const sql = createDatabaseClient(env.supabaseDbUrl);
  try {
    switch (parsed.request.action) {
      case "validate":
        return await handleValidate(sql, parsed.request);
      case "claim":
        return await handleClaim(sql, parsed.request);
      case "status":
        return await handleStatus(sql, parsed.request);
    }
  } catch (error) {
    logWebhookEvent("error", "promo-api unexpected failure", buildSafeErrorLogMetadata(sqlStateOf(error)));
    return errorResponse(500, "internal_error");
  } finally {
    // Guarded exactly like referral-api/index.ts and revenuecat-webhook/index.ts: a
    // connection-close failure here must never replace an already-computed, otherwise-valid
    // response with an unhandled error.
    await sql.end({ timeout: 5 }).catch(() => {});
  }
});
