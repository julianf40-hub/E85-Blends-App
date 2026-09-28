// 85Blends 2.4.0 — Referral Reward Redemption. Pure constants + classification for the three
// dedicated Apple subscription Offer Codes referral rewards are redeemed through.
//
// These three values ARE the App Store Connect subscription Offer Code's own REFERENCE NAME field
// (Subscriptions > offer codes > create) — the value Apple uses to identify the offer in App Store
// Connect's own Reports, and the SAME value RevenueCat's webhook exposes as `event.offer_code`.
// CORRECTION: an earlier revision of this file described these as a separate "Offer Identifier"
// distinct from an internal-only "Reference Name" — that two-field distinction belongs to a
// DIFFERENT Apple mechanism (signed Promotional Offers), not Offer Codes, which have only the one
// Reference Name field. See this feature's deployment documentation for exactly where in App Store
// Connect each of these three values must be entered.
//
// Pure — no I/O, no Deno-specific APIs. Fully unit-testable under Node (see
// referral-reward-offer-codes.test.ts).

import type { RevenueCatWebhookEnvironment } from "./revenuecat-types.ts";

export const REFERRAL_REWARD_OFFER_REFERENCE_NAMES = [
  "REFERRAL_REWARD_MONTHLY_1M_FREE",
  "REFERRAL_REWARD_3MONTH_1M_FREE",
  "REFERRAL_REWARD_ANNUAL_1M_FREE",
] as const;

export type ReferralRewardOfferReferenceName = (typeof REFERRAL_REWARD_OFFER_REFERENCE_NAMES)[number];

/** Permanent 1:1 pairing — mirrors the migration's own
 *  referral_reward_offer_codes_reference_matches_product CHECK constraint exactly. A mismatch
 *  between an event's own offer reference and its own product id is never trusted (see
 *  `determineReferralRewardFulfillmentCandidate` below) — defense in depth beyond the database
 *  constraint, in case a malformed/unexpected webhook payload ever paired them incorrectly. */
export const REFERRAL_REWARD_PRODUCT_BY_OFFER_REFERENCE: Record<ReferralRewardOfferReferenceName, string> = {
  REFERRAL_REWARD_MONTHLY_1M_FREE: "com.85blends.subscription.monthly",
  REFERRAL_REWARD_3MONTH_1M_FREE: "com.85blends.subscription.threemonth",
  REFERRAL_REWARD_ANNUAL_1M_FREE: "com.85blends.subscription.annual",
};

/** TRUE for any of the three dedicated referral-reward offer references — deliberately never true
 *  for `null`, an empty/unrelated string, or the existing public 85BLENDS launch promotion's own
 *  reference (whatever it is) — see this feature's task spec rule 7: "Generic/public promo offers
 *  ... must NEVER satisfy a referral reward." Used both to EXCLUDE a referral-reward redemption from
 *  ever counting as a qualifying paid referral (referral-classification.ts's isReferralQualifyingEvent)
 *  and to DETECT a fulfillment candidate (below) — the same predicate serves both directions on
 *  purpose, since both questions are really "is this transaction one of OUR OWN free reward months."
 */
export function isReferralRewardOfferReference(value: string | null): value is ReferralRewardOfferReferenceName {
  return value !== null && (REFERRAL_REWARD_OFFER_REFERENCE_NAMES as readonly string[]).includes(value);
}

/** The minimal fields a fulfillment candidate decision needs — a subset of
 *  referral-classification.ts's own ReferralWebhookFields, kept separate so this module has no
 *  dependency on that file (avoids a circular import; referral-classification.ts is the one that
 *  imports FROM this module, for the qualifying-event exclusion — see that file's own header). */
export interface ReferralRewardFulfillmentFields {
  environment: RevenueCatWebhookEnvironment | null;
  offerCode: string | null;
  productId: string | null;
  transactionId: string | null;
  originalTransactionId: string | null;
}

export interface ReferralRewardFulfillmentCandidate {
  appUserIdSet: string[];
  /** 85Blends 2.4.0 correctness hardening pass — SANDBOX or PRODUCTION, no longer hardcoded to
   *  PRODUCTION only. A reward/code can legitimately be SANDBOX-tagged (an operator-seeded test
   *  reward for pre-release Sandbox/TestFlight verification — see this feature's deployment
   *  documentation) — excluding every SANDBOX event here would make that verification impossible.
   *  The real cross-environment isolation guarantee lives in
   *  private.fulfill_referral_reward_offer_code itself, which only ever matches an issued code
   *  whose OWN `environment` column equals this exact value — see that function's own header. */
  environment: RevenueCatWebhookEnvironment;
  offerReferenceName: ReferralRewardOfferReferenceName;
  productId: string;
  transactionId: string;
  originalTransactionId: string;
  eventId: string;
}

/**
 * TRUE only when this webhook event both carries one of the three dedicated referral-reward offer
 * references AND every other fact needed to call private.fulfill_referral_reward_offer_code is
 * present and internally consistent. Deliberately NOT gated on the event's own `type` (INITIAL_PURCHASE
 * vs RENEWAL vs NON_RENEWING_PURCHASE, etc.) — per this feature's task spec, Apple's offer codes are
 * valid for New/Existing/Expired subscribers alike, which can surface as different RevenueCat event
 * types depending on the redeemer's prior subscription state; fulfillment matching is entirely
 * offer-reference + product + participant-identity driven, never event-type driven (see the
 * migration's own fulfill_referral_reward_offer_code header). Callers (revenuecat-webhook/index.ts)
 * run this check on every "normal" parsed event, regardless of type — see this feature's own report
 * for why that is an acceptable, low-cost check on every webhook delivery.
 *
 * A mismatch between the event's offer reference and its own product id (see
 * REFERRAL_REWARD_PRODUCT_BY_OFFER_REFERENCE) is treated as NOT a candidate at all — never trusted,
 * never "corrected" to the expected product.
 *
 * 85Blends 2.4.0 correctness hardening pass: `fields.environment` must be a KNOWN value (SANDBOX or
 * PRODUCTION) but is no longer required to be exactly PRODUCTION — see
 * `ReferralRewardFulfillmentCandidate.environment`'s own header for why, and
 * private.fulfill_referral_reward_offer_code for where the real per-environment isolation is
 * actually enforced (an exact match against the code's own `environment` column, never a blanket
 * exclusion of one environment here).
 */
export function determineReferralRewardFulfillmentCandidate(
  fields: ReferralRewardFulfillmentFields,
  context: { appUserIdSet: string[]; eventId: string },
): ReferralRewardFulfillmentCandidate | null {
  if (!isReferralRewardOfferReference(fields.offerCode)) return null;
  if (fields.environment === null) return null;
  if (fields.productId === null) return null;
  if (REFERRAL_REWARD_PRODUCT_BY_OFFER_REFERENCE[fields.offerCode] !== fields.productId) return null;
  if (fields.transactionId === null || fields.originalTransactionId === null) return null;

  return {
    appUserIdSet: context.appUserIdSet,
    environment: fields.environment,
    offerReferenceName: fields.offerCode,
    productId: fields.productId,
    transactionId: fields.transactionId,
    originalTransactionId: fields.originalTransactionId,
    eventId: context.eventId,
  };
}
