// 85Blends 2.4.0 — Referral Reward Redemption. Pure constants + classification for the three
// dedicated Apple subscription Offer Codes referral rewards are redeemed through.
//
// These offer reference names identify the App Store Connect OFFER IDENTIFIER (the developer-
// facing value actually communicated through StoreKit/RevenueCat) — never App Store Connect's
// separate, internal-only "Reference Name" field, which is never exposed to StoreKit, RevenueCat,
// or any webhook. See this feature's deployment documentation for the exact App Store Connect field
// each of these three values must be entered into.
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
  environment: "PRODUCTION";
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
 */
export function determineReferralRewardFulfillmentCandidate(
  fields: ReferralRewardFulfillmentFields,
  context: { appUserIdSet: string[]; eventId: string },
): ReferralRewardFulfillmentCandidate | null {
  if (!isReferralRewardOfferReference(fields.offerCode)) return null;
  if (fields.environment !== "PRODUCTION") return null;
  if (fields.productId === null) return null;
  if (REFERRAL_REWARD_PRODUCT_BY_OFFER_REFERENCE[fields.offerCode] !== fields.productId) return null;
  if (fields.transactionId === null || fields.originalTransactionId === null) return null;

  return {
    appUserIdSet: context.appUserIdSet,
    environment: "PRODUCTION",
    offerReferenceName: fields.offerCode,
    productId: fields.productId,
    transactionId: fields.transactionId,
    originalTransactionId: fields.originalTransactionId,
    eventId: context.eventId,
  };
}
