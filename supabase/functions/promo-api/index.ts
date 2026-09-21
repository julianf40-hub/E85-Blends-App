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
// isRateLimited() itself is also skipped entirely (not just its result recorded/unrecorded) for a
// retry of an installation's own existing SAME-PRODUCT claim, in validate, claim, AND status alike
// — idempotent retrieval of a fact this backend already confirmed is never a new code-guessing
// attempt, so it must never cost that installation any of its abuse budget, whichever action asks.
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
  deriveClaimStatus,
  type CampaignPresentationInput,
} from "../_shared/promo-api-response.ts";
import { mapClaimOutcomeToError, buildSafeErrorLogMetadata } from "../_shared/promo-api-errors.ts";
import { hasUnverifiedEligibilityScope } from "../_shared/promo-api-eligibility.ts";

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

  // An explicit `row = rows[0]` guard, not a `rows.length === 0` check followed by further
  // `rows[0]` access — under noUncheckedIndexedAccess, TS does not narrow rows[0] itself based on
  // a prior `.length` comparison, so this is both more honest AND the only form that is actually
  // provably safe (see this repo's own promo-foundation hardening pass: "harden array/result
  // access instead of copying older unchecked patterns").
  const row = rows[0];
  if (!row) {
    return { ok: false, response: errorResponse(401, "invalid_installation_credentials") };
  }

  const suppliedHash = await hashSecret(installationSecret);
  if (!constantTimeEqual(suppliedHash, row.installation_secret_hash)) {
    return { ok: false, response: errorResponse(401, "invalid_installation_credentials") };
  }

  return { ok: true, participantId: row.participant_id, installationId };
}

interface CampaignStateRow {
  id: string;
  status: string;
  is_before_start: boolean;
  is_after_end: boolean;
  global_claim_limit: number | null;
  eligibility_new_subscribers: boolean;
  eligibility_existing_subscribers: boolean;
  eligibility_expired_subscribers: boolean;
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
      eligibility_new_subscribers, eligibility_existing_subscribers, eligibility_expired_subscribers,
      display_title, display_subtitle, display_badge, display_terms, cta_label,
      (starts_at is not null and now() < starts_at) as is_before_start,
      (ends_at is not null and now() > ends_at) as is_after_end
    from private.promo_campaigns
    where normalized_public_code = ${normalizedPublicCode}
  `;
  return rows[0] ?? null;
}

interface PlanOfferRow {
  id: string;
}

/** Mirrors private.claim_promo_campaign's own "an ACTIVE plan-offer row for this product" check —
 *  used by validate (Phase ... hardening: "verify the selected active plan... before returning
 *  valid=true") so validate can never say a product looks claimable when claim would immediately
 *  refuse it with product_not_eligible. */
async function loadActivePlanOffer(sql: Sql, campaignId: string, productId: string): Promise<PlanOfferRow | null> {
  const rows = await sql<PlanOfferRow[]>`
    select id from private.promo_campaign_plan_offers
    where campaign_id = ${campaignId} and product_id = ${productId} and active = true
  `;
  return rows[0] ?? null;
}

/** Mirrors private.claim_promo_campaign's own pool-availability condition (available, unexpired)
 *  exactly — used by validate so it can never say a product looks claimable when the pool backing
 *  it is actually empty (Phase ... hardening: "usable non-expired code pool... before returning
 *  valid=true"). Read-only: never locks anything, never allocates. */
async function planOfferHasAvailableCode(sql: Sql, campaignPlanOfferId: string): Promise<boolean> {
  const rows = await sql<{ code_available: boolean }[]>`
    select exists (
      select 1 from private.promo_offer_codes
      where campaign_plan_offer_id = ${campaignPlanOfferId}
        and status = 'available'
        and apple_expires_at > now()
    ) as code_available
  `;
  return rows[0]?.code_available ?? false;
}

type ValidateOutcome =
  | "valid"
  | "campaign_not_active"
  | "campaign_not_started"
  | "campaign_ended"
  | "eligibility_unverified"
  | "product_not_eligible"
  | "offer_pool_exhausted";

/** Determines the SAME real outcome private.claim_promo_campaign would reach for this campaign +
 *  product, WITHOUT allocating anything — the one place validate's status/date/eligibility/
 *  product/pool checks live, so the value logged to promo_code_attempts and the value the HTTP
 *  response actually reflects can never drift apart (Phase ... hardening: "validate attempt
 *  logging must record the REAL outcome, not prematurely record 'valid'"). Global claim_limit is
 *  deliberately NOT checked here — that stays informational-only via claim_limit_reached on the
 *  success response, exactly as before this hardening pass; only the two NEW checks this pass adds
 *  (product eligibility, pool availability) turn into a hard, non-'valid' outcome. */
async function determineValidateOutcome(sql: Sql, campaign: CampaignStateRow, selectedProductId: string): Promise<ValidateOutcome> {
  if (campaign.status !== "active") return "campaign_not_active";
  if (campaign.is_before_start) return "campaign_not_started";
  if (campaign.is_after_end) return "campaign_ended";
  if (
    hasUnverifiedEligibilityScope({
      eligibilityNewSubscribers: campaign.eligibility_new_subscribers,
      eligibilityExistingSubscribers: campaign.eligibility_existing_subscribers,
      eligibilityExpiredSubscribers: campaign.eligibility_expired_subscribers,
    })
  ) {
    return "eligibility_unverified";
  }
  const planOffer = await loadActivePlanOffer(sql, campaign.id, selectedProductId);
  if (!planOffer) return "product_not_eligible";
  const hasAvailableCode = await planOfferHasAvailableCode(sql, planOffer.id);
  if (!hasAvailableCode) return "offer_pool_exhausted";
  return "valid";
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
  /** The claim's own code's status ('available' | 'issued' | 'redeemed' | 'void') — null only if
   *  the LEFT JOIN somehow finds no code row (structurally shouldn't happen now that
   *  promo_claims.offer_code_id is NOT NULL + FK-enforced, but the join stays LEFT defensively).
   *  Feeds deriveClaimStatus (see promo-api-response.ts). */
  offer_code_status: string | null;
  /** Computed IN SQL, not JS — same timestamp-comparison-risk avoidance as is_before_start/
   *  is_after_end above. False (never true) when offer_code_status is null. */
  offer_code_expired: boolean;
}

async function loadExistingClaim(sql: Sql, campaignId: string, participantId: string): Promise<ExistingClaimRow | null> {
  const rows = await sql<ExistingClaimRow[]>`
    select
      c.id, c.product_id, c.status, oc.apple_code, oc.status as offer_code_status,
      (oc.apple_expires_at is not null and oc.apple_expires_at <= now()) as offer_code_expired
    from private.promo_claims c
    left join private.promo_offer_codes oc on oc.id = c.offer_code_id
    where c.campaign_id = ${campaignId} and c.participant_id = ${participantId}
  `;
  return rows[0] ?? null;
}

/** A narrower lookup than loadExistingClaim: `claim` doesn't yet have a resolved campaign_id at
 *  the point it needs this (unlike validate/status, which already called loadCampaignByCode) — so
 *  this resolves directly from the normalized public code in one query, returning only the ONE
 *  field the rate-limit-bypass check actually needs (Phase ... hardening: "existing same-product
 *  claim bypasses the new-code rate limiter"). Returns null if no claim exists yet, exactly like a
 *  genuinely new attempt. */
async function loadExistingClaimProductByPublicCode(sql: Sql, normalizedPublicCode: string, participantId: string): Promise<string | null> {
  const rows = await sql<{ product_id: string }[]>`
    select c.product_id
    from private.promo_claims c
    join private.promo_campaigns pc on pc.id = c.campaign_id
    where pc.normalized_public_code = ${normalizedPublicCode} and c.participant_id = ${participantId}
  `;
  return rows[0]?.product_id ?? null;
}

/** See this module's own header for why this is a plain, unlocked count-check rather than an
 *  advisory-locked one — a soft abuse deterrent, never the global claim cap's own hard guarantee.
 *  Reads the count via `rows[0]?.count ?? "0"` rather than destructuring (`const [{ count }] =
 *  ...`) — a `select count(*)` always returns exactly one row in practice, but that is a runtime
 *  invariant of the query, not something the type system can see; destructuring would silently
 *  assume it and crash on a driver/refactor surprise, where an explicit fallback degrades safely
 *  to "not rate limited yet" instead (see this repo's own promo-foundation hardening pass). */
async function isRateLimited(sql: Sql, installationId: string): Promise<boolean> {
  const rows = await sql<{ count: string }[]>`
    select count(*)::text as count from private.promo_code_attempts
    where installation_id = ${installationId}
      and attempted_at >= now() - (${ATTEMPT_RATE_LIMIT_WINDOW_SECONDS} * interval '1 second')
  `;
  return Number(rows[0]?.count ?? "0") >= ATTEMPT_RATE_LIMIT_MAX_ATTEMPTS;
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

  // An existing claim is immutable regardless of the campaign's later state (see the STATUS
  // action's own identical philosophy) — never re-derives an outcome, never touches
  // promo_code_attempts at all (this module's header: repeated retrieval of an already-claimed
  // campaign never consumes the abuse budget). Guarding on `campaign` too (not just
  // `existingClaim`) is what actually lets TS narrow `campaign` to non-null below — existingClaim
  // is only ever non-null when campaign was too (loadExistingClaim is only called when campaign is
  // truthy, above), but TS cannot see that fact through a ternary alone.
  if (campaign && existingClaim) {
    const response = buildValidateResponse({
      ...campaignPresentation(campaign, request.publicCode),
      selectedProductId: request.selectedProductId,
      claimLimitReached: false,
      alreadyClaimed: true,
      claimedProductId: existingClaim.product_id,
    });
    return jsonResponse(200, response);
  }

  if (await isRateLimited(sql, auth.installationId)) {
    return errorResponse(429, "rate_limited");
  }

  // Determine the REAL outcome ONCE — the SAME value both drives the HTTP response below AND gets
  // logged to promo_code_attempts, closing the "recorded 'valid', then a later check actually
  // failed" gap (Phase ... hardening: "validate attempt logging must record the REAL outcome, not
  // prematurely record 'valid'"). Never allocates anything either way — validate must never
  // consume a slot (this repo's promo-foundation task spec, Phase 5).
  const outcome: ValidateOutcome | "campaign_not_found" = campaign
    ? await determineValidateOutcome(sql, campaign, request.selectedProductId)
    : "campaign_not_found";
  await recordAttempt(sql, auth.installationId, request.publicCode, outcome);

  if (!campaign) {
    return errorResponse(404, "campaign_not_found");
  }
  if (outcome === "campaign_not_active") return errorResponse(409, "campaign_not_active");
  if (outcome === "campaign_not_started") return errorResponse(409, "campaign_not_started");
  if (outcome === "campaign_ended") return errorResponse(409, "campaign_ended");
  if (outcome === "eligibility_unverified") return errorResponse(409, "eligibility_unverified");
  if (outcome === "product_not_eligible") return errorResponse(409, "product_not_eligible");
  if (outcome === "offer_pool_exhausted") return errorResponse(409, "offer_pool_exhausted");

  // outcome === "valid" from here — global_claim_limit stays INFORMATIONAL only (unchanged by this
  // hardening pass): a fully-claimed campaign still returns valid:true with claim_limit_reached
  // true, so the client can show "fully claimed" copy rather than a bare error.
  let claimLimitReached = false;
  if (campaign.global_claim_limit !== null) {
    const claimCountRows = await sql<{ count: string }[]>`
      select count(*)::text as count from private.promo_claims where campaign_id = ${campaign.id}
    `;
    claimLimitReached = Number(claimCountRows[0]?.count ?? "0") >= campaign.global_claim_limit;
  }

  const response = buildValidateResponse({
    ...campaignPresentation(campaign, request.publicCode),
    selectedProductId: request.selectedProductId,
    claimLimitReached,
    alreadyClaimed: false,
    claimedProductId: null,
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

  // A retry of an ALREADY-claimed campaign for the SAME product must never be rate-limited — it is
  // idempotent retrieval (private.claim_promo_campaign returns 'already_claimed' for it, and never
  // touches promo_code_attempts either — see recordAttempt's own call below), not a new code-guess
  // attempt, exactly mirroring validate/status's own existing-claim exemption (Phase ... hardening:
  // "existing same-product claim bypasses the new-code rate limiter"). A DIFFERENT product is NOT
  // exempt — that is a genuinely new decision (a plan change), still subject to the limiter.
  const existingProductId = await loadExistingClaimProductByPublicCode(sql, request.publicCode, auth.participantId);
  const isIdempotentRetry = existingProductId !== null && existingProductId === request.selectedProductId;

  if (!isIdempotentRetry && (await isRateLimited(sql, auth.installationId))) {
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

  // Explicit `rows[0]` + guard, not a destructure — private.claim_promo_campaign's own body always
  // returns exactly one row on every path, but that is a PL/pgSQL body invariant, not something
  // the type system (or a future refactor of that function) guarantees; this stays honest about
  // that instead of silently assuming it (see this repo's own promo-foundation hardening pass).
  const result = rows[0];
  if (!result) {
    logWebhookEvent("error", "promo-api claim returned no rows", {});
    return errorResponse(500, "internal_error");
  }

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

    if (result.outcome === "already_claimed") {
      // A freshly-'claimed' outcome is provably current — the code was JUST allocated inside this
      // SAME call to claim_promo_campaign, atomically. An idempotent 'already_claimed' retry
      // reflects a PAST claim instead, whose code may since have expired, been voided by ops, or
      // (once a future webhook pass exists) been marked redeemed — void/expired/redeemed claims
      // must never re-expose a redemption URL (Phase ... hardening), and `claim` is just as
      // reachable a way to retrieve one as `status` is. Re-derive the SAME way status does, rather
      // than trusting the apple_code claim_promo_campaign happened to return.
      const existingClaim = await loadExistingClaim(sql, result.campaign_id as string, auth.participantId);
      const currentStatus = existingClaim
        ? deriveClaimStatus({
            claimStatus: existingClaim.status,
            offerCodeStatus: existingClaim.offer_code_status,
            offerCodeExpired: existingClaim.offer_code_expired,
          })
        : "void"; // structurally unreachable (already_claimed implies a real row) — fail safe, not open.
      if (currentStatus !== "claimed") {
        return errorResponse(409, "claim_no_longer_redeemable");
      }
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

  // Retrying a currently-valid claim must not allocate another code — the same stored apple_code
  // is returned every time via the same redemption URL. void/expired/redeemed never re-expose it
  // (Phase ... hardening) — deriveClaimStatus (see promo-api-response.ts) combines the claim's OWN
  // status with its underlying code's status/expiry into the one status value that decides this;
  // buildStatusResponse itself additionally gates the URL on status === 'claimed' as a second,
  // independent safeguard, so passing appleCode through unconditionally here is safe.
  const status = deriveClaimStatus({
    claimStatus: existingClaim.status,
    offerCodeStatus: existingClaim.offer_code_status,
    offerCodeExpired: existingClaim.offer_code_expired,
  });
  const response = buildStatusResponse({
    status,
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
