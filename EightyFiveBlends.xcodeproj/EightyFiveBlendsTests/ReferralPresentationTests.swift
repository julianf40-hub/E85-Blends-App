//
//  ReferralPresentationTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.0 — Refer & Earn UI. Tests for ReferralPresentation's pure UI-only helpers (code
//  format validation, progress formatting, entry eligibility, applied-status copy, error copy,
//  share text), plus a few focused MANAGER/UI CONTRACT tests confirming the exact
//  ReferralManager.applyReferralCode(_:) behavior ReferralCodeEntrySheet relies on. Reuses the
//  FakeReferralAPIService/TestGate/etc. fakes already defined in ReferralManagerTests.swift (same
//  test target, no import needed) rather than redefining them.
//
//  Item 40 ("Refer & Earn row is outside the Normal Mode condition") is verified by static/manual
//  source inspection during this feature's own validation pass, not as an automated test here —
//  MoreView.swift's conditional structure isn't naturally unit-testable without a view-inspection
//  library this codebase doesn't use; see this feature's final report.
//

import Testing
import Foundation
@testable import EightyFiveBlends

struct ReferralPresentationTests {
    // MARK: - 85Blends 2.4.0 Referral Reward Redemption — pure presentation helpers

    @Test("parseISO8601Date parses the fractional-seconds form this feature's own backend emits")
    func parseISO8601Date_fractionalSeconds() {
        let date = ReferralPresentation.parseISO8601Date("2026-12-31T00:00:00.000Z")
        #expect(date != nil)
    }

    @Test("parseISO8601Date falls back to the plain (no fractional seconds) form")
    func parseISO8601Date_plainForm() {
        let date = ReferralPresentation.parseISO8601Date("2026-12-31T00:00:00Z")
        #expect(date != nil)
    }

    @Test("parseISO8601Date returns nil for nil or malformed input, never throws/crashes")
    func parseISO8601Date_nilOrMalformed() {
        #expect(ReferralPresentation.parseISO8601Date(nil) == nil)
        #expect(ReferralPresentation.parseISO8601Date("not-a-date") == nil)
        #expect(ReferralPresentation.parseISO8601Date("") == nil)
    }

    @Test("rewardCardHeadline pluralizes correctly")
    func rewardCardHeadline_pluralization() {
        #expect(ReferralPresentation.rewardCardHeadline(earnedMonthsAvailable: 1) == "1 Free Month Ready")
        #expect(ReferralPresentation.rewardCardHeadline(earnedMonthsAvailable: 2) == "2 Free Months Ready")
    }

    // MARK: - rewardCardState (85Blends 2.4.0 third correctness hardening pass)
    //
    // The exact 5-referral scenario from the reported bug: after claim_reward succeeds,
    // earnedMonthsAvailable correctly drops to 0 (the reward's own status is now 'issued', not
    // 'earned') — issuedRewardCode is the ONLY remaining signal keeping the redemption entry point
    // visible. These tests pin the state-decision logic ReferEarnView's card AND
    // ReferralRewardRedemptionSheet's content both delegate to, independent of any SwiftUI
    // rendering this environment cannot compile/run (see this feature's own task spec: no Xcode
    // available here).

    @Test("Normal issued-code reentry: earnedMonthsAvailable=0 with a live issued code still exposes the entry point (.issuedCode) — this is the exact backend state after claiming the only earned reward")
    func rewardCardState_issuedCodeAfterClaim_stillExposesEntryPoint() {
        let state = ReferralPresentation.rewardCardState(
            earnedMonthsAvailable: 0,
            issuedRewardCode: "ABCD1234EFGH",
            issuedRewardNeedsRefresh: false
        )
        #expect(state == .issuedCode)
        #expect(state != nil)
    }

    @Test("Needs-refresh reentry: earnedMonthsAvailable=0, no issued code, needsRefresh=true still exposes the entry point (.needsRefresh)")
    func rewardCardState_needsRefresh_stillExposesEntryPoint() {
        let state = ReferralPresentation.rewardCardState(
            earnedMonthsAvailable: 0,
            issuedRewardCode: nil,
            issuedRewardNeedsRefresh: true
        )
        #expect(state == .needsRefresh)
        #expect(state != nil)
    }

    @Test("A freshly earned, unclaimed reward is .earned(count:)")
    func rewardCardState_earnedUnclaimed() {
        #expect(
            ReferralPresentation.rewardCardState(earnedMonthsAvailable: 1, issuedRewardCode: nil, issuedRewardNeedsRefresh: false)
                == .earned(count: 1)
        )
        #expect(
            ReferralPresentation.rewardCardState(earnedMonthsAvailable: 3, issuedRewardCode: nil, issuedRewardNeedsRefresh: false)
                == .earned(count: 3)
        )
    }

    @Test("Nothing earned, nothing issued, no refresh needed -> nil (card hidden entirely)")
    func rewardCardState_nothingToShow_isNil() {
        #expect(ReferralPresentation.rewardCardState(earnedMonthsAvailable: 0, issuedRewardCode: nil, issuedRewardNeedsRefresh: false) == nil)
    }

    @Test("A live issued code always wins precedence over earnedMonthsAvailable or needsRefresh, however they're combined")
    func rewardCardState_issuedCodeTakesPrecedence() {
        #expect(
            ReferralPresentation.rewardCardState(earnedMonthsAvailable: 1, issuedRewardCode: "CODE1", issuedRewardNeedsRefresh: false)
                == .issuedCode
        )
        #expect(
            ReferralPresentation.rewardCardState(earnedMonthsAvailable: 0, issuedRewardCode: "CODE1", issuedRewardNeedsRefresh: true)
                == .issuedCode
        )
    }

    @Test("earnedMonthsAvailable > 0 wins precedence over needsRefresh when both are somehow true")
    func rewardCardState_earnedTakesPrecedenceOverNeedsRefresh() {
        #expect(
            ReferralPresentation.rewardCardState(earnedMonthsAvailable: 1, issuedRewardCode: nil, issuedRewardNeedsRefresh: true)
                == .earned(count: 1)
        )
    }

    @Test("Each rewardCardState has distinct, non-empty headline and subtitle copy, and never echoes the raw Apple code")
    func rewardCardState_headlineAndSubtitleAreDistinctAndSafe() {
        let states: [ReferralPresentation.RewardCardState] = [.earned(count: 1), .issuedCode, .needsRefresh]
        let headlines = states.map { ReferralPresentation.rewardCardHeadline(for: $0) }
        let subtitles = states.map { ReferralPresentation.rewardCardSubtitle(for: $0) }
        #expect(Set(headlines).count == states.count)
        #expect(Set(subtitles).count == states.count)
        for copy in headlines + subtitles {
            #expect(copy.isEmpty == false)
            #expect(copy.contains("ABCD1234EFGH") == false)
        }
        #expect(ReferralPresentation.rewardCardHeadline(for: .earned(count: 1)) == "1 Free Month Ready")
        #expect(ReferralPresentation.rewardCardHeadline(for: .issuedCode) == "Free Month Ready to Redeem")
        #expect(ReferralPresentation.rewardCardHeadline(for: .needsRefresh) == "Free Month Needs Refresh")
    }

    @Test("renewalPriceLine composes the real, passed-in display price and billing period label")
    func renewalPriceLine_composesRealValues() {
        let line = ReferralPresentation.renewalPriceLine(displayPrice: "$3.99", billingPeriodLabel: "month")
        #expect(line == "$3.99/month after the free month")
    }

    @Test("redemptionConfirmationCopy embeds the exact renewal price line it is given")
    func redemptionConfirmationCopy_embedsRenewalLine() {
        let copy = ReferralPresentation.redemptionConfirmationCopy(renewalPriceLine: "$3.99/month after the free month")
        #expect(copy.contains("$3.99/month after the free month"))
        #expect(copy.contains("1 month of 85Blends Pro free"))
    }

    @Test("claimStatusMessage returns nil only for the success outcome, never for any other")
    func claimStatusMessage_nilOnlyForClaimed() {
        #expect(ReferralPresentation.claimStatusMessage("claimed") == nil)
        #expect(ReferralPresentation.claimStatusMessage("no_eligible_reward") != nil)
        #expect(ReferralPresentation.claimStatusMessage("no_code_available") != nil)
        #expect(ReferralPresentation.claimStatusMessage("legacy_or_unsupported_product_active") != nil)
        #expect(ReferralPresentation.claimStatusMessage("invalid_product") != nil)
        #expect(ReferralPresentation.claimStatusMessage("outstanding_reward_exists") != nil)
        #expect(ReferralPresentation.claimStatusMessage("expired_no_longer_qualified") != nil)
        #expect(ReferralPresentation.claimStatusMessage("some_future_unknown_outcome") != nil)
    }

    @Test("claimStatusMessage never echoes the raw backend status string verbatim")
    func claimStatusMessage_neverEchoesRawStatus() {
        let rawStatuses = ["no_eligible_reward", "no_code_available", "outstanding_reward_exists", "invalid_product", "expired_no_longer_qualified"]
        for raw in rawStatuses {
            let message = ReferralPresentation.claimStatusMessage(raw)
            #expect(message?.contains(raw) != true)
        }
    }

    // MARK: - Input validation (1-10)

    @Test("A valid 8-character code from the allowed alphabet is accepted")
    func validCode_isAccepted() {
        #expect(ReferralPresentation.referralCodeIsValid("ABCD2345"))
    }

    @Test("Lowercase input normalizes to uppercase and is still accepted")
    func lowercaseCode_normalizesAndIsAccepted() {
        #expect(ReferralPresentation.referralCodeIsValid("abcd2345"))
        #expect(ReferralPresentation.normalizedReferralCode("abcd2345") == "ABCD2345")
    }

    @Test("Surrounding whitespace is trimmed before validation")
    func surroundingWhitespace_isTrimmed() {
        #expect(ReferralPresentation.referralCodeIsValid("  ABCD2345  "))
        #expect(ReferralPresentation.normalizedReferralCode("  abcd2345  ") == "ABCD2345")
    }

    @Test(
        "Codes with the wrong length or a disallowed character are rejected",
        arguments: [
            "ABCD234",      // 4. 7 chars
            "23456789A",    // 5. 9 chars (all otherwise-valid alphabet characters)
            "ABCD2340",     // 6. contains 0
            "ABCD2341",     // 7. contains 1
            "ABCDI345",     // 8. contains I
            "ABCDO345",     // 9. contains O
            "ABCD-345",     // 10. contains a symbol
        ]
    )
    func invalidCode_isRejected(code: String) {
        #expect(ReferralPresentation.referralCodeIsValid(code) == false)
    }

    // MARK: - Progress (11-15)

    @Test(
        "progressInCurrentCycle derives the correct position in the fixed 5-referral cycle",
        arguments: [
            (5, 0),  // 11. referralsNeeded=5 => 0/5
            (4, 1),  // 12. referralsNeeded=4 => 1/5
            (3, 2),  // 13. referralsNeeded=3 => 2/5
            (1, 4),  // 14. referralsNeeded=1 => 4/5
        ]
    )
    func progressInCurrentCycle_matchesExpected(referralsNeeded: Int, expectedProgress: Int) {
        #expect(ReferralPresentation.progressInCurrentCycle(referralsNeeded: referralsNeeded) == expectedProgress)
    }

    @Test("progressInCurrentCycle clamps an unexpected out-of-range value into [0, 5]")
    func progressInCurrentCycle_clampsUnexpectedValues() {
        // referralsNeeded == 0 (already at the milestone) clamps to the full bar, never > 5.
        #expect(ReferralPresentation.progressInCurrentCycle(referralsNeeded: 0) == 5)
        // A value larger than the cycle length clamps to 0, never negative.
        #expect(ReferralPresentation.progressInCurrentCycle(referralsNeeded: 99) == 0)
        // A negative value (should never happen server-side) still clamps into range.
        #expect(ReferralPresentation.progressInCurrentCycle(referralsNeeded: -3) == 5)
    }

    // MARK: - Entry eligibility (16-19, extended for entitlement-resolution + authoritative-status gating)

    @Test("canApplyReferralCode=true, entitlement resolved, authoritative, not Pro allows entry")
    func entryEligibility_freeUserCanApply_allowed() {
        #expect(
            ReferralPresentation.entryEligibility(
                canApplyReferralCode: true,
                isCurrentlyPro: false,
                isEntitlementResolutionPending: false,
                hasAuthoritativeProStatus: true
            ) == .allowed
        )
    }

    @Test("canApplyReferralCode=true, entitlement resolved, authoritative, Pro blocks entry with the Pro-specific reason")
    func entryEligibility_proUserCanApply_blockedAlreadyPro() {
        #expect(
            ReferralPresentation.entryEligibility(
                canApplyReferralCode: true,
                isCurrentlyPro: true,
                isEntitlementResolutionPending: false,
                hasAuthoritativeProStatus: true
            ) == .blockedAlreadyPro
        )
    }

    @Test("canApplyReferralCode=false blocks entry regardless of Pro status, entitlement-resolution state, or authoritative-status")
    func entryEligibility_cannotApply_blockedRegardlessOfPro() {
        #expect(ReferralPresentation.entryEligibility(canApplyReferralCode: false, isCurrentlyPro: false, isEntitlementResolutionPending: false, hasAuthoritativeProStatus: true) == .blockedCannotApply)
        #expect(ReferralPresentation.entryEligibility(canApplyReferralCode: false, isCurrentlyPro: true, isEntitlementResolutionPending: false, hasAuthoritativeProStatus: true) == .blockedCannotApply)
        // The backend's own canApplyReferralCode=false is checked first and is decisive on its
        // own — still blockedCannotApply even while entitlement resolution is pending or
        // unresolved-and-not-authoritative.
        #expect(ReferralPresentation.entryEligibility(canApplyReferralCode: false, isCurrentlyPro: false, isEntitlementResolutionPending: true, hasAuthoritativeProStatus: false) == .blockedCannotApply)
        #expect(ReferralPresentation.entryEligibility(canApplyReferralCode: false, isCurrentlyPro: false, isEntitlementResolutionPending: false, hasAuthoritativeProStatus: false) == .blockedCannotApply)
    }

    @Test(
        "While entitlement resolution is pending, entry is withheld with waitingForSubscriptionStatus regardless of the provisional isCurrentlyPro value",
        arguments: [false, true]
    )
    func entryEligibility_entitlementResolutionPending_waitsRegardlessOfProvisionalProValue(provisionalIsCurrentlyPro: Bool) {
        // A real Pro subscriber can briefly read isProUser == false during cold-launch RevenueCat
        // resolution — this must never be trusted while resolution is still pending, in either
        // direction: .allowed would risk letting a real Pro subscriber apply a code they should
        // never be offered; .blockedAlreadyPro would risk wrongly telling a real Free user they
        // can't enter a code. hasAuthoritativeProStatus is false here too (nothing has succeeded
        // yet at cold launch) but is irrelevant either way — isEntitlementResolutionPending is
        // checked first and is decisive on its own.
        #expect(
            ReferralPresentation.entryEligibility(
                canApplyReferralCode: true,
                isCurrentlyPro: provisionalIsCurrentlyPro,
                isEntitlementResolutionPending: true,
                hasAuthoritativeProStatus: false
            ) == .waitingForSubscriptionStatus
        )
    }

    @Test(
        "A resolution attempt that finished without ever producing a real CustomerInfo answer (a failed first fetch) is subscriptionStatusUnavailable, never allowed or blockedAlreadyPro, regardless of the stale/default isCurrentlyPro value",
        arguments: [false, true]
    )
    func entryEligibility_resolvedButNotAuthoritative_isUnavailableRegardlessOfProvisionalProValue(staleIsCurrentlyPro: Bool) {
        // This is the exact failed-first-fetch shape: RevenueCatSubscriptionService reaches
        // .resolved (isEntitlementResolutionPending == false) on a FAILED first fetch too, on
        // purpose, while revenueCatIsPro stays at its untouched false default — see
        // SubscriptionManager.hasAuthoritativeProStatus's own header. Without this case, a real
        // existing Pro subscriber whose first fetch fails would read isCurrentlyPro == false and
        // be wrongly offered referral-code entry.
        #expect(
            ReferralPresentation.entryEligibility(
                canApplyReferralCode: true,
                isCurrentlyPro: staleIsCurrentlyPro,
                isEntitlementResolutionPending: false,
                hasAuthoritativeProStatus: false
            ) == .subscriptionStatusUnavailable
        )
    }

    @Test("A present referredByCode means the immutable applied state, never entry")
    func hasAppliedReferralCode_reflectsReferredByCodePresence() {
        #expect(ReferralPresentation.hasAppliedReferralCode(referredByCode: "ABCD2345"))
        #expect(ReferralPresentation.hasAppliedReferralCode(referredByCode: nil) == false)
    }

    @Test("hasAppliedReferralCode takes no entitlement-resolution or authoritative-status parameter, so an applied code always wins independently of both — see ReferEarnLoadedContent.referredBySection's own precedence comment")
    func hasAppliedReferralCode_isIndependentOfEntitlementResolution() {
        #expect(ReferralPresentation.hasAppliedReferralCode(referredByCode: "ABCD2345"))
        // Confirms the separate facts this precedence relies on: with the exact same
        // canApplyReferralCode/isCurrentlyPro inputs, entryEligibility alone (never consulted by
        // referredBySection once a code is applied) would have produced a waiting or unavailable
        // outcome instead — hasAppliedReferralCode being checked first is what shields the applied
        // card from ever being replaced by either.
        #expect(
            ReferralPresentation.entryEligibility(
                canApplyReferralCode: true,
                isCurrentlyPro: false,
                isEntitlementResolutionPending: true,
                hasAuthoritativeProStatus: false
            ) == .waitingForSubscriptionStatus
        )
        #expect(
            ReferralPresentation.entryEligibility(
                canApplyReferralCode: true,
                isCurrentlyPro: false,
                isEntitlementResolutionPending: false,
                hasAuthoritativeProStatus: false
            ) == .subscriptionStatusUnavailable
        )
    }

    // MARK: - Paywall entry-gate composition (Phase 20, 2.4.0)
    //
    // ProUpgradeView's own `hasInvalidNonEmptyReferralCode` is a PRIVATE computed property (not
    // reachable even via @testable import) that composes exactly
    // `normalizedReferralCode.isEmpty == false && referralCodeIsValid(normalizedReferralCode) ==
    // false` — deliberately never a second/duplicate validator, per this feature's own task spec.
    // These tests pin the exact behavior of that composition's two ReferralPresentation building
    // blocks so a future change to either one can't silently break the paywall's gating without a
    // test failing here.

    @Test("An empty or whitespace-only referral code normalizes to empty — the paywall treats this as 'no code,' optional, never as an invalid one")
    func blankReferralCode_normalizesToEmpty_isOptionalNotInvalid() {
        for blank in ["", "   ", "\n\t "] {
            let normalized = ReferralPresentation.normalizedReferralCode(blank)
            #expect(normalized.isEmpty)
            // referralCodeIsValid(blank) is false, but the paywall never reads that alone — it
            // only flags a code as invalid when normalizedReferralCode.isEmpty == false AND
            // referralCodeIsValid == false. A blank/whitespace-only value fails the isEmpty
            // check, so it can never reach the "invalid" branch — matching the composition above.
            #expect(ReferralPresentation.referralCodeIsValid(blank) == false)
        }
    }

    @Test(
        "A non-empty, malformed referral code fails validation, so the paywall's isEmpty==false && !isValid gate correctly flags it as invalid",
        arguments: ["SHORT", "ABCD234O", "TOOLONGCODE9"]
    )
    func nonEmptyInvalidReferralCode_failsValidation_gateFlagsInvalid(code: String) {
        let normalized = ReferralPresentation.normalizedReferralCode(code)
        #expect(normalized.isEmpty == false)
        #expect(ReferralPresentation.referralCodeIsValid(code) == false)
        // The exact boolean expression ProUpgradeView.hasInvalidNonEmptyReferralCode composes:
        let hasInvalidNonEmptyReferralCode = normalized.isEmpty == false && ReferralPresentation.referralCodeIsValid(normalized) == false
        #expect(hasInvalidNonEmptyReferralCode)
    }

    @Test("A non-empty, well-formed referral code never trips the paywall's invalid-code gate")
    func nonEmptyValidReferralCode_neverTripsInvalidGate() {
        let normalized = ReferralPresentation.normalizedReferralCode("abcd2345")
        let hasInvalidNonEmptyReferralCode = normalized.isEmpty == false && ReferralPresentation.referralCodeIsValid(normalized) == false
        #expect(hasInvalidNonEmptyReferralCode == false)
    }

    @Test("Pro-hides-entry and Free+canApply-shows-entry are the exact two paywall referral-card outcomes reused from the standalone Refer & Earn screen — no paywall-specific eligibility rule exists")
    func paywallReusesExactStandaloneEntryEligibilityOutcomes() {
        // Free, resolved, authoritative, backend allows it -> the paywall shows the entry field.
        #expect(
            ReferralPresentation.entryEligibility(
                canApplyReferralCode: true,
                isCurrentlyPro: false,
                isEntitlementResolutionPending: false,
                hasAuthoritativeProStatus: true
            ) == .allowed
        )
        // Already Pro -> the paywall never shows entry (a purchase can't happen twice, and
        // attribution must happen before the qualifying purchase).
        #expect(
            ReferralPresentation.entryEligibility(
                canApplyReferralCode: true,
                isCurrentlyPro: true,
                isEntitlementResolutionPending: false,
                hasAuthoritativeProStatus: true
            ) == .blockedAlreadyPro
        )
    }

    // MARK: - shouldBlockPurchaseForReferralInput (pre-merge pass: backend attribution must
    // structurally dominate the paywall CTA's own invalid-input gate, not merely be assumed
    // unreachable — see this function's own header)

    @Test("No backend attribution + a malformed non-empty local code blocks the CTA")
    func shouldBlockPurchase_noBackendCode_malformedLocalInput_blocks() {
        #expect(
            ReferralPresentation.shouldBlockPurchaseForReferralInput(
                backendAppliedReferralCode: nil,
                normalizedReferralCode: "BAD!"
            )
        )
    }

    @Test("No backend attribution + a blank local field never blocks the CTA")
    func shouldBlockPurchase_noBackendCode_blankLocalInput_neverBlocks() {
        #expect(
            ReferralPresentation.shouldBlockPurchaseForReferralInput(
                backendAppliedReferralCode: nil,
                normalizedReferralCode: ""
            ) == false
        )
    }

    @Test("No backend attribution + a well-formed local code never blocks the CTA")
    func shouldBlockPurchase_noBackendCode_validLocalInput_neverBlocks() {
        #expect(
            ReferralPresentation.shouldBlockPurchaseForReferralInput(
                backendAppliedReferralCode: nil,
                normalizedReferralCode: "5SDC95NB"
            ) == false
        )
    }

    @Test("Backend attribution already exists + a malformed stale local code must NOT block the CTA — backend state dominates")
    func shouldBlockPurchase_backendCodeExists_malformedStaleLocalInput_neverBlocks() {
        #expect(
            ReferralPresentation.shouldBlockPurchaseForReferralInput(
                backendAppliedReferralCode: "5SDC95NB",
                normalizedReferralCode: "BAD!"
            ) == false
        )
    }

    @Test("Backend attribution already exists + a different valid stale local code must NOT block the CTA — backend state dominates")
    func shouldBlockPurchase_backendCodeExists_differentValidStaleLocalInput_neverBlocks() {
        #expect(
            ReferralPresentation.shouldBlockPurchaseForReferralInput(
                backendAppliedReferralCode: "5SDC95NB",
                normalizedReferralCode: "ABCD2345"
            ) == false
        )
    }

    @Test("An empty-string backend-applied code is treated identically to nil — never mistaken for real attribution")
    func shouldBlockPurchase_emptyStringBackendCode_treatedAsAbsent() {
        #expect(
            ReferralPresentation.shouldBlockPurchaseForReferralInput(
                backendAppliedReferralCode: "",
                normalizedReferralCode: "BAD!"
            )
        )
    }

    // MARK: - Referred-status copy (20-23)

    @Test("referredStatus 'pending' maps to friendly Pending copy")
    func appliedStatusPresentation_pending() {
        let presentation = ReferralPresentation.appliedStatusPresentation("pending")
        #expect(presentation.title == "Pending")
        #expect(presentation.body.isEmpty == false)
    }

    @Test("referredStatus 'qualified' maps to friendly Qualified copy")
    func appliedStatusPresentation_qualified() {
        let presentation = ReferralPresentation.appliedStatusPresentation("qualified")
        #expect(presentation.title == "Qualified")
    }

    @Test("referredStatus 'reversed' maps to friendly Reversed copy")
    func appliedStatusPresentation_reversed() {
        let presentation = ReferralPresentation.appliedStatusPresentation("reversed")
        #expect(presentation.title == "Reversed")
    }

    @Test(
        "An unrecognized or nil referredStatus falls back to generic 'Applied' copy and never exposes the raw value",
        arguments: (["some_future_status", "REVERSED", ""] as [String?]) + [nil]
    )
    func appliedStatusPresentation_unknownFallback_neverExposesRawValue(referredStatus: String?) {
        let presentation = ReferralPresentation.appliedStatusPresentation(referredStatus)
        #expect(presentation.title == "Applied")
        if let referredStatus, referredStatus.isEmpty == false {
            #expect(presentation.title.contains(referredStatus) == false)
            #expect(presentation.body.contains(referredStatus) == false)
        }
    }

    // MARK: - Error copy (24-31) — never a raw backend string

    @Test("invalidReferralCode maps to safe, specific copy")
    func errorCopy_invalidCode() {
        #expect(ReferralPresentation.userFacingMessage(for: .api(.invalidReferralCode)) == "That referral code isn't valid.")
    }

    @Test("referralCodeNotFound maps to safe, specific copy")
    func errorCopy_codeNotFound() {
        #expect(ReferralPresentation.userFacingMessage(for: .api(.referralCodeNotFound)) == "We couldn't find that referral code.")
    }

    @Test("selfReferralNotAllowed maps to safe, specific copy")
    func errorCopy_selfReferral() {
        #expect(ReferralPresentation.userFacingMessage(for: .api(.selfReferralNotAllowed)) == "You can't use your own referral code.")
    }

    @Test("referralAlreadyApplied maps to safe, specific copy")
    func errorCopy_alreadyApplied() {
        #expect(ReferralPresentation.userFacingMessage(for: .api(.referralAlreadyApplied)) == "A referral code has already been applied to this installation.")
    }

    @Test("revenueCatIdentityConflict maps to a generic, support-safe message that never names RevenueCat")
    func errorCopy_identityConflict() {
        let message = ReferralPresentation.userFacingMessage(for: .api(.revenueCatIdentityConflict))
        #expect(message.isEmpty == false)
        #expect(message.localizedCaseInsensitiveContains("revenuecat") == false)
    }

    @Test("rateLimited maps to safe, specific copy")
    func errorCopy_rateLimited() {
        #expect(ReferralPresentation.userFacingMessage(for: .api(.rateLimited)) == "Too many attempts. Try again shortly.")
    }

    @Test("serviceUnavailable (API) and a raw network failure map to the identical temporarily-unavailable copy")
    func errorCopy_temporaryServiceOrNetwork() {
        let apiMessage = ReferralPresentation.userFacingMessage(for: .api(.serviceUnavailable))
        let networkMessage = ReferralPresentation.userFacingMessage(for: .network("raw socket description, never shown"))
        #expect(apiMessage == "Referral service is temporarily unavailable. Try again.")
        #expect(networkMessage == apiMessage)
        #expect(networkMessage.contains("raw socket description") == false)
    }

    @Test("credentialUnavailable maps to the same generic temporarily-unavailable copy, never a raw OSStatus")
    func errorCopy_credentialUnavailable() {
        #expect(ReferralPresentation.userFacingMessage(for: .credentialUnavailable) == "Referral service is temporarily unavailable. Try again.")
    }

    // MARK: - Share text (32-35)

    @Test("Share text contains the referral code")
    func shareText_containsCode() {
        #expect(ReferralPresentation.shareText(code: "ABCD2345").contains("ABCD2345"))
    }

    @Test("Share text contains the official App Store destination URL")
    func shareText_containsAppStoreDestination() {
        let text = ReferralPresentation.shareText(code: "ABCD2345")
        #expect(text.contains(AppStoreDestination.share.absoluteString))
    }

    @Test("Share text says the code should be used before subscribing")
    func shareText_mentionsBeforeSubscribing() {
        #expect(ReferralPresentation.shareText(code: "ABCD2345").contains("before subscribing"))
    }

    @Test("Share text never contains any installation credential or private identifier")
    func shareText_neverContainsPrivateIdentifiers() {
        let text = ReferralPresentation.shareText(code: "ABCD2345")
        for forbidden in ["installationSecret", "secret", "RevenueCat", "participant", "attribution", "UUID"] {
            #expect(text.localizedCaseInsensitiveContains(forbidden) == false)
        }
    }

    @Test("No presentation copy anywhere in this feature's UI-only layer contains reward-redemption language")
    func noRedemptionLanguage_inPresentationCopy() {
        let forbidden = ["Redeem", "Apply Reward", "Claim", "Start Free Month"]
        let allCopy = [
            ReferralPresentation.appliedStatusPresentation("pending").title,
            ReferralPresentation.appliedStatusPresentation("pending").body,
            ReferralPresentation.appliedStatusPresentation("qualified").title,
            ReferralPresentation.appliedStatusPresentation("qualified").body,
            ReferralPresentation.appliedStatusPresentation("reversed").title,
            ReferralPresentation.appliedStatusPresentation("reversed").body,
            ReferralPresentation.appliedStatusPresentation(nil).title,
            ReferralPresentation.appliedStatusPresentation(nil).body,
            ReferralPresentation.referralProgressUnavailableTitle,
            ReferralPresentation.referralProgressUnavailableBody,
            ReferralPresentation.referralsNeededCopy(3),
            ReferralPresentation.shareText(code: "ABCD2345"),
        ]
        for copy in allCopy {
            for word in forbidden {
                #expect(copy.localizedCaseInsensitiveContains(word) == false)
            }
        }
    }

    // MARK: - Diagnostic support codes (39+) — privacy-safe failure identification

    @Test(
        "Every top-level ReferralServiceError case (except .api, covered separately) maps to its exact support code",
        arguments: [
            (ReferralServiceError.notConfigured, "REF-CONFIG"),
            (ReferralServiceError.credentialUnavailable, "REF-KEYCHAIN"),
            (ReferralServiceError.network("irrelevant — never read, see the dedicated leak test below"), "REF-NETWORK"),
            (ReferralServiceError.decoding, "REF-DECODE"),
            (ReferralServiceError.invalidResponse, "REF-RESPONSE"),
        ]
    )
    func diagnosticCode_topLevelCases(error: ReferralServiceError, expectedCode: String) {
        #expect(ReferralPresentation.diagnosticCode(for: error) == expectedCode)
    }

    @Test(
        "Every ReferralAPIError case maps to its exact support code",
        arguments: [
            (ReferralAPIError.invalidAPIKey, "REF-API-KEY"),
            (ReferralAPIError.invalidInstallationCredentials, "REF-INSTALL-AUTH"),
            (ReferralAPIError.invalidRequestBody, "REF-API-BODY"),
            (ReferralAPIError.unknownAction, "REF-API-ACTION"),
            (ReferralAPIError.invalidReferralCode, "REF-CODE-FORMAT"),
            (ReferralAPIError.referralCodeNotFound, "REF-CODE-NOTFOUND"),
            (ReferralAPIError.selfReferralNotAllowed, "REF-SELF"),
            (ReferralAPIError.referralAlreadyApplied, "REF-ALREADY"),
            (ReferralAPIError.revenueCatIdentityConflict, "REF-RC-CONFLICT"),
            (ReferralAPIError.rateLimited, "REF-RATE"),
            (ReferralAPIError.serviceUnavailable, "REF-SERVICE"),
            (ReferralAPIError.internalError, "REF-INTERNAL"),
            (ReferralAPIError.unrecognized(code: "irrelevant", statusCode: 599), "REF-API-OTHER"),
        ]
    )
    func diagnosticCode_apiErrorCases(apiError: ReferralAPIError, expectedCode: String) {
        #expect(ReferralPresentation.diagnosticCode(for: apiError) == expectedCode)
    }

    @Test("The top-level ReferralServiceError.api(_:) case genuinely delegates to the ReferralAPIError mapping, not a separate/stale copy of it")
    func diagnosticCode_apiCaseDelegates() {
        #expect(ReferralPresentation.diagnosticCode(for: .api(.rateLimited)) == ReferralPresentation.diagnosticCode(for: ReferralAPIError.rateLimited))
        #expect(ReferralPresentation.diagnosticCode(for: .api(.rateLimited)) == "REF-RATE")
    }

    @Test("Two different .network(_:) localizedDescription values both map to the identical REF-NETWORK code — the raw description is never read")
    func diagnosticCode_network_neverLeaksDescription() {
        let first = ReferralPresentation.diagnosticCode(for: .network("Optional(NSError domain=NSURLErrorDomain code=-1009 \"offline\")"))
        let second = ReferralPresentation.diagnosticCode(for: .network("A completely different transport failure string"))
        #expect(first == "REF-NETWORK")
        #expect(second == "REF-NETWORK")
        #expect(first == second)
    }

    @Test("Two different .unrecognized(code:statusCode:) backend values both map to the identical REF-API-OTHER code — the raw code/status is never read")
    func diagnosticCode_unrecognized_neverLeaksRawBackendValue() {
        let first = ReferralPresentation.diagnosticCode(for: .unrecognized(code: "some_future_backend_error", statusCode: 418))
        let second = ReferralPresentation.diagnosticCode(for: .unrecognized(code: "a_totally_different_code", statusCode: 502))
        #expect(first == "REF-API-OTHER")
        #expect(second == "REF-API-OTHER")
        #expect(first == second)
    }

    @Test("supportCodeCopyText contains the support code and the supplied app version/build")
    func supportCodeCopyText_containsSupportCodeAndVersion() {
        let text = ReferralPresentation.supportCodeCopyText(diagnosticCode: "REF-NETWORK", appVersion: "2.4.0", buildNumber: "187")
        #expect(text.contains("REF-NETWORK"))
        #expect(text.contains("2.4.0"))
        #expect(text.contains("187"))
        #expect(text.contains("85Blends"))
    }

    @Test("supportCodeCopyText's only inputs are the code/version/build strings handed to it — it has no way to embed arbitrary raw error text")
    func supportCodeCopyText_cannotContainArbitraryRawErrorText() {
        // supportCodeCopyText(diagnosticCode:appVersion:buildNumber:) takes exactly these three
        // plain strings and nothing else — no ReferralServiceError, no URLSession error, no
        // backend response is ever in scope inside it. This test documents that contract by
        // confirming a value that was never passed in is absent from the output.
        let text = ReferralPresentation.supportCodeCopyText(diagnosticCode: "REF-NETWORK", appVersion: "2.4.0", buildNumber: "187")
        #expect(text.contains("raw backend body this function was never given") == false)
    }
}

private extension ReferralStatus {
    init(canApply: Bool) {
        self.init(
            referralCode: "ABCD2345",
            qualifiedReferrals: 0,
            pendingReferrals: 0,
            earnedMonthsAvailable: 0,
            fulfilledMonths: 0,
            nextMilestoneNumber: 1,
            nextRewardAt: 5,
            referralsNeeded: 5,
            canApplyReferralCode: canApply,
            referredByCode: nil,
            referredStatus: nil
        )
    }
}

// MARK: - Manager/UI contract (36-38)
//
// A separate, @MainActor-isolated struct — constructing a real ReferralManager and calling its
// @MainActor-isolated methods requires this, exactly like ReferralManagerTests.swift's own
// top-level struct (see that file for the identical pattern this mirrors).

@MainActor
struct ReferralPresentationManagerContractTests {
    @Test("The apply path genuinely awaits the manager's backend-confirmed result — it is not fire-and-forget")
    func applyAwaitsBackendResult() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = ReferralManager(
            credentialStore: InMemoryReferralCredentialStore(),
            environmentProvider: FakeReferralEnvironmentProvider(environment: .production),
            identityProvider: FakeReferralRevenueCatIdentityProvider(appUserID: "rc_user_1"),
            serviceFactory: { service }
        )
        await manager.bootstrapIfNeeded()

        let applyCodeGate = TestGate()
        service.applyCodeGate = applyCodeGate
        service.applyCodeResult = .success(
            ReferralApplyCodeResponse(status: ReferralStatus(canApply: false), applyStatus: "applied")
        )

        let applyCompleted = TestFlag()
        let applyTask = Task {
            _ = try await manager.applyReferralCode("ABCD2345")
            await applyCompleted.set(true)
        }
        while service.applyCodeCallCount == 0 { await Task.yield() }
        // Held open — the call must still be in flight, never having "succeeded" locally already.
        #expect(await applyCompleted.get() == false)

        applyCodeGate.open()
        try await applyTask.value
        #expect(await applyCompleted.get())
    }

    @Test("A failed apply throws — it never silently claims success")
    func failedApply_neverClaimsSuccess() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = ReferralManager(
            credentialStore: InMemoryReferralCredentialStore(),
            environmentProvider: FakeReferralEnvironmentProvider(environment: .production),
            identityProvider: FakeReferralRevenueCatIdentityProvider(appUserID: "rc_user_1"),
            serviceFactory: { service }
        )
        await manager.bootstrapIfNeeded()
        service.applyCodeResult = .failure(ReferralServiceError.api(.referralCodeNotFound))

        do {
            _ = try await manager.applyReferralCode("ZZZZ9999")
            Issue.record("Expected applyReferralCode to throw")
        } catch ReferralServiceError.api(.referralCodeNotFound) {
            // expected — the failure propagates rather than being swallowed into a false success.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A successful apply's returned status is exactly the backend's own response — never locally invented")
    func successUsesBackendReturnedStatus() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = ReferralManager(
            credentialStore: InMemoryReferralCredentialStore(),
            environmentProvider: FakeReferralEnvironmentProvider(environment: .production),
            identityProvider: FakeReferralRevenueCatIdentityProvider(appUserID: "rc_user_1"),
            serviceFactory: { service }
        )
        await manager.bootstrapIfNeeded()

        let backendResponse = ReferralApplyCodeResponse(
            status: ReferralStatus(
                referralCode: "ABCD2345", qualifiedReferrals: 4, pendingReferrals: 0,
                earnedMonthsAvailable: 0, fulfilledMonths: 0, nextMilestoneNumber: 1,
                nextRewardAt: 5, referralsNeeded: 1, canApplyReferralCode: false,
                referredByCode: "DISTINCT1", referredStatus: "pending"
            ),
            applyStatus: "applied"
        )
        service.applyCodeResult = .success(backendResponse)

        let result = try await manager.applyReferralCode("DISTINCT1")

        #expect(result == backendResponse.status)
        #expect(result.referredByCode == "DISTINCT1")
    }
}
