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

export type PromoClaimStatusValue = "not_claimed" | "claimed" | "redeemed";

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
  /** Present only when status is 'claimed' or 'redeemed' — the caller passes null for
   *  'not_claimed'. Retrying a valid, unexpired claim's redemption must not allocate another code
   *  (see the task spec's own Phase 5 STATUS section) — this returns the SAME code every time. */
  appleCode: string | null;
}

export function buildStatusResponse(input: StatusResponseInput): StatusResponse {
  return {
    status: input.status,
    campaign: buildCampaignPresentation(input.campaign),
    selected_product_id: input.selectedProductId,
    redemption_url: input.appleCode ? buildRedemptionUrl(input.appleCode) : null,
  };
}
