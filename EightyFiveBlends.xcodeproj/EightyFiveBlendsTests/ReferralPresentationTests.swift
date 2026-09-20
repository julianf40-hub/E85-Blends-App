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
