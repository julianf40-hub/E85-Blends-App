// 85Blends 2.4.0 Referral Reward Redemption — Tests for referral-active-product.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  isSupportedReferralRewardProduct,
  REFERRAL_REWARD_SUPPORTED_PRODUCT_IDS,
  resolveActiveProAndProduct,
} from "./referral-active-product.ts";
import type { RevenueCatSubscription } from "./revenuecat-types.ts";

function proSubscription(overrides: Partial<RevenueCatSubscription> = {}): RevenueCatSubscription {
  return {
    gives_access: true,
    environment: "production",
    product_id: "com.85blends.subscription.monthly",
    ends_at: 1_800_000_000_000,
    entitlements: { items: [{ lookup_key: "pro" }] },
    ...overrides,
  };
}

// MARK: resolveActiveProAndProduct

test("resolveActiveProAndProduct: one qualifying subscription -> active with its own product id", () => {
  const result = resolveActiveProAndProduct([proSubscription()]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, "com.85blends.subscription.monthly");
});

test("resolveActiveProAndProduct: empty list -> not active, no product", () => {
  const result = resolveActiveProAndProduct([]);
  assert.equal(result.proIsActive, false);
  assert.equal(result.activeProductId, null);
});

test("resolveActiveProAndProduct: gives_access !== true (e.g. false, missing, or a truthy non-boolean) -> not active", () => {
  assert.equal(resolveActiveProAndProduct([proSubscription({ gives_access: false })]).proIsActive, false);
  assert.equal(resolveActiveProAndProduct([proSubscription({ gives_access: undefined })]).proIsActive, false);
  assert.equal(resolveActiveProAndProduct([proSubscription({ gives_access: "true" })]).proIsActive, false);
});

test("resolveActiveProAndProduct: subscription without the 'pro' entitlement -> not active", () => {
  const result = resolveActiveProAndProduct([proSubscription({ entitlements: { items: [{ lookup_key: "other" }] } })]);
  assert.equal(result.proIsActive, false);
});

test("resolveActiveProAndProduct: multiple qualifying subscriptions -> the one with the LATEST expiration wins", () => {
  const earlier = proSubscription({ product_id: "com.85blends.subscription.monthly", ends_at: 1_000 });
  const later = proSubscription({ product_id: "com.85blends.subscription.annual", ends_at: 2_000 });
  const result = resolveActiveProAndProduct([earlier, later]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, "com.85blends.subscription.annual");
});

test("resolveActiveProAndProduct: falls back to current_period_ends_at when ends_at is absent", () => {
  const result = resolveActiveProAndProduct([
    proSubscription({ ends_at: undefined, current_period_ends_at: 1_900_000_000_000 }),
  ]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, "com.85blends.subscription.monthly");
});

test("resolveActiveProAndProduct: active but every qualifying subscription lacks a resolvable expiration -> still active, reports the first one's product", () => {
  const result = resolveActiveProAndProduct([
    proSubscription({ ends_at: undefined, current_period_ends_at: undefined, product_id: "com.85blends.subscription.threemonth" }),
  ]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, "com.85blends.subscription.threemonth");
});

test("resolveActiveProAndProduct: active subscription with a missing/malformed product_id -> active, but activeProductId is null (never guessed)", () => {
  const result = resolveActiveProAndProduct([proSubscription({ product_id: undefined })]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, null);
});

test("resolveActiveProAndProduct: reports the legacy quarterly product id AS-IS when it's the active one (caller decides eligibility)", () => {
  const result = resolveActiveProAndProduct([proSubscription({ product_id: "com.85blends.subscription.quarterly" })]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, "com.85blends.subscription.quarterly");
});

// MARK: isSupportedReferralRewardProduct

test("isSupportedReferralRewardProduct: true only for the three shipping products", () => {
  for (const id of REFERRAL_REWARD_SUPPORTED_PRODUCT_IDS) {
    assert.equal(isSupportedReferralRewardProduct(id), true);
  }
});

test("isSupportedReferralRewardProduct: false for the legacy quarterly product, null, or an unrelated id", () => {
  assert.equal(isSupportedReferralRewardProduct("com.85blends.subscription.quarterly"), false);
  assert.equal(isSupportedReferralRewardProduct(null), false);
  assert.equal(isSupportedReferralRewardProduct("com.example.unrelated"), false);
});
