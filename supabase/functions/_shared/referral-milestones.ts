// 85Blends 2.4.0 — Referral paid-qualification foundation. Pure mirror of the repeatable
// 5-referral milestone formula.
//
// The ACTUAL runtime enforcement of this formula is SQL, inside
// private.process_referral_subscription_event(...) (see the referral migration) — reward rows are
// created/revoked/restored transactionally alongside the qualification/reversal write they result
// from, which only a database function can do atomically. This file exists so the formula itself
// has a fast, deterministic, Node-testable specification independent of a live Postgres connection
// — mirroring why database.ts documents itself as "static-review-only" while the DECISIONS it
// implements live in Node-tested pure functions elsewhere in this directory. Production code never
// calls this function; the SQL migration re-implements the identical `floor(count / 5)` rule
// directly (see that migration's own comments for the SQL expression), and this file's tests are
// the executable proof that the formula those SQL comments describe is the one actually intended.

/** Every 5 qualified paid referrals earns one more milestone, forever — see the referral task's
 *  own "Repeatable milestone algorithm" section. Not expected to change independently of the SQL
 *  migration's own hardcoded `5` — if it ever needs to become configurable, both this constant and
 *  the SQL function's literal must be updated together. */
export const REFERRALS_PER_MILESTONE = 5;

/**
 * How many milestones a given qualified-referral count has earned, in total, ever — always
 * `floor(count / REFERRALS_PER_MILESTONE)`. Negative counts are clamped to 0 (never reachable in
 * practice; a qualified-referral count is always a non-negative SQL `count(*)`, but this keeps the
 * function total rather than leaning on that invariant silently — same defensive style as
 * ProPlan.equivalentMonthlyAmount on the iOS side).
 */
export function desiredEarnedMilestones(qualifiedReferralCount: number): number {
  if (qualifiedReferralCount <= 0) return 0;
  return Math.floor(qualifiedReferralCount / REFERRALS_PER_MILESTONE);
}

/** One reward row's milestone-relevant shape — deliberately just the two fields the progress
 *  calculation below needs, not the full private.referral_rewards row (no UUIDs, no timestamps). */
export interface RewardMilestoneRow {
  milestoneNumber: number;
  status: "earned" | "fulfilled" | "revoked";
}

export interface NextMilestoneProgress {
  nextMilestoneNumber: number;
  nextRewardAt: number;
  referralsNeeded: number;
}

/**
 * 85Blends 2.4.0 referral client API — the next milestone a referrer is working toward, computed
 * from reward HISTORY rather than the raw qualified-referral count. A fulfilled reward is never
 * clawed back (see the SQL migration's shrink logic in
 * private.process_referral_subscription_event), so a later refund that drops the qualified count
 * back below a PAST milestone's threshold must never make that milestone look reachable again —
 * simple `qualified_count % REFERRALS_PER_MILESTONE` arithmetic would get this wrong. The next
 * target is always the first milestone number strictly after the highest one this referrer has
 * ever earned or had fulfilled; a 'revoked' milestone is deliberately excluded from that "highest"
 * calculation. Worked examples (see the referral-api task's own "Phase 8" spec):
 *   - no rewards: next = 1, next_reward_at = 5
 *   - milestone 1 fulfilled: next = 2, next_reward_at = 10
 *   - milestone 2 revoked, milestone 1 still fulfilled: next = 2, next_reward_at = 10 (does NOT
 *     fall back to re-targeting milestone 1)
 *   - milestones 1 fulfilled + 2 earned: next = 3, next_reward_at = 15
 */
export function computeNextMilestoneProgress(
  rewards: readonly RewardMilestoneRow[],
  qualifiedReferralCount: number,
): NextMilestoneProgress {
  let highestEarnedOrFulfilled = 0;
  for (const reward of rewards) {
    if (reward.status === "earned" || reward.status === "fulfilled") {
      highestEarnedOrFulfilled = Math.max(highestEarnedOrFulfilled, reward.milestoneNumber);
    }
  }

  const nextMilestoneNumber = highestEarnedOrFulfilled + 1;
  const nextRewardAt = nextMilestoneNumber * REFERRALS_PER_MILESTONE;
  const referralsNeeded = Math.max(0, nextRewardAt - qualifiedReferralCount);

  return { nextMilestoneNumber, nextRewardAt, referralsNeeded };
}
