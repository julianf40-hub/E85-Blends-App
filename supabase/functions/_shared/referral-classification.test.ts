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
  });
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
    }),
    false,
  );
});

// MARK: isReferralRelevantEventType — cheap pre-filter

test("isReferralRelevantEventType: true only for INITIAL_PURCHASE, CANCELLATION, REFUND_REVERSED", () => {
  assert.equal(isReferralRelevantEventType("INITIAL_PURCHASE"), true);
  assert.equal(isReferralRelevantEventType("CANCELLATION"), true);
  assert.equal(isReferralRelevantEventType("REFUND_REVERSED"), true);
});

test("isReferralRelevantEventType: false for every other lifecycle event", () => {
  for (const type of ["RENEWAL", "PRODUCT_CHANGE", "EXPIRATION", "BILLING_ISSUE", "UNCANCELLATION", "TRANSFER", "TEST", "TEMPORARY_ENTITLEMENT_GRANT", "NON_RENEWING_PURCHASE"]) {
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
  });
});

test("determineReferralAction: canonicalProIsActive is passed through verbatim, never re-derived", () => {
  const envelope = {
    event: {
      type: "INITIAL_PURCHASE",
      environment: "PRODUCTION",
      period_type: "NORMAL",
      product_id: "com.85blends.subscription.monthly",
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

test("determineReferralAction: referral-irrelevant event type (e.g. RENEWAL) -> undefined without even reading the envelope", () => {
  const result = determineReferralAction(context({ eventType: "RENEWAL" }), { event: { type: "RENEWAL" } }, true);
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
