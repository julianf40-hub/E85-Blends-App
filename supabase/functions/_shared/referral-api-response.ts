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

/** 85Blends 2.4.0 Referral Reward Redemption — this installation's own currently ISSUED (not yet
 *  redeemed) reward code, if any. Deliberately the raw Apple code itself: rule 5 of this feature's
 *  task spec permits returning it "to the authenticated installation they were assigned to," and the
 *  client needs it available across app relaunches (e.g. the user backgrounds the app before ever
 *  tapping "Redeem in App Store" and returns later) — see referral-api/index.ts's own header on why
 *  this is safe: this whole response is only ever reachable after authenticateInstallation succeeds
 *  for THIS installation. Never populated from another participant's row. */
export interface IssuedRewardCodeSummary {
  productId: string;
  offerReferenceName: string;
  appleCode: string;
  appleExpiresAt: Date | null;
}

export interface ReferralStatusInput {
  referralCode: string;
  qualifiedReferralCount: number;
  pendingReferralCount: number;
  rewards: readonly RewardMilestoneRow[];
  /** This installation's own attribution as the REFERRED party, if it has ever applied a code —
   *  never another participant's data. */
  ownAttribution: OwnAttributionSummary | null;
  /** `null` when no reward currently has a live issued code for this participant. */
  issuedRewardCode: IssuedRewardCodeSummary | null;
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
  issued_reward_product_id: string | null;
  issued_reward_offer_reference_name: string | null;
  issued_reward_code: string | null;
  issued_reward_expires_at: string | null;
}

/** Builds the exact client-safe status payload — used by `status`, `bootstrap`, `apply_code`, and
 *  (85Blends 2.4.0) `claim_reward`'s success responses, so every action always reports referral
 *  progress the same way. `earned_months_available` deliberately counts only `status = 'earned'`
 *  rewards — a `revoked` reward is neither available nor ever counted here again once its milestone
 *  is no longer justified by the current qualified count (see the SQL migration's shrink logic), a
 *  `fulfilled` reward is reported separately, not as "available" (it has already been redeemed), and
 *  (85Blends 2.4.0 second correctness hardening pass) an `issued` reward is ALSO excluded — it
 *  already has a real Apple code handed out for it, surfaced separately via `issued_reward_*` below,
 *  so counting it as "available to claim" too would double-report the same reward two ways. */
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
    issued_reward_product_id: input.issuedRewardCode?.productId ?? null,
    issued_reward_offer_reference_name: input.issuedRewardCode?.offerReferenceName ?? null,
    issued_reward_code: input.issuedRewardCode?.appleCode ?? null,
    issued_reward_expires_at: input.issuedRewardCode?.appleExpiresAt?.toISOString() ?? null,
  };
}
