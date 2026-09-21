// 85Blends 2.4.0 — Generic promo campaign backend foundation. Pure error-message mapping — no
// Deno-specific APIs, Node-testable (see promo-api-errors.test.ts). The one place a
// private.claim_promo_campaign `outcome` value (or another internal failure reason) is translated
// into a safe, stable, typed API response code.
//
// Reuses referral-api-errors.ts's buildSafeErrorLogMetadata directly — that helper is fully
// generic (a raw caught-error SQLSTATE in, a safe structured log object out, with zero
// referral-specific logic) rather than being redefined here. referral-api-errors.ts itself is
// never modified by this addition.
//
// Never leak: raw SQL errors, constraint names, an Apple one-time-use code, an installation
// secret/hash, a full RevenueCat identity, a participant/installation/claim UUID beyond what the
// client contract already requires (see promo-api-response.ts), or any private table name — every
// mapping below returns only one of the fixed, stable machine-readable codes this repo's
// promo-foundation task spec lists.

export { buildSafeErrorLogMetadata } from "./referral-api-errors.ts";

export interface PromoApiErrorMapping {
  httpStatus: number;
  code: string;
}

/**
 * Maps private.claim_promo_campaign's own `outcome` column (see the migration's RETURNS TABLE) to
 * an HTTP status + stable error code. 'claimed' and 'already_claimed' are NOT failures — the
 * caller (promo-api/index.ts) branches on those directly into a 200 success response and never
 * reaches this map for them. 'claim_plan_conflict' IS mapped here as a genuine error (409):
 * exactly like referral-api's own handling of a DIFFERENT referral code once one is already
 * applied, a request for a plan that conflicts with an already-claimed one is a hard failure, not
 * a silent second allocation — see the migration's own claim_promo_campaign header for why the
 * SAME product re-requested is idempotent success while a DIFFERENT one is this 409 instead.
 */
const CLAIM_OUTCOME_ERROR_MAP: Record<string, PromoApiErrorMapping> = {
  campaign_not_found: { httpStatus: 404, code: "campaign_not_found" },
  campaign_not_active: { httpStatus: 409, code: "campaign_not_active" },
  campaign_not_started: { httpStatus: 409, code: "campaign_not_started" },
  campaign_ended: { httpStatus: 409, code: "campaign_ended" },
  product_not_eligible: { httpStatus: 409, code: "product_not_eligible" },
  campaign_exhausted: { httpStatus: 409, code: "campaign_exhausted" },
  offer_pool_exhausted: { httpStatus: 409, code: "offer_pool_exhausted" },
  claim_plan_conflict: { httpStatus: 409, code: "claim_plan_conflict" },
};

/** Falls back to a generic 500 internal_error for any outcome value this map doesn't recognize —
 *  never leaks the raw outcome string itself in that fallback case. */
export function mapClaimOutcomeToError(outcome: string): PromoApiErrorMapping {
  return CLAIM_OUTCOME_ERROR_MAP[outcome] ?? { httpStatus: 500, code: "internal_error" };
}
