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
