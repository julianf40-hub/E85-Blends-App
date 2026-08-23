// 85Blends 2.3.0 — Phase B1. Tests for entitlement.ts. Run under Node — see hmac.test.ts's header.

import { test } from "node:test";
import assert from "node:assert/strict";
import { calculatePro, parseRevenueCatTimestamp } from "./entitlement.ts";
import type { RevenueCatSubscription } from "./revenuecat-types.ts";

function sub(overrides: Partial<RevenueCatSubscription> & { entitlementKeys?: string[] }): RevenueCatSubscription {
  const { entitlementKeys, ...rest } = overrides;
  return {
    entitlements: { items: (entitlementKeys ?? ["pro"]).map((lookup_key) => ({ lookup_key })) },
    ...rest,
  };
}

test("calculatePro: gives_access true + pro entitlement -> active", () => {
  const result = calculatePro([sub({ gives_access: true })]);
  assert.equal(result.proIsActive, true);
});

test("calculatePro: gives_access false + pro entitlement -> inactive", () => {
  const result = calculatePro([sub({ gives_access: false })]);
  assert.equal(result.proIsActive, false);
});

test("calculatePro: gives_access true but unrelated entitlement -> inactive", () => {
  const result = calculatePro([sub({ gives_access: true, entitlementKeys: ["some_other_entitlement"] })]);
  assert.equal(result.proIsActive, false);
});

test("calculatePro: gives_access true with multiple entitlements including pro -> active", () => {
  const result = calculatePro([sub({ gives_access: true, entitlementKeys: ["other", "pro"] })]);
  assert.equal(result.proIsActive, true);
});

test("calculatePro: grace-period-like subscription (status not 'active') with gives_access true -> active", () => {
  // The whole point of using gives_access instead of status: RevenueCat reports gives_access
  // true through trials, grace periods, and billing retry — status alone must never be consulted.
  const result = calculatePro([sub({ gives_access: true, status: "billing_issue" })]);
  assert.equal(result.proIsActive, true);
});

test("calculatePro: status active but gives_access false -> inactive (status is never trusted alone)", () => {
  const result = calculatePro([sub({ gives_access: false, status: "active" })]);
  assert.equal(result.proIsActive, false);
});

test("calculatePro: gives_access missing entirely -> inactive (never defaults to true)", () => {
  const result = calculatePro([sub({})]);
  assert.equal(result.proIsActive, false);
});

test("calculatePro: multiple qualifying subscriptions -> active, uses latest expiration", () => {
  const result = calculatePro([
    sub({ gives_access: true, ends_at: "2026-01-01T00:00:00Z" }),
    sub({ gives_access: true, ends_at: "2026-06-01T00:00:00Z" }),
  ]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.proExpiresAt?.toISOString(), "2026-06-01T00:00:00.000Z");
});

test("calculatePro: non-qualifying subscription's expiration is ignored", () => {
  const result = calculatePro([
    sub({ gives_access: true, ends_at: "2026-01-01T00:00:00Z" }),
    sub({ gives_access: false, ends_at: "2027-01-01T00:00:00Z" }), // later, but doesn't qualify
  ]);
  assert.equal(result.proExpiresAt?.toISOString(), "2026-01-01T00:00:00.000Z");
});

test("calculatePro: falls back to current_period_ends_at when ends_at is absent", () => {
  const result = calculatePro([sub({ gives_access: true, current_period_ends_at: "2026-03-01T00:00:00Z" })]);
  assert.equal(result.proExpiresAt?.toISOString(), "2026-03-01T00:00:00.000Z");
});

test("calculatePro: no subscriptions at all -> inactive, no expiration", () => {
  const result = calculatePro([]);
  assert.deepEqual(result, { proIsActive: false, proExpiresAt: null });
});

test("calculatePro: qualifying subscription with no resolvable timestamp -> active, null expiration", () => {
  const result = calculatePro([sub({ gives_access: true })]);
  assert.equal(result.proIsActive, true);
  assert.equal(result.proExpiresAt, null);
});

test("calculatePro: custom entitlement lookup key", () => {
  const result = calculatePro([sub({ gives_access: true, entitlementKeys: ["other_entitlement"] })], "other_entitlement");
  assert.equal(result.proIsActive, true);
});

test("parseRevenueCatTimestamp: accepts ISO 8601 string", () => {
  const date = parseRevenueCatTimestamp("2026-01-01T00:00:00Z");
  assert.equal(date?.toISOString(), "2026-01-01T00:00:00.000Z");
});

test("parseRevenueCatTimestamp: accepts epoch milliseconds number", () => {
  const date = parseRevenueCatTimestamp(1735689600000);
  assert.equal(date?.toISOString(), "2025-01-01T00:00:00.000Z");
});

test("parseRevenueCatTimestamp: rejects garbage", () => {
  assert.equal(parseRevenueCatTimestamp("not a date"), null);
  assert.equal(parseRevenueCatTimestamp(null), null);
  assert.equal(parseRevenueCatTimestamp(undefined), null);
  assert.equal(parseRevenueCatTimestamp(NaN), null);
  assert.equal(parseRevenueCatTimestamp(""), null);
});
