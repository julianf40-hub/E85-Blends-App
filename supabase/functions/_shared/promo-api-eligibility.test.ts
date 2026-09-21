// 85Blends 2.4.0 — Tests for promo-api-eligibility.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { hasUnverifiedEligibilityScope } from "./promo-api-eligibility.ts";

test("hasUnverifiedEligibilityScope: false only when ALL THREE segments are open — a campaign open to everyone needs no verification", () => {
  assert.equal(
    hasUnverifiedEligibilityScope({
      eligibilityNewSubscribers: true,
      eligibilityExistingSubscribers: true,
      eligibilityExpiredSubscribers: true,
    }),
    false,
  );
});

test("hasUnverifiedEligibilityScope: true when scoped to new subscribers only — the REAL 85BLENDS example's own shape", () => {
  assert.equal(
    hasUnverifiedEligibilityScope({
      eligibilityNewSubscribers: true,
      eligibilityExistingSubscribers: false,
      eligibilityExpiredSubscribers: false,
    }),
    true,
  );
});

test("hasUnverifiedEligibilityScope: true for any single narrower segment left out — existing-only", () => {
  assert.equal(
    hasUnverifiedEligibilityScope({
      eligibilityNewSubscribers: false,
      eligibilityExistingSubscribers: true,
      eligibilityExpiredSubscribers: false,
    }),
    true,
  );
});

test("hasUnverifiedEligibilityScope: true for any single narrower segment left out — expired-only", () => {
  assert.equal(
    hasUnverifiedEligibilityScope({
      eligibilityNewSubscribers: false,
      eligibilityExistingSubscribers: false,
      eligibilityExpiredSubscribers: true,
    }),
    true,
  );
});

test("hasUnverifiedEligibilityScope: true when two of three are open but not all three", () => {
  assert.equal(
    hasUnverifiedEligibilityScope({
      eligibilityNewSubscribers: true,
      eligibilityExistingSubscribers: true,
      eligibilityExpiredSubscribers: false,
    }),
    true,
  );
});

test("hasUnverifiedEligibilityScope: true when a misconfigured campaign leaves all three at their default false", () => {
  assert.equal(
    hasUnverifiedEligibilityScope({
      eligibilityNewSubscribers: false,
      eligibilityExistingSubscribers: false,
      eligibilityExpiredSubscribers: false,
    }),
    true,
  );
});
