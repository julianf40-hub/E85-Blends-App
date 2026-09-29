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
    product_id: "prod_monthly_internal",
    ends_at: 1_800_000_000_000,
    entitlements: {
      items: [
        {
          lookup_key: "pro",
          products: {
            items: [
              {
                id: "prod_monthly_internal",
                store_identifier: "com.85blends.subscription.monthly",
              },
            ],
          },
        },
      ],
    },
    ...overrides,
  };
}

function entitlementForProduct(internalId: string, storeIdentifier: string, lookupKey = "pro") {
  return {
    lookup_key: lookupKey,
    products: {
      items: [{ id: internalId, store_identifier: storeIdentifier }],
    },
  };
}

// MARK: resolveActiveProAndProduct

test("resolveActiveProAndProduct: one qualifying subscription -> active with its Apple store identifier", () => {
  const result = resolveActiveProAndProduct([proSubscription()]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, "com.85blends.subscription.monthly");
});

test("resolveActiveProAndProduct: RevenueCat internal product_id is never returned as the store product id", () => {
  const result = resolveActiveProAndProduct([
    proSubscription({
      product_id: "prod_monthly_internal",
      entitlements: { items: [{ lookup_key: "pro" }] },
    }),
  ]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, null);
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
  const result = resolveActiveProAndProduct([
    proSubscription({ entitlements: { items: [entitlementForProduct("prod_monthly_internal", "com.85blends.subscription.monthly", "other")] } }),
  ]);
  assert.equal(result.proIsActive, false);
});

test("resolveActiveProAndProduct: multiple qualifying subscriptions -> latest expiration wins using store identifiers", () => {
  const earlier = proSubscription({
    product_id: "prod_monthly_internal",
    ends_at: 1_000,
    entitlements: { items: [entitlementForProduct("prod_monthly_internal", "com.85blends.subscription.monthly")] },
  });
  const later = proSubscription({
    product_id: "prod_annual_internal",
    ends_at: 2_000,
    entitlements: { items: [entitlementForProduct("prod_annual_internal", "com.85blends.subscription.annual")] },
  });
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

test("resolveActiveProAndProduct: active but every qualifying subscription lacks a resolvable expiration -> resolves first store identifier", () => {
  const result = resolveActiveProAndProduct([
    proSubscription({
      ends_at: undefined,
      current_period_ends_at: undefined,
      product_id: "prod_three_month_internal",
      entitlements: { items: [entitlementForProduct("prod_three_month_internal", "com.85blends.subscription.threemonth")] },
    }),
  ]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, "com.85blends.subscription.threemonth");
});

test("resolveActiveProAndProduct: active subscription with missing/malformed internal product_id -> active, but activeProductId is null", () => {
  const result = resolveActiveProAndProduct([proSubscription({ product_id: undefined })]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, null);
});

test("resolveActiveProAndProduct: missing matching embedded product -> active, but activeProductId is null", () => {
  const result = resolveActiveProAndProduct([
    proSubscription({
      product_id: "prod_monthly_internal",
      entitlements: { items: [entitlementForProduct("different_internal", "com.85blends.subscription.monthly")] },
    }),
  ]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, null);
});

test("resolveActiveProAndProduct: malformed/blank store_identifier -> active, but activeProductId is null", () => {
  const result = resolveActiveProAndProduct([
    proSubscription({
      entitlements: {
        items: [{ lookup_key: "pro", products: { items: [{ id: "prod_monthly_internal", store_identifier: "   " }] } }],
      },
    }),
  ]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, null);
});

test("resolveActiveProAndProduct: conflicting duplicate matches fail closed instead of guessing", () => {
  const result = resolveActiveProAndProduct([
    proSubscription({
      entitlements: {
        items: [
          {
            lookup_key: "pro",
            products: {
              items: [
                { id: "prod_monthly_internal", store_identifier: "com.85blends.subscription.monthly" },
                { id: "prod_monthly_internal", store_identifier: "com.85blends.subscription.annual" },
              ],
            },
          },
        ],
      },
    }),
  ]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, null);
});

test("resolveActiveProAndProduct: reports legacy quarterly STORE identifier when that is the active product", () => {
  const result = resolveActiveProAndProduct([
    proSubscription({
      product_id: "prod_legacy_quarterly_internal",
      entitlements: { items: [entitlementForProduct("prod_legacy_quarterly_internal", "com.85blends.subscription.quarterly")] },
    }),
  ]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, "com.85blends.subscription.quarterly");
});

// MARK: isSupportedReferralRewardProduct

test("isSupportedReferralRewardProduct: true only for the three shipping store product ids", () => {
  for (const id of REFERRAL_REWARD_SUPPORTED_PRODUCT_IDS) {
    assert.equal(isSupportedReferralRewardProduct(id), true);
  }
});

test("isSupportedReferralRewardProduct: false for the legacy quarterly product, RevenueCat internal ids, null, or unrelated ids", () => {
  assert.equal(isSupportedReferralRewardProduct("com.85blends.subscription.quarterly"), false);
  assert.equal(isSupportedReferralRewardProduct("prod_monthly_internal"), false);
  assert.equal(isSupportedReferralRewardProduct(null), false);
  assert.equal(isSupportedReferralRewardProduct("com.example.unrelated"), false);
});
