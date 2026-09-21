// 85Blends 2.4.0 — Generic promo campaign backend foundation. Pure response-shape builders — no
// Deno-specific APIs, Node-testable (see promo-api-response.test.ts). Takes already-fetched DB
// values as plain data; performs no I/O itself. Never returns raw internal identifiers
// (campaign_id, participant_id, installation_id, offer_code_id, RevenueCat identifiers) — only a
// campaign's own PUBLIC presentation copy, the claimant's OWN claim_id (safe: it identifies only
// their own row, never another participant's), and the redemption URL for their own claim.

const APPLE_REDEEM_BASE_URL = "https://apps.apple.com/redeem";
// The 85Blends App Store app id — the same constant value for every campaign/plan/code; only the
// `code` query parameter ever varies per claim.
const APPLE_REDEEM_APP_ID = "6762037468";

/**
 * Builds the one-time Apple Offer Code redemption URL:
 * https://apps.apple.com/redeem?ctx=offercodes&id=6762037468&code=<APPLE_ONE_TIME_CODE>
 * Pure string construction — no I/O, no logging. This is the ONLY place the raw Apple code is
 * ever embedded into a client-facing value; see promo-api/index.ts's own header for why it must
 * never additionally appear as a bare field anywhere in a JSON response, and must never be logged
 * (matching the migration's own promo_offer_codes.apple_code column comment).
 */
export function buildRedemptionUrl(appleCode: string): string {
  const params = new URLSearchParams({ ctx: "offercodes", id: APPLE_REDEEM_APP_ID, code: appleCode });
  return `${APPLE_REDEEM_BASE_URL}?${params.toString()}`;
}

export interface PromoCampaignPresentation {
  public_code: string;
  display_title: string;
  display_subtitle: string | null;
  display_badge: string | null;
  display_terms: string | null;
  cta_label: string | null;
}

export interface CampaignPresentationInput {
  publicCode: string;
  displayTitle: string;
  displaySubtitle: string | null;
  displayBadge: string | null;
  displayTerms: string | null;
  ctaLabel: string | null;
}

export function buildCampaignPresentation(input: CampaignPresentationInput): PromoCampaignPresentation {
  return {
    public_code: input.publicCode,
    display_title: input.displayTitle,
    display_subtitle: input.displaySubtitle,
    display_badge: input.displayBadge,
    display_terms: input.displayTerms,
    cta_label: input.ctaLabel,
  };
}

// MARK: — validate

export interface ValidateCampaignResult extends CampaignPresentationInput {
  selectedProductId: string;
  /** True once this campaign's global_claim_limit has been reached — checking/typing a code must
   *  never itself move this value; it only ever reports the CURRENT count, read-only. */
  claimLimitReached: boolean;
  /** True when this installation already holds ANY claim on this campaign (any product) — lets
   *  the client show "you already claimed this" without a second round trip. */
  alreadyClaimed: boolean;
  /** The product this installation actually claimed, if alreadyClaimed — independent of whatever
   *  selectedProductId the CURRENT validate request happened to ask about. */
  claimedProductId: string | null;
}

export interface ValidateSuccessResponse {
  valid: true;
  campaign: PromoCampaignPresentation & {
    selected_product_id: string;
    claim_limit_reached: boolean;
    already_claimed: boolean;
    claimed_product_id: string | null;
  };
}

/** Builds the `validate` action's success payload. Never issues/consumes anything — see this
 *  module's own header; the caller (promo-api/index.ts) must never call this from a code path that
 *  also allocates an Apple code. */
export function buildValidateResponse(input: ValidateCampaignResult): ValidateSuccessResponse {
  const presentation = buildCampaignPresentation(input);
  return {
    valid: true,
    campaign: {
      ...presentation,
      selected_product_id: input.selectedProductId,
      claim_limit_reached: input.claimLimitReached,
      already_claimed: input.alreadyClaimed,
      claimed_product_id: input.claimedProductId,
    },
  };
}

// MARK: — claim

export interface ClaimSuccessResponse {
  claim_id: string;
  campaign: PromoCampaignPresentation;
  selected_product_id: string;
  redemption_url: string;
}

export interface ClaimSuccessInput {
  claimId: string;
  campaign: CampaignPresentationInput;
  selectedProductId: string;
  appleCode: string;
}

/** Builds the `claim` action's success payload — used for a genuinely new claim AND for an
 *  idempotent repeat of an existing one (same claim_id/redemption_url either way, never a second
 *  Apple code allocated — see the migration's own private.claim_promo_campaign header). */
export function buildClaimSuccessResponse(input: ClaimSuccessInput): ClaimSuccessResponse {
  return {
    claim_id: input.claimId,
    campaign: buildCampaignPresentation(input.campaign),
    selected_product_id: input.selectedProductId,
    redemption_url: buildRedemptionUrl(input.appleCode),
  };
}

// MARK: — status

/** 'expired' and 'void' were added by a later hardening pass (see deriveClaimStatus's own header):
 *  a claim can independently outlive its own code's apple_expires_at, or either the claim or its
 *  code can independently be voided by ops — the external status vocabulary must be able to say so
 *  rather than collapsing either case into a misleading 'claimed' or 'not_claimed'. */
export type PromoClaimStatusValue = "not_claimed" | "claimed" | "expired" | "redeemed" | "void";

export interface StatusResponse {
  status: PromoClaimStatusValue;
  campaign: PromoCampaignPresentation;
  selected_product_id: string | null;
  redemption_url: string | null;
}

export interface StatusResponseInput {
  status: PromoClaimStatusValue;
  campaign: CampaignPresentationInput;
  selectedProductId: string | null;
  /** The claim's underlying Apple code, when one exists — the caller passes null for
   *  'not_claimed'. Whether it actually surfaces as a redemption_url is decided BELOW by status
   *  alone (see buildStatusResponse), not by whether this is present — a defense-in-depth
   *  guarantee that a caller bug passing a non-null code alongside a void/expired/redeemed status
   *  can never leak a URL for a code that is no longer safely usable/relevant. */
  appleCode: string | null;
}

export interface ClaimStatusDerivationInput {
  /** promo_claims.status: 'claimed' | 'redeemed' | 'void' by the DB's own CHECK constraint — typed
   *  as plain `string` here (not that literal union) deliberately, so deriveClaimStatus's own
   *  fail-closed handling of an unrecognized value is a real, exercised code path, not something
   *  the type system quietly rules out. */
  claimStatus: string;
  /** promo_offer_codes.status for this claim's own code: 'available' | 'issued' | 'redeemed' |
   *  'void' by the DB's own CHECK constraint — null only if the claim somehow has no resolvable
   *  code row (structurally shouldn't happen now that offer_code_id is NOT NULL + FK-enforced).
   *  'available' specifically would itself be a structural inconsistency (offer_code_id should
   *  only ever point at a code claim_promo_campaign just marked 'issued') — deriveClaimStatus
   *  treats it, null, and any other unrecognized value identically: fail closed, never 'claimed'. */
  offerCodeStatus: string | null;
  /** True when the code's own apple_expires_at has passed, computed in SQL (see index.ts's own
   *  loadExistingClaim query) to avoid any driver timestamp-comparison risk. */
  offerCodeExpired: boolean;
}

/**
 * Combines a claim's own status with its underlying Apple code's status/expiry into the ONE
 * external status vocabulary `status` returns. void/expired/redeemed never carry a redemption_url
 * (see buildStatusResponse) regardless of WHICH of the two underlying rows actually recorded it —
 * a claim can be independently voided by ops, or its code can independently expire or be voided,
 * and either must produce the same safe, non-URL-bearing external status.
 *
 * 'claimed' — the ONLY status buildStatusResponse ever attaches a redemption_url to — is
 * therefore a PRIVILEGE, not a default: it requires an EXACT valid combination
 * (claimStatus === 'claimed' AND offerCodeStatus === 'issued' AND offerCodeExpired === false),
 * checked last, only once every other, more specific state has been ruled out. Anything that
 * isn't one of the two recognized terminal states (void/redeemed) and also isn't that exact
 * combination — an unrecognized claimStatus, an offerCodeStatus that is 'available' (never
 * actually allocated to this claim despite the claim existing) or null (no resolvable code row)
 * or any other unrecognized value — fails closed to 'void' rather than falling through to
 * 'claimed' by default. A future, genuinely distinct "structurally invalid" status was considered
 * and rejected here: 'void' already means "this claim's code is not currently redeemable," which
 * is exactly what every one of these fail-closed cases is, and introducing a second status for the
 * same external meaning would only give a caller two things to check instead of one.
 *
 * Order (checked in this exact sequence): (1) void wins, either side. (2) redeemed wins, either
 * side. (3) any claimStatus other than 'claimed' fails closed to void. (4) any offerCodeStatus
 * other than 'issued' fails closed to void. (5) an expired-but-issued code is 'expired'. (6) only
 * then, 'claimed'.
 */
export function deriveClaimStatus(input: ClaimStatusDerivationInput): PromoClaimStatusValue {
  if (input.claimStatus === "void" || input.offerCodeStatus === "void") {
    return "void";
  }
  if (input.claimStatus === "redeemed" || input.offerCodeStatus === "redeemed") {
    return "redeemed";
  }
  if (input.claimStatus !== "claimed") {
    return "void";
  }
  if (input.offerCodeStatus !== "issued") {
    return "void";
  }
  if (input.offerCodeExpired) {
    return "expired";
  }
  return "claimed";
}

/** A redemption_url is ever emitted ONLY when status is exactly 'claimed' — void/expired/redeemed
 *  never re-expose it (Phase ... hardening): void/expired because the code is no longer usable,
 *  redeemed because it has already served its purpose and continuing to echo the raw code back is
 *  unnecessary. Gated here, at the one place every status response is built, rather than trusted to
 *  every call site — the same "enforce once, at the most authoritative layer" pattern this
 *  migration's own STORED GENERATED column and status-transition trigger already apply in SQL. */
export function buildStatusResponse(input: StatusResponseInput): StatusResponse {
  return {
    status: input.status,
    campaign: buildCampaignPresentation(input.campaign),
    selected_product_id: input.selectedProductId,
    redemption_url: input.status === "claimed" && input.appleCode ? buildRedemptionUrl(input.appleCode) : null,
  };
}
