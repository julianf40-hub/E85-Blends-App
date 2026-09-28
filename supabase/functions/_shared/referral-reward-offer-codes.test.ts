// 85Blends 2.4.0 Referral Reward Redemption — Tests for referral-reward-offer-codes.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  determineReferralRewardFulfillmentCandidate,
  isReferralRewardOfferReference,
  REFERRAL_REWARD_OFFER_REFERENCE_NAMES,
  REFERRAL_REWARD_PRODUCT_BY_OFFER_REFERENCE,
  type ReferralRewardFulfillmentFields,
} from "./referral-reward-offer-codes.ts";

// MARK: isReferralRewardOfferReference

test("isReferralRewardOfferReference: true for exactly the three dedicated offer references", () => {
  for (const name of REFERRAL_REWARD_OFFER_REFERENCE_NAMES) {
    assert.equal(isReferralRewardOfferReference(name), true);
  }
});

test("isReferralRewardOfferReference: false for null, an unrelated string, or the public launch promo", () => {
  assert.equal(isReferralRewardOfferReference(null), false);
  assert.equal(isReferralRewardOfferReference("85BLENDS_LAUNCH_PROMO"), false);
  assert.equal(isReferralRewardOfferReference(""), false);
  assert.equal(isReferralRewardOfferReference("REFERRAL_REWARD_MONTHLY_1M_FREE_TYPO"), false);
});

// MARK: REFERRAL_REWARD_PRODUCT_BY_OFFER_REFERENCE

test("REFERRAL_REWARD_PRODUCT_BY_OFFER_REFERENCE: each reference maps to exactly its own product", () => {
  assert.equal(REFERRAL_REWARD_PRODUCT_BY_OFFER_REFERENCE.REFERRAL_REWARD_MONTHLY_1M_FREE, "com.85blends.subscription.monthly");
  assert.equal(REFERRAL_REWARD_PRODUCT_BY_OFFER_REFERENCE.REFERRAL_REWARD_3MONTH_1M_FREE, "com.85blends.subscription.threemonth");
  assert.equal(REFERRAL_REWARD_PRODUCT_BY_OFFER_REFERENCE.REFERRAL_REWARD_ANNUAL_1M_FREE, "com.85blends.subscription.annual");
});

// MARK: determineReferralRewardFulfillmentCandidate

function baseFields(overrides: Partial<ReferralRewardFulfillmentFields> = {}): ReferralRewardFulfillmentFields {
  return {
    environment: "PRODUCTION",
    offerCode: "REFERRAL_REWARD_MONTHLY_1M_FREE",
    productId: "com.85blends.subscription.monthly",
    transactionId: "txn_1",
    originalTransactionId: "orig_txn_1",
    ...overrides,
  };
}

const context = { appUserIdSet: ["user_1", "anon_1"], eventId: "event_1" };

test("determineReferralRewardFulfillmentCandidate: a valid PRODUCTION event with a matching offer/product -> a candidate", () => {
  const result = determineReferralRewardFulfillmentCandidate(baseFields(), context);
  assert.deepEqual(result, {
    appUserIdSet: ["user_1", "anon_1"],
    environment: "PRODUCTION",
    offerReferenceName: "REFERRAL_REWARD_MONTHLY_1M_FREE",
    productId: "com.85blends.subscription.monthly",
    transactionId: "txn_1",
    originalTransactionId: "orig_txn_1",
    eventId: "event_1",
  });
});

test("determineReferralRewardFulfillmentCandidate: works identically for the 3-month and annual offers", () => {
  const threeMonth = determineReferralRewardFulfillmentCandidate(
    baseFields({ offerCode: "REFERRAL_REWARD_3MONTH_1M_FREE", productId: "com.85blends.subscription.threemonth" }),
    context,
  );
  assert.equal(threeMonth?.offerReferenceName, "REFERRAL_REWARD_3MONTH_1M_FREE");

  const annual = determineReferralRewardFulfillmentCandidate(
    baseFields({ offerCode: "REFERRAL_REWARD_ANNUAL_1M_FREE", productId: "com.85blends.subscription.annual" }),
    context,
  );
  assert.equal(annual?.offerReferenceName, "REFERRAL_REWARD_ANNUAL_1M_FREE");
});

test("determineReferralRewardFulfillmentCandidate: no offer code at all -> null (ordinary purchase, not a candidate)", () => {
  assert.equal(determineReferralRewardFulfillmentCandidate(baseFields({ offerCode: null }), context), null);
});

test("determineReferralRewardFulfillmentCandidate: the public/unrelated launch promo offer code -> null, never fulfills a referral reward", () => {
  assert.equal(
    determineReferralRewardFulfillmentCandidate(baseFields({ offerCode: "85BLENDS_LAUNCH_PROMO" }), context),
    null,
  );
});

test("determineReferralRewardFulfillmentCandidate: SANDBOX -> null even with a valid offer code (v1 scope lock)", () => {
  assert.equal(
    determineReferralRewardFulfillmentCandidate(baseFields({ environment: "SANDBOX" }), context),
    null,
  );
});

test("determineReferralRewardFulfillmentCandidate: missing environment -> null", () => {
  assert.equal(
    determineReferralRewardFulfillmentCandidate(baseFields({ environment: null }), context),
    null,
  );
});

test("determineReferralRewardFulfillmentCandidate: offer reference paired with the WRONG product -> null, never trusted/corrected", () => {
  assert.equal(
    determineReferralRewardFulfillmentCandidate(
      baseFields({ offerCode: "REFERRAL_REWARD_MONTHLY_1M_FREE", productId: "com.85blends.subscription.annual" }),
      context,
    ),
    null,
  );
});

test("determineReferralRewardFulfillmentCandidate: missing product id -> null", () => {
  assert.equal(determineReferralRewardFulfillmentCandidate(baseFields({ productId: null }), context), null);
});

test("determineReferralRewardFulfillmentCandidate: missing transaction_id or original_transaction_id -> null", () => {
  assert.equal(determineReferralRewardFulfillmentCandidate(baseFields({ transactionId: null }), context), null);
  assert.equal(determineReferralRewardFulfillmentCandidate(baseFields({ originalTransactionId: null }), context), null);
});
