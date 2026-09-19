// 85Blends 2.4.0 — Referral client API. Pure response-shape builder — no Deno-specific APIs,
// Node-testable (see referral-api-response.test.ts). Takes already-fetched DB values as plain
// data; performs no I/O itself. This is the one place the exact client-safe JSON contract is
// assembled, so it is also the one place that "never expose participant/attribution/reward UUIDs,
// other users' identities, RevenueCat identifiers, or transaction/event IDs" (see the referral-api
// task spec's Phase 7) is enforced by construction — every field below is either a count, a
// backend-computed number, this installation's OWN referral code, or this installation's OWN
// attribution status. Nothing else from private.referral_* ever reaches this shape.

import { computeNextMilestoneProgress, type RewardMilestoneRow } from "./referral-milestones.ts";

export interface OwnAttributionSummary {
  referralCodeUsed: string;
  status: string;
}

export interface ReferralStatusInput {
  referralCode: string;
  qualifiedReferralCount: number;
  pendingReferralCount: number;
  rewards: readonly RewardMilestoneRow[];
  /** This installation's own attribution as the REFERRED party, if it has ever applied a code —
   *  never another participant's data. */
  ownAttribution: OwnAttributionSummary | null;
}

export interface ReferralStatusResponse {
  referral_code: string;
  qualified_referrals: number;
  pending_referrals: number;
  earned_months_available: number;
  fulfilled_months: number;
  next_milestone_number: number;
  next_reward_at: number;
  referrals_needed: number;
  can_apply_referral_code: boolean;
  referred_by_code: string | null;
  referred_status: string | null;
}

/** Builds the exact client-safe status payload — used by both the `status` action and (merged
 *  with a couple of extra fields) `bootstrap`/`apply_code`'s success responses, so all three
 *  actions always report referral progress the same way. `earned_months_available` deliberately
 *  counts only `status = 'earned'` rewards — a `revoked` reward is neither available nor ever
 *  counted here again once its milestone is no longer justified by the current qualified count
 *  (see the SQL migration's shrink logic), and a `fulfilled` reward is reported separately, not as
 *  "available" (it has already been redeemed — redemption itself is out of scope for this API). */
export function buildReferralStatusResponse(input: ReferralStatusInput): ReferralStatusResponse {
  const progress = computeNextMilestoneProgress(input.rewards, input.qualifiedReferralCount);
  const earnedMonthsAvailable = input.rewards.filter((reward) => reward.status === "earned").length;
  const fulfilledMonths = input.rewards.filter((reward) => reward.status === "fulfilled").length;

  return {
    referral_code: input.referralCode,
    qualified_referrals: input.qualifiedReferralCount,
    pending_referrals: input.pendingReferralCount,
    earned_months_available: earnedMonthsAvailable,
    fulfilled_months: fulfilledMonths,
    next_milestone_number: progress.nextMilestoneNumber,
    next_reward_at: progress.nextRewardAt,
    referrals_needed: progress.referralsNeeded,
    // Immutable one-referrer-for-life rule (see private.referral_attributions_one_referrer_per_referred
    // and the referral-api task's own "Phase 10 — Immutability") — once ANY attribution row exists
    // for this participant as the referred party, regardless of its status, applying a code is
    // permanently closed for this installation.
    can_apply_referral_code: input.ownAttribution === null,
    referred_by_code: input.ownAttribution?.referralCodeUsed ?? null,
    referred_status: input.ownAttribution?.status ?? null,
  };
}
