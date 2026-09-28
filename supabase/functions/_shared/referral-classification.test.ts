// 85Blends 2.4.0 — Tests for referral-classification.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  determineReferralAction,
  extractReferralWebhookFields,
  isReferralQualifyingEvent,
  isReferralRefundReversalEvent,
  isReferralRelevantEventType,
  isReferralRenewalQualificationCandidate,
  isReferralRequalificationEvent,
  REFERRAL_QUALIFYING_PRODUCT_IDS,
  type NormalEventReferralContext,
  type ReferralWebhookFields,
} from "./referral-classification.ts";

// MARK: extractReferralWebhookFields

test("extractReferralWebhookFields: full normal INITIAL_PURCHASE envelope extracts every field", () => {
  const envelope = {
    event: {
      type: "INITIAL_PURCHASE",
      environment: "PRODUCTION",
      period_type: "NORMAL",
      product_id: "com.85blends.subscription.annual",
      transaction_id: "txn_1",
      original_transaction_id: "orig_txn_1",
      purchased_at_ms: 1_700_000_000_000,
    },
  };
  assert.deepEqual(extractReferralWebhookFields(envelope), {
    eventType: "INITIAL_PURCHASE",
    environment: "PRODUCTION",
    periodType: "NORMAL",
    productId: "com.85blends.subscription.annual",
    cancelReason: null,
    transactionId: "txn_1",
    originalTransactionId: "orig_txn_1",
    purchasedAtMs: 1_700_000_000_000,
    offerCode: null,
  });
});

// 85Blends 2.4.0 Referral Reward Redemption.
test("extractReferralWebhookFields: offer_code is extracted when present", () => {
  const envelope = {
    event: {
      type: "INITIAL_PURCHASE",
      environment: "PRODUCTION",
      period_type: "NORMAL",
      product_id: "com.85blends.subscription.monthly",
      transaction_id: "txn_1",
      original_transaction_id: "orig_txn_1",
      offer_code: "REFERRAL_REWARD_MONTHLY_1M_FREE",
    },
  };
  assert.equal(extractReferralWebhookFields(envelope)?.offerCode, "REFERRAL_REWARD_MONTHLY_1M_FREE");
});

test("extractReferralWebhookFields: missing optional fields become null, never throw or reject", () => {
  const envelope = { event: { type: "RENEWAL" } };
  assert.deepEqual(extractReferralWebhookFields(envelope), {
    eventType: "RENEWAL",
    environment: null,
    periodType: null,
    productId: null,
    cancelReason: null,
    transactionId: null,
    originalTransactionId: null,
    purchasedAtMs: null,
    offerCode: null,
  });
});

test("extractReferralWebhookFields: malformed envelope (no event object) returns null", () => {
  assert.equal(extractReferralWebhookFields({}), null);
  assert.equal(extractReferralWebhookFields(null), null);
  assert.equal(extractReferralWebhookFields("not an object"), null);
  assert.equal(extractReferralWebhookFields({ event: "not an object either" }), null);
});

test("extractReferralWebhookFields: event.type present but blank/non-string yields null", () => {
  assert.equal(extractReferralWebhookFields({ event: { type: "" } }), null);
  assert.equal(extractReferralWebhookFields({ event: { type: 123 } }), null);
});

// MARK: isReferralQualifyingEvent — Phase 16

function baseQualifyingFields(overrides: Partial<ReferralWebhookFields> = {}): ReferralWebhookFields {
  return {
    eventType: "INITIAL_PURCHASE",
    environment: "PRODUCTION",
    periodType: "NORMAL",
    productId: "com.85blends.subscription.monthly",
    cancelReason: null,
    transactionId: "txn_1",
    originalTransactionId: "orig_txn_1",
    purchasedAtMs: 1_700_000_000_000,
    offerCode: null,
    ...overrides,
  };
}

test("isReferralQualifyingEvent: INITIAL_PURCHASE + PRODUCTION + NORMAL + Monthly -> true", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ productId: "com.85blends.subscription.monthly" })), true);
});

test("isReferralQualifyingEvent: INITIAL_PURCHASE + PRODUCTION + NORMAL + 3-Month -> true", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ productId: "com.85blends.subscription.threemonth" })), true);
});

test("isReferralQualifyingEvent: INITIAL_PURCHASE + PRODUCTION + NORMAL + Annual -> true", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ productId: "com.85blends.subscription.annual" })), true);
});

test("isReferralQualifyingEvent: SANDBOX environment -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ environment: "SANDBOX" })), false);
});

test("isReferralQualifyingEvent: unknown/missing environment -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ environment: null })), false);
});

test("isReferralQualifyingEvent: legacy quarterly product -> false (never a qualifying product)", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ productId: "com.85blends.subscription.quarterly" })), false);
  assert.equal(REFERRAL_QUALIFYING_PRODUCT_IDS.includes("com.85blends.subscription.quarterly"), false);
});

test("isReferralQualifyingEvent: unrecognized product id -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ productId: "com.example.unrelated" })), false);
});

test("isReferralQualifyingEvent: missing product id -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ productId: null })), false);
});

test("isReferralQualifyingEvent: RENEWAL -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ eventType: "RENEWAL" })), false);
});

test("isReferralQualifyingEvent: PRODUCT_CHANGE -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ eventType: "PRODUCT_CHANGE" })), false);
});

test("isReferralQualifyingEvent: CANCELLATION -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ eventType: "CANCELLATION" })), false);
});

test("isReferralQualifyingEvent: EXPIRATION -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ eventType: "EXPIRATION" })), false);
});

test("isReferralQualifyingEvent: BILLING_ISSUE -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ eventType: "BILLING_ISSUE" })), false);
});

test("isReferralQualifyingEvent: UNCANCELLATION -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ eventType: "UNCANCELLATION" })), false);
});

test("isReferralQualifyingEvent: TRANSFER -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ eventType: "TRANSFER" })), false);
});

test("isReferralQualifyingEvent: TEST -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ eventType: "TEST" })), false);
});

test("isReferralQualifyingEvent: TEMPORARY_ENTITLEMENT_GRANT -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ eventType: "TEMPORARY_ENTITLEMENT_GRANT" })), false);
});

test("isReferralQualifyingEvent: NON_RENEWING_PURCHASE -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ eventType: "NON_RENEWING_PURCHASE" })), false);
});

test("isReferralQualifyingEvent: TRIAL period -> false (download-only/free trial, not a paid conversion)", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ periodType: "TRIAL" })), false);
});

test("isReferralQualifyingEvent: INTRO period -> false", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ periodType: "INTRO" })), false);
});

test("isReferralQualifyingEvent: PROMOTIONAL period -> false (promotional entitlement grant, not a paid conversion)", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ periodType: "PROMOTIONAL" })), false);
});

test("isReferralQualifyingEvent: missing period_type -> false (never assume NORMAL)", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ periodType: null })), false);
});

test("isReferralQualifyingEvent: price fields are never required — a fully qualifying event with no price/currency info still qualifies", () => {
  // RevenueCat documents price/currency fields as optional; this classifier never reads them at
  // all (ReferralWebhookFields doesn't even carry them) — this test exists to make that omission
  // an explicit, verified contract rather than an accident.
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields()), true);
});

test("isReferralQualifyingEvent: missing transaction_id -> false (integrity hardening: unreversible without it)", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ transactionId: null })), false);
});

test("isReferralQualifyingEvent: missing original_transaction_id -> false (integrity hardening: unreversible without it)", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ originalTransactionId: null })), false);
});

// MARK: 85Blends 2.4.0 Referral Reward Redemption — offer-code exclusion + RENEWAL qualification

test("isReferralQualifyingEvent: a referral-reward offer code on an otherwise-qualifying INITIAL_PURCHASE -> false", () => {
  for (const offerCode of [
    "REFERRAL_REWARD_MONTHLY_1M_FREE",
    "REFERRAL_REWARD_3MONTH_1M_FREE",
    "REFERRAL_REWARD_ANNUAL_1M_FREE",
  ]) {
    assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ offerCode })), false, `expected ${offerCode} to be excluded`);
  }
});

test("isReferralQualifyingEvent: an unrelated/public offer code never excludes an otherwise-qualifying purchase", () => {
  assert.equal(isReferralQualifyingEvent(baseQualifyingFields({ offerCode: "85BLENDS_LAUNCH_PROMO" })), true);
});

test("isReferralRenewalQualificationCandidate: RENEWAL + PRODUCTION + NORMAL + supported product -> true", () => {
  assert.equal(
    isReferralRenewalQualificationCandidate(baseQualifyingFields({ eventType: "RENEWAL" })),
    true,
  );
});

test("isReferralRenewalQualificationCandidate: INITIAL_PURCHASE (not RENEWAL) -> false — the two are mutually exclusive triggers", () => {
  assert.equal(isReferralRenewalQualificationCandidate(baseQualifyingFields()), false);
});

test("isReferralRenewalQualificationCandidate: a RENEWAL carrying a referral-reward offer code -> false", () => {
  assert.equal(
    isReferralRenewalQualificationCandidate(
      baseQualifyingFields({ eventType: "RENEWAL", offerCode: "REFERRAL_REWARD_ANNUAL_1M_FREE" }),
    ),
    false,
  );
});

test("isReferralRenewalQualificationCandidate: SANDBOX RENEWAL -> false", () => {
  assert.equal(
    isReferralRenewalQualificationCandidate(baseQualifyingFields({ eventType: "RENEWAL", environment: "SANDBOX" })),
    false,
  );
});

test("isReferralRenewalQualificationCandidate: legacy quarterly product -> false", () => {
  assert.equal(
    isReferralRenewalQualificationCandidate(
      baseQualifyingFields({ eventType: "RENEWAL", productId: "com.85blends.subscription.quarterly" }),
    ),
    false,
  );
});

test("isReferralRenewalQualificationCandidate: missing transaction/original_transaction id -> false", () => {
  assert.equal(
    isReferralRenewalQualificationCandidate(
      baseQualifyingFields({ eventType: "RENEWAL", transactionId: null }),
    ),
    false,
  );
  assert.equal(
    isReferralRenewalQualificationCandidate(
      baseQualifyingFields({ eventType: "RENEWAL", originalTransactionId: null }),
    ),
    false,
  );
});

// MARK: isReferralRefundReversalEvent — Phase 17

function baseRefundFields(overrides: Partial<ReferralWebhookFields> = {}): ReferralWebhookFields {
  return {
    eventType: "CANCELLATION",
    environment: "PRODUCTION",
    periodType: null,
    productId: null,
    cancelReason: "CUSTOMER_SUPPORT",
    transactionId: "txn_1",
    originalTransactionId: "orig_txn_1",
    purchasedAtMs: null,
    offerCode: null,
    ...overrides,
  };
}

test("isReferralRefundReversalEvent: CANCELLATION + PRODUCTION + CUSTOMER_SUPPORT -> reversal candidate", () => {
  assert.equal(isReferralRefundReversalEvent(baseRefundFields()), true);
});

test("isReferralRefundReversalEvent: CANCELLATION + UNSUBSCRIBE -> no reversal", () => {
  assert.equal(isReferralRefundReversalEvent(baseRefundFields({ cancelReason: "UNSUBSCRIBE" })), false);
});

test("isReferralRefundReversalEvent: CANCELLATION + BILLING_ERROR -> no reversal", () => {
  assert.equal(isReferralRefundReversalEvent(baseRefundFields({ cancelReason: "BILLING_ERROR" })), false);
});

test("isReferralRefundReversalEvent: missing cancel_reason -> no reversal (never assume support-initiated)", () => {
  assert.equal(isReferralRefundReversalEvent(baseRefundFields({ cancelReason: null })), false);
});

test("isReferralRefundReversalEvent: SANDBOX CUSTOMER_SUPPORT -> no production reversal", () => {
  assert.equal(isReferralRefundReversalEvent(baseRefundFields({ environment: "SANDBOX" })), false);
});

test("isReferralRefundReversalEvent: non-CANCELLATION event type -> false even with CUSTOMER_SUPPORT reason", () => {
  assert.equal(isReferralRefundReversalEvent(baseRefundFields({ eventType: "EXPIRATION" })), false);
});

test("isReferralRefundReversalEvent: missing original_transaction_id -> false (no possible match, no referral action)", () => {
  assert.equal(isReferralRefundReversalEvent(baseRefundFields({ originalTransactionId: null })), false);
});

// This module only classifies the EVENT; matching against the stored qualifying_original_transaction_id
// happens in the database function (see the referral migration) — a mismatched original_transaction_id
// is therefore not something this pure classifier can or should express. Documented here rather than
// tested as a no-op, consistent with how customer-resolution.ts's tests draw the same line at what a
// pure classifier can decide vs. what only a database lookup can.

// MARK: isReferralRequalificationEvent — Phase 17 (REFUND_REVERSED)

test("isReferralRequalificationEvent: PRODUCTION REFUND_REVERSED -> requalification candidate", () => {
  assert.equal(
    isReferralRequalificationEvent({
      eventType: "REFUND_REVERSED",
      environment: "PRODUCTION",
      periodType: null,
      productId: null,
      cancelReason: null,
      transactionId: "txn_1",
      originalTransactionId: "orig_txn_1",
      purchasedAtMs: null,
      offerCode: null,
    }),
    true,
  );
});

test("isReferralRequalificationEvent: SANDBOX REFUND_REVERSED -> false", () => {
  assert.equal(
    isReferralRequalificationEvent({
      eventType: "REFUND_REVERSED",
      environment: "SANDBOX",
      periodType: null,
      productId: null,
      cancelReason: null,
      transactionId: null,
      originalTransactionId: null,
      purchasedAtMs: null,
      offerCode: null,
    }),
    false,
  );
});

test("isReferralRequalificationEvent: other event types -> false", () => {
  assert.equal(
    isReferralRequalificationEvent({
      eventType: "RENEWAL",
      environment: "PRODUCTION",
      periodType: null,
      productId: null,
      cancelReason: null,
      transactionId: null,
      originalTransactionId: null,
      purchasedAtMs: null,
      offerCode: null,
    }),
    false,
  );
});

test("isReferralRequalificationEvent: missing original_transaction_id -> false (no possible match, no requalification action)", () => {
  assert.equal(
    isReferralRequalificationEvent({
      eventType: "REFUND_REVERSED",
      environment: "PRODUCTION",
      periodType: null,
      productId: null,
      cancelReason: null,
      transactionId: null,
      originalTransactionId: null,
      purchasedAtMs: null,
      offerCode: null,
    }),
    false,
  );
});

// MARK: isReferralRelevantEventType — cheap pre-filter

test("isReferralRelevantEventType: true for INITIAL_PURCHASE, RENEWAL, CANCELLATION, REFUND_REVERSED", () => {
  assert.equal(isReferralRelevantEventType("INITIAL_PURCHASE"), true);
  // 85Blends 2.4.0 Referral Reward Redemption — RENEWAL is now relevant (see
  // isReferralRenewalQualificationCandidate's own header for why).
  assert.equal(isReferralRelevantEventType("RENEWAL"), true);
  assert.equal(isReferralRelevantEventType("CANCELLATION"), true);
  assert.equal(isReferralRelevantEventType("REFUND_REVERSED"), true);
});

test("isReferralRelevantEventType: false for every other lifecycle event", () => {
  for (const type of ["PRODUCT_CHANGE", "EXPIRATION", "BILLING_ISSUE", "UNCANCELLATION", "TRANSFER", "TEST", "TEMPORARY_ENTITLEMENT_GRANT", "NON_RENEWING_PURCHASE"]) {
    assert.equal(isReferralRelevantEventType(type), false, `expected ${type} to be referral-irrelevant`);
  }
});

// MARK: determineReferralAction — index.ts's actual orchestration entry point

function context(overrides: Partial<NormalEventReferralContext> = {}): NormalEventReferralContext {
  return {
    eventType: "INITIAL_PURCHASE",
    environment: "PRODUCTION",
    aliasSet: ["user_1", "anon_1"],
    eventId: "event_1",
    ...overrides,
  };
}

test("determineReferralAction: qualifying INITIAL_PURCHASE -> a 'qualify' action carrying the event's own fields", () => {
  const envelope = {
    event: {
      type: "INITIAL_PURCHASE",
      environment: "PRODUCTION",
      period_type: "NORMAL",
      product_id: "com.85blends.subscription.annual",
      transaction_id: "txn_1",
      original_transaction_id: "orig_txn_1",
      purchased_at_ms: 1_700_000_000_000,
    },
  };
  const result = determineReferralAction(context(), envelope, true);
  assert.deepEqual(result, {
    action: "qualify",
    appUserIdSet: ["user_1", "anon_1"],
    environment: "PRODUCTION",
    eventId: "event_1",
    purchasedAtMs: 1_700_000_000_000,
    productId: "com.85blends.subscription.annual",
    transactionId: "txn_1",
    originalTransactionId: "orig_txn_1",
    canonicalProIsActive: true,
    // 85Blends 2.4.0 Referral Reward Redemption — never required for an INITIAL_PURCHASE-triggered
    // qualify (see isReferralRenewalQualificationCandidate's own header for why only a RENEWAL-
    // triggered one needs the extra database-backed proof).
    requiresRewardRedemptionProof: false,
  });
});

// 85Blends 2.4.0 Referral Reward Redemption.
test("determineReferralAction: qualifying RENEWAL -> a 'qualify' action with requiresRewardRedemptionProof true", () => {
  const envelope = {
    event: {
      type: "RENEWAL",
      environment: "PRODUCTION",
      period_type: "NORMAL",
      product_id: "com.85blends.subscription.monthly",
      transaction_id: "txn_2",
      original_transaction_id: "orig_txn_1",
      purchased_at_ms: 1_700_100_000_000,
    },
  };
  const result = determineReferralAction(context({ eventType: "RENEWAL" }), envelope, true);
  assert.equal(result?.action, "qualify");
  assert.equal(result?.requiresRewardRedemptionProof, true);
  assert.equal(result?.purchasedAtMs, 1_700_100_000_000);
});

test("determineReferralAction: a RENEWAL carrying a referral-reward offer code never qualifies (excluded like any other offer-code purchase)", () => {
  const envelope = {
    event: {
      type: "RENEWAL",
      environment: "PRODUCTION",
      period_type: "NORMAL",
      product_id: "com.85blends.subscription.monthly",
      transaction_id: "txn_2",
      original_transaction_id: "orig_txn_1",
      offer_code: "REFERRAL_REWARD_MONTHLY_1M_FREE",
    },
  };
  const result = determineReferralAction(context({ eventType: "RENEWAL" }), envelope, true);
  assert.equal(result, undefined);
});

test("determineReferralAction: canonicalProIsActive is passed through verbatim, never re-derived", () => {
  const envelope = {
    event: {
      type: "INITIAL_PURCHASE",
      environment: "PRODUCTION",
      period_type: "NORMAL",
      product_id: "com.85blends.subscription.monthly",
      transaction_id: "txn_1",
      original_transaction_id: "orig_txn_1",
    },
  };
  const result = determineReferralAction(context(), envelope, false);
  assert.equal(result?.canonicalProIsActive, false);
});

test("determineReferralAction: CUSTOMER_SUPPORT CANCELLATION -> a 'refund_reversal' action", () => {
  const envelope = {
    event: {
      type: "CANCELLATION",
      environment: "PRODUCTION",
      cancel_reason: "CUSTOMER_SUPPORT",
      original_transaction_id: "orig_txn_1",
    },
  };
  const result = determineReferralAction(context({ eventType: "CANCELLATION" }), envelope, false);
  assert.equal(result?.action, "refund_reversal");
  assert.equal(result?.purchasedAtMs, null);
  assert.equal(result?.originalTransactionId, "orig_txn_1");
});

test("determineReferralAction: PRODUCTION REFUND_REVERSED -> a 'refund_reversed' action", () => {
  const envelope = {
    event: {
      type: "REFUND_REVERSED",
      environment: "PRODUCTION",
      original_transaction_id: "orig_txn_1",
    },
  };
  const result = determineReferralAction(context({ eventType: "REFUND_REVERSED" }), envelope, true);
  assert.equal(result?.action, "refund_reversed");
});

test("determineReferralAction: referral-irrelevant event type (e.g. PRODUCT_CHANGE) -> undefined without even reading the envelope", () => {
  const result = determineReferralAction(context({ eventType: "PRODUCT_CHANGE" }), { event: { type: "PRODUCT_CHANGE" } }, true);
  assert.equal(result, undefined);
});

test("determineReferralAction: a non-qualifying-shaped RENEWAL (e.g. SANDBOX) -> undefined, never a bare 'relevant type' pass-through", () => {
  const envelope = {
    event: {
      type: "RENEWAL",
      environment: "SANDBOX",
      period_type: "NORMAL",
      product_id: "com.85blends.subscription.monthly",
      transaction_id: "txn_2",
      original_transaction_id: "orig_txn_1",
    },
  };
  const result = determineReferralAction(context({ eventType: "RENEWAL", environment: "SANDBOX" }), envelope, true);
  assert.equal(result, undefined);
});

test("determineReferralAction: INITIAL_PURCHASE that doesn't classify as qualifying (e.g. SANDBOX) -> undefined", () => {
  const envelope = {
    event: {
      type: "INITIAL_PURCHASE",
      environment: "SANDBOX",
      period_type: "NORMAL",
      product_id: "com.85blends.subscription.monthly",
    },
  };
  const result = determineReferralAction(context({ environment: "SANDBOX" }), envelope, true);
  assert.equal(result, undefined);
});

test("determineReferralAction: CANCELLATION with a non-support reason -> undefined (no reversal action)", () => {
  const envelope = {
    event: { type: "CANCELLATION", environment: "PRODUCTION", cancel_reason: "UNSUBSCRIBE" },
  };
  const result = determineReferralAction(context({ eventType: "CANCELLATION" }), envelope, true);
  assert.equal(result, undefined);
});

test("determineReferralAction: relevant event type but unparseable envelope -> undefined, never throws", () => {
  const result = determineReferralAction(context(), "not an object", true);
  assert.equal(result, undefined);
});
