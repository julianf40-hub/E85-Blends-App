// 85Blends 2.4.0 — Tests for referral-api-response.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { buildReferralStatusResponse } from "./referral-api-response.ts";

test("buildReferralStatusResponse: no attribution -> can_apply_referral_code true, referred_by_code/referred_status null", () => {
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 0,
    pendingReferralCount: 0,
    rewards: [],
    ownAttribution: null,
  });
  assert.equal(response.can_apply_referral_code, true);
  assert.equal(response.referred_by_code, null);
  assert.equal(response.referred_status, null);
  assert.equal(response.referral_code, "ABCD2345");
});

test("buildReferralStatusResponse: existing attribution -> can_apply_referral_code false regardless of its status", () => {
  for (const status of ["pending", "qualified", "reversed", "disqualified"]) {
    const response = buildReferralStatusResponse({
      referralCode: "ABCD2345",
      qualifiedReferralCount: 0,
      pendingReferralCount: 0,
      rewards: [],
      ownAttribution: { referralCodeUsed: "WXYZ6789", status },
    });
    assert.equal(response.can_apply_referral_code, false, `status=${status}`);
    assert.equal(response.referred_by_code, "WXYZ6789", `status=${status}`);
    assert.equal(response.referred_status, status, `status=${status}`);
  }
});

test("buildReferralStatusResponse: earned_months_available counts only 'earned' rows, never revoked or fulfilled", () => {
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 15,
    pendingReferralCount: 0,
    rewards: [
      { milestoneNumber: 1, status: "fulfilled" },
      { milestoneNumber: 2, status: "earned" },
      { milestoneNumber: 3, status: "earned" },
      { milestoneNumber: 4, status: "revoked" },
    ],
    ownAttribution: null,
  });
  assert.equal(response.earned_months_available, 2);
  assert.equal(response.fulfilled_months, 1);
});

test("buildReferralStatusResponse: never includes any field beyond the fixed client-safe shape (no UUIDs/identifiers can leak through)", () => {
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 3,
    pendingReferralCount: 1,
    rewards: [],
    ownAttribution: null,
  });
  const allowedKeys = new Set([
    "referral_code",
    "qualified_referrals",
    "pending_referrals",
    "earned_months_available",
    "fulfilled_months",
    "next_milestone_number",
    "next_reward_at",
    "referrals_needed",
    "can_apply_referral_code",
    "referred_by_code",
    "referred_status",
  ]);
  for (const key of Object.keys(response)) {
    assert.equal(allowedKeys.has(key), true, `unexpected key in status response: ${key}`);
  }
  assert.equal(Object.keys(response).length, allowedKeys.size);
});

test("buildReferralStatusResponse: propagates next-milestone math from computeNextMilestoneProgress", () => {
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 4,
    pendingReferralCount: 0,
    rewards: [{ milestoneNumber: 1, status: "fulfilled" }],
    ownAttribution: null,
  });
  assert.equal(response.next_milestone_number, 2);
  assert.equal(response.next_reward_at, 10);
  assert.equal(response.referrals_needed, 6);
});
