// 85Blends 2.4.0 — Tests for referral-milestones.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { desiredEarnedMilestones, REFERRALS_PER_MILESTONE } from "./referral-milestones.ts";

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
