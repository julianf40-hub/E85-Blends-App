// 85Blends 2.4.0 — Generic promo campaign backend foundation. Pure subscriber-eligibility-scope
// predicate — no Deno-specific APIs, Node-testable (see promo-api-eligibility.test.ts).
//
// FAIL-CLOSED BY DESIGN: this foundation has no RevenueCat subscriber-history lookup, so it cannot
// verify whether a given caller is actually a new/existing/expired subscriber. A campaign that
// targets ALL THREE segments needs no such verification — everyone qualifies by definition, so it
// may proceed. A campaign scoped to any NARROWER combination (e.g. new subscribers only, which is
// the REAL 85BLENDS example's own eligibility) cannot be safely evaluated by this foundation at
// all — claiming it anyway would silently let a possibly-ineligible caller through.
// private.claim_promo_campaign enforces this exact rule authoritatively in SQL (the
// 'eligibility_unverified' outcome — see the promo campaign foundation migration's own header);
// this mirrors that SAME rule so promo-api's `validate` action never tells a caller a
// selectively-scoped campaign looks claimable when claim would immediately refuse it. See
// supabase/README.md's "REQUIRED launch gates" for what closes this permanently — a real
// RevenueCat subscriber-history check, not implemented by this addition.

export interface CampaignEligibilityScope {
  eligibilityNewSubscribers: boolean;
  eligibilityExistingSubscribers: boolean;
  eligibilityExpiredSubscribers: boolean;
}

/** True when this campaign restricts itself to a subscriber segment narrower than "everyone" — the
 *  exact condition under which neither claim_promo_campaign nor this backend can currently verify
 *  eligibility, and must therefore fail closed. */
export function hasUnverifiedEligibilityScope(scope: CampaignEligibilityScope): boolean {
  return !(scope.eligibilityNewSubscribers && scope.eligibilityExistingSubscribers && scope.eligibilityExpiredSubscribers);
}
