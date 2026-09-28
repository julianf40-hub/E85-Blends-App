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
    issuedRewardCode: null,
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
      issuedRewardCode: null,
    });
    assert.equal(response.can_apply_referral_code, false, `status=${status}`);
    assert.equal(response.referred_by_code, "WXYZ6789", `status=${status}`);
    assert.equal(response.referred_status, status, `status=${status}`);
  }
});

test("buildReferralStatusResponse: earned_months_available counts only 'earned' rows, never revoked, issued, or fulfilled", () => {
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 15,
    pendingReferralCount: 0,
    rewards: [
      { milestoneNumber: 1, status: "fulfilled" },
      { milestoneNumber: 2, status: "earned" },
      { milestoneNumber: 3, status: "earned" },
      { milestoneNumber: 4, status: "revoked" },
      { milestoneNumber: 5, status: "issued" },
    ],
    ownAttribution: null,
    issuedRewardCode: null,
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
    issuedRewardCode: null,
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
    // 85Blends 2.4.0 Referral Reward Redemption.
    "issued_reward_product_id",
    "issued_reward_offer_reference_name",
    "issued_reward_code",
    "issued_reward_expires_at",
    // 85Blends 2.4.0 third correctness hardening pass.
    "issued_reward_needs_refresh",
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
    issuedRewardCode: null,
  });
  assert.equal(response.next_milestone_number, 2);
  assert.equal(response.next_reward_at, 10);
  assert.equal(response.referrals_needed, 6);
});

// MARK: 85Blends 2.4.0 Referral Reward Redemption — issued reward code fields

test("buildReferralStatusResponse: no issued code -> all four issued_reward_* fields are null", () => {
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 5,
    pendingReferralCount: 0,
    rewards: [{ milestoneNumber: 1, status: "earned" }],
    ownAttribution: null,
    issuedRewardCode: null,
  });
  assert.equal(response.issued_reward_product_id, null);
  assert.equal(response.issued_reward_offer_reference_name, null);
  assert.equal(response.issued_reward_code, null);
  assert.equal(response.issued_reward_expires_at, null);
});

test("buildReferralStatusResponse: an issued code populates all four fields, expiration as an ISO 8601 string", () => {
  const expiresAt = new Date("2026-12-31T00:00:00.000Z");
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 5,
    pendingReferralCount: 0,
    rewards: [{ milestoneNumber: 1, status: "earned" }],
    ownAttribution: null,
    issuedRewardCode: {
      productId: "com.85blends.subscription.monthly",
      offerReferenceName: "REFERRAL_REWARD_MONTHLY_1M_FREE",
      appleCode: "ABCD1234EFGH",
      appleExpiresAt: expiresAt,
    },
  });
  assert.equal(response.issued_reward_product_id, "com.85blends.subscription.monthly");
  assert.equal(response.issued_reward_offer_reference_name, "REFERRAL_REWARD_MONTHLY_1M_FREE");
  assert.equal(response.issued_reward_code, "ABCD1234EFGH");
  assert.equal(response.issued_reward_expires_at, "2026-12-31T00:00:00.000Z");
});

test("buildReferralStatusResponse: an issued code with no expiration reports issued_reward_expires_at as null, other three fields still populated", () => {
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 5,
    pendingReferralCount: 0,
    rewards: [{ milestoneNumber: 1, status: "earned" }],
    ownAttribution: null,
    issuedRewardCode: {
      productId: "com.85blends.subscription.annual",
      offerReferenceName: "REFERRAL_REWARD_ANNUAL_1M_FREE",
      appleCode: "WXYZ9876",
      appleExpiresAt: null,
    },
  });
  assert.equal(response.issued_reward_code, "WXYZ9876");
  assert.equal(response.issued_reward_expires_at, null);
});

// MARK: 85Blends 2.4.0 third correctness hardening pass — issued_reward_needs_refresh
//
// The exact 5-referral scenario from the reported bug: a reward transitions earned -> issued the
// moment claim_referral_reward hands out a code, so earned_months_available correctly drops to 0
// (see buildReferralStatusResponse's own doc comment) — issued_reward_code/issued_reward_needs_refresh
// are the ONLY remaining signals a client can use to find its way back to the redemption sheet.

test("buildReferralStatusResponse: issued reward WITH a live code -> needs_refresh is false (the normal post-claim state)", () => {
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 5,
    pendingReferralCount: 0,
    rewards: [{ milestoneNumber: 1, status: "issued" }],
    ownAttribution: null,
    issuedRewardCode: {
      productId: "com.85blends.subscription.monthly",
      offerReferenceName: "REFERRAL_REWARD_MONTHLY_1M_FREE",
      appleCode: "ABCD1234EFGH",
      appleExpiresAt: new Date("2026-12-31T00:00:00.000Z"),
    },
  });
  assert.equal(response.earned_months_available, 0);
  assert.notEqual(response.issued_reward_code, null);
  assert.equal(response.issued_reward_needs_refresh, false);
});

test("buildReferralStatusResponse: issued reward with NO live code (expired, not yet reclaimed) -> needs_refresh is true, code stays null", () => {
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 5,
    pendingReferralCount: 0,
    rewards: [{ milestoneNumber: 1, status: "issued" }],
    ownAttribution: null,
    // Caller (loadStatusResponse) filters `apple_expires_at > now()` — an expired issued code
    // therefore never reaches this function as a populated issuedRewardCode at all.
    issuedRewardCode: null,
  });
  assert.equal(response.earned_months_available, 0);
  assert.equal(response.issued_reward_code, null);
  assert.equal(response.issued_reward_needs_refresh, true);
});

test("buildReferralStatusResponse: no issued reward at all -> needs_refresh is false regardless of other reward statuses", () => {
  for (const rewards of [
    [],
    [{ milestoneNumber: 1, status: "earned" as const }],
    [{ milestoneNumber: 1, status: "fulfilled" as const }],
    [{ milestoneNumber: 1, status: "revoked" as const }],
  ]) {
    const response = buildReferralStatusResponse({
      referralCode: "ABCD2345",
      qualifiedReferralCount: 5,
      pendingReferralCount: 0,
      rewards,
      ownAttribution: null,
      issuedRewardCode: null,
    });
    assert.equal(response.issued_reward_needs_refresh, false, JSON.stringify(rewards));
  }
});

test("buildReferralStatusResponse: needs_refresh derivation only ever reads the ALREADY-scoped rewards/issuedRewardCode inputs — never a second query", () => {
  // Environment isolation itself lives upstream, in loadStatusResponse's own SQL (`AND environment
  // = $environment` on both the reward-rows and issued-code queries — see referral-api/index.ts and
  // the migration's own Postgres scenario for a same-participant multi-environment proof). This
  // function has no environment concept at all: passing it an 'issued' reward from one environment
  // alongside an issuedRewardCode from a DIFFERENT environment is a caller bug this pure function
  // cannot and does not try to detect — it trusts its inputs are already correctly scoped, exactly
  // like every other field here (qualifiedReferralCount, rewards, ownAttribution).
  const response = buildReferralStatusResponse({
    referralCode: "ABCD2345",
    qualifiedReferralCount: 5,
    pendingReferralCount: 0,
    rewards: [{ milestoneNumber: 1, status: "issued" }],
    ownAttribution: null,
    issuedRewardCode: {
      productId: "com.85blends.subscription.monthly",
      offerReferenceName: "REFERRAL_REWARD_MONTHLY_1M_FREE",
      appleCode: "SOME_CODE",
      appleExpiresAt: new Date("2026-12-31T00:00:00.000Z"),
    },
  });
  assert.equal(response.issued_reward_needs_refresh, false);
});
