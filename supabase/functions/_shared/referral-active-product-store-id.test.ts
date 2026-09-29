// 85Blends 2.4.0 referral reward hotfix — verifies the active-product resolver consumes the
// canonical store identifier annotated by revenuecat-api.ts, without ever treating RevenueCat's
// internal product id as an Apple product id.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveActiveProAndProduct } from "./referral-active-product.ts";
import type { RevenueCatSubscription } from "./revenuecat-types.ts";

function activePro(overrides: Partial<RevenueCatSubscription> = {}): RevenueCatSubscription {
  return {
    gives_access: true,
    environment: "sandbox",
    product_id: "prod_monthly_internal_hotfix",
    store_product_id: "com.85blends.subscription.monthly",
    ends_at: 1_900_000_000_000,
    entitlements: { items: [{ lookup_key: "pro" }] },
    ...overrides,
  };
}

test("resolveActiveProAndProduct prefers canonical store_product_id", () => {
  const result = resolveActiveProAndProduct([activePro()]);
  assert.deepEqual(result, {
    proIsActive: true,
    activeProductId: "com.85blends.subscription.monthly",
  });
});

test("resolveActiveProAndProduct never falls back to RevenueCat internal product_id", () => {
  const result = resolveActiveProAndProduct([activePro({ store_product_id: undefined })]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.activeProductId, null);
});

test("latest active Pro subscription still wins after canonical mapping", () => {
  const earlier = activePro({
    product_id: "prod_monthly_internal_hotfix",
    store_product_id: "com.85blends.subscription.monthly",
    ends_at: 1_800_000_000_000,
  });
  const later = activePro({
    product_id: "prod_annual_internal_hotfix",
    store_product_id: "com.85blends.subscription.annual",
    ends_at: 1_900_000_000_000,
  });

  const result = resolveActiveProAndProduct([earlier, later]);
  assert.equal(result.activeProductId, "com.85blends.subscription.annual");
});
