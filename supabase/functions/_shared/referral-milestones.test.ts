// 85Blends 2.4.0 — Tests for referral-milestones.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  desiredEarnedMilestones,
  REFERRALS_PER_MILESTONE,
  computeNextMilestoneProgress,
  type RewardMilestoneRow,
} from "./referral-milestones.ts";

test("REFERRALS_PER_MILESTONE is 5, per the locked business rule", () => {
  assert.equal(REFERRALS_PER_MILESTONE, 5);
});

const cases: [number, number][] = [
  [0, 0],
  [4, 0],
  [5, 1],
  [9, 1],
  [10, 2],
  [12, 2],
  [15, 3],
  [27, 5],
];

for (const [count, expected] of cases) {
  test(`desiredEarnedMilestones(${count}) === ${expected}`, () => {
    assert.equal(desiredEarnedMilestones(count), expected);
  });
}

test("desiredEarnedMilestones: negative counts clamp to 0 (defensive — never reachable from a real SQL count(*))", () => {
  assert.equal(desiredEarnedMilestones(-1), 0);
  assert.equal(desiredEarnedMilestones(-100), 0);
});

test("desiredEarnedMilestones: just below a milestone boundary never rounds up", () => {
  assert.equal(desiredEarnedMilestones(19), 3);
  assert.equal(desiredEarnedMilestones(24), 4);
});

// 85Blends 2.4.0 referral client API — computeNextMilestoneProgress. The exact worked examples
// from the referral-api task's own "Phase 8 — Next-Milestone Logic" spec.

test("computeNextMilestoneProgress: no rewards -> next milestone 1, next_reward_at 5", () => {
  const result = computeNextMilestoneProgress([], 0);
  assert.deepEqual(result, { nextMilestoneNumber: 1, nextRewardAt: 5, referralsNeeded: 5 });
});

test("computeNextMilestoneProgress: milestone 1 fulfilled -> next milestone 2, next_reward_at 10", () => {
  const rewards: RewardMilestoneRow[] = [{ milestoneNumber: 1, status: "fulfilled" }];
  const result = computeNextMilestoneProgress(rewards, 5);
  assert.deepEqual(result, { nextMilestoneNumber: 2, nextRewardAt: 10, referralsNeeded: 5 });
});

test("computeNextMilestoneProgress: fulfilled milestone 1 + qualified count 4 -> next target 10, need 6", () => {
  const rewards: RewardMilestoneRow[] = [{ milestoneNumber: 1, status: "fulfilled" }];
  const result = computeNextMilestoneProgress(rewards, 4);
  assert.deepEqual(result, { nextMilestoneNumber: 2, nextRewardAt: 10, referralsNeeded: 6 });
});

test("computeNextMilestoneProgress: milestone 2 revoked + milestone 1 fulfilled -> next target still 10, not a fallback to 5", () => {
  const rewards: RewardMilestoneRow[] = [
    { milestoneNumber: 1, status: "fulfilled" },
    { milestoneNumber: 2, status: "revoked" },
  ];
  const result = computeNextMilestoneProgress(rewards, 9);
  assert.deepEqual(result, { nextMilestoneNumber: 2, nextRewardAt: 10, referralsNeeded: 1 });
});

test("computeNextMilestoneProgress: milestones 1 fulfilled + 2 earned -> next milestone 3, next_reward_at 15", () => {
  const rewards: RewardMilestoneRow[] = [
    { milestoneNumber: 1, status: "fulfilled" },
    { milestoneNumber: 2, status: "earned" },
  ];
  const result = computeNextMilestoneProgress(rewards, 10);
  assert.deepEqual(result, { nextMilestoneNumber: 3, nextRewardAt: 15, referralsNeeded: 5 });
});

test("computeNextMilestoneProgress: referralsNeeded never goes negative", () => {
  const rewards: RewardMilestoneRow[] = [{ milestoneNumber: 1, status: "earned" }];
  // Already past the next threshold (e.g. a fresh qualification landed before this call).
  const result = computeNextMilestoneProgress(rewards, 11);
  assert.equal(result.referralsNeeded, 0);
});

test("computeNextMilestoneProgress: reward rows out of milestone order are still handled by max(), not array order", () => {
  const rewards: RewardMilestoneRow[] = [
    { milestoneNumber: 2, status: "earned" },
    { milestoneNumber: 1, status: "fulfilled" },
  ];
  const result = computeNextMilestoneProgress(rewards, 10);
  assert.deepEqual(result, { nextMilestoneNumber: 3, nextRewardAt: 15, referralsNeeded: 5 });
});
