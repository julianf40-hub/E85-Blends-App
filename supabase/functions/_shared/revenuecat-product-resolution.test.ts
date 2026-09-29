// 85Blends 2.4.0 referral reward hotfix — verifies the customer-subscriptions client resolves
// RevenueCat's internal product id through the SAME subscription's entitlement list, without making
// canonical entitlement refresh depend on that secondary metadata lookup.

import { test } from "node:test";
import assert from "node:assert/strict";
import { fetchCustomerSubscriptions } from "./revenuecat-api.ts";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function activeProSubscription(productId: string, subscriptionId = "sub_monthly_hotfix") {
  return {
    id: subscriptionId,
    gives_access: true,
    environment: "sandbox",
    product_id: productId,
    ends_at: 1_900_000_000_000,
    entitlements: { items: [{ lookup_key: "pro" }] },
  };
}

function proEntitlement(productId: string, storeIdentifier: string) {
  return {
    object: "list",
    items: [
      {
        lookup_key: "pro",
        products: {
          object: "list",
          items: [{ id: productId, store_identifier: storeIdentifier }],
        },
      },
    ],
    next_page: null,
  };
}

test("fetchCustomerSubscriptions resolves an active Pro internal product id through subscription entitlements", async () => {
  const calls: string[] = [];
  const fetchImpl = (async (url: string) => {
    calls.push(url);
    if (url.includes("/customers/")) {
      return jsonResponse(200, { items: [activeProSubscription("prod_monthly_hotfix")], next_page: null });
    }
    assert.match(url, /\/v2\/projects\/proj_hotfix\/subscriptions\/sub_monthly_hotfix\/entitlements\?limit=100$/);
    return jsonResponse(200, proEntitlement("prod_monthly_hotfix", "com.85blends.subscription.monthly"));
  }) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_hotfix", secretApiKey: "secret", fetchImpl },
    "sandbox_user",
    "sandbox",
  );

  assert.equal(result.kind, "ok");
  if (result.kind === "ok") {
    assert.equal(result.subscriptions.length, 1);
    assert.equal(result.subscriptions[0].store_product_id, "com.85blends.subscription.monthly");
  }
  assert.equal(calls.length, 2);
});

test("subscription entitlement lookup failure is non-fatal to canonical subscription refresh", async () => {
  const fetchImpl = (async (url: string) => {
    if (url.includes("/customers/")) {
      return jsonResponse(200, { items: [activeProSubscription("prod_permission_denied_hotfix")], next_page: null });
    }
    return new Response(null, { status: 403 });
  }) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_hotfix", secretApiKey: "secret", fetchImpl },
    "sandbox_user",
    "sandbox",
  );

  assert.equal(result.kind, "ok");
  if (result.kind === "ok") {
    assert.equal(result.subscriptions[0].store_product_id, undefined);
    assert.equal(result.subscriptions[0].product_id, "prod_permission_denied_hotfix");
  }
});

test("non-Pro subscriptions do not trigger subscription entitlement lookups", async () => {
  let calls = 0;
  const fetchImpl = (async () => {
    calls += 1;
    return jsonResponse(200, {
      items: [{ id: "sub_other", gives_access: true, environment: "sandbox", product_id: "prod_other", entitlements: { items: [{ lookup_key: "other" }] } }],
      next_page: null,
    });
  }) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_hotfix", secretApiKey: "secret", fetchImpl },
    "sandbox_user",
    "sandbox",
  );

  assert.equal(result.kind, "ok");
  assert.equal(calls, 1);
});

test("ambiguous store identifiers fail closed", async () => {
  const fetchImpl = (async (url: string) => {
    if (url.includes("/customers/")) {
      return jsonResponse(200, { items: [activeProSubscription("prod_ambiguous")], next_page: null });
    }
    return jsonResponse(200, {
      object: "list",
      items: [{
        lookup_key: "pro",
        products: {
          items: [
            { id: "prod_ambiguous", store_identifier: "com.85blends.subscription.monthly" },
            { id: "prod_ambiguous", store_identifier: "com.85blends.subscription.annual" },
          ],
        },
      }],
      next_page: null,
    });
  }) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_hotfix", secretApiKey: "secret", fetchImpl },
    "sandbox_user",
    "sandbox",
  );

  assert.equal(result.kind, "ok");
  if (result.kind === "ok") assert.equal(result.subscriptions[0].store_product_id, undefined);
});
