//
//  PendingPriceContributionEligibilityTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rules behind the 85Blends 2.4.0 post-navigation
//  price-contribution prompt. These are the actual functions ContentView calls — not a
//  duplicate reimplementation — so passing tests here directly verify production behavior.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct PendingPriceContributionEligibilityTests {
    private func makeContribution(directionsOpenedAt: Date) -> PendingPriceContribution {
        PendingPriceContribution(
            stationKey: "shell|1 test st|testville|co|80000",
            stationName: "Shell",
            streetAddress: "1 Test St",
            city: "Testville",
            state: "CO",
            zip: "80000",
            latitude: 39.0,
            longitude: -104.0,
            directionsOpenedAt: directionsOpenedAt,
            mapsProvider: "Apple Maps"
        )
    }

    // MARK: - Time window boundaries

    @Test("1m59.999s elapsed is not yet eligible")
    func isEligible_justUnderTwoMinutes_isFalse() {
        let now = Date()
        let contribution = makeContribution(directionsOpenedAt: now.addingTimeInterval(-(119.999)))
        #expect(PendingPriceContributionEligibility.isEligible(contribution, now: now) == false)
    }

    @Test("Exactly 2 minutes elapsed is eligible")
    func isEligible_exactlyTwoMinutes_isTrue() {
        let now = Date()
        let contribution = makeContribution(directionsOpenedAt: now.addingTimeInterval(-120))
        #expect(PendingPriceContributionEligibility.isEligible(contribution, now: now) == true)
    }

    @Test("Well within the window (e.g. 3 minutes) is eligible")
    func isEligible_threeMinutes_isTrue() {
        let now = Date()
        let contribution = makeContribution(directionsOpenedAt: now.addingTimeInterval(-3 * 60))
        #expect(PendingPriceContributionEligibility.isEligible(contribution, now: now) == true)
    }

    @Test("Just before 6 hours elapsed is still eligible")
    func isEligible_justUnderSixHours_isTrue() {
        let now = Date()
        let contribution = makeContribution(directionsOpenedAt: now.addingTimeInterval(-(6 * 60 * 60 - 1)))
        #expect(PendingPriceContributionEligibility.isEligible(contribution, now: now) == true)
    }

    @Test(
        "Exactly 6 hours elapsed is still eligible (inclusive upper bound) and not yet expired — " +
        "isEligible and isExpired agree at the boundary"
    )
    func isEligible_exactlySixHours_isTrueAndNotExpired() {
        let now = Date()
        let contribution = makeContribution(directionsOpenedAt: now.addingTimeInterval(-(6 * 60 * 60)))
        #expect(PendingPriceContributionEligibility.isEligible(contribution, now: now) == true)
        #expect(PendingPriceContributionEligibility.isExpired(contribution, now: now) == false)
    }

    @Test("More than 6 hours elapsed is expired and no longer eligible")
    func isEligible_overSixHours_isFalseAndExpired() {
        let now = Date()
        let contribution = makeContribution(directionsOpenedAt: now.addingTimeInterval(-(6 * 60 * 60 + 1)))
        #expect(PendingPriceContributionEligibility.isEligible(contribution, now: now) == false)
        #expect(PendingPriceContributionEligibility.isExpired(contribution, now: now) == true)
    }

    @Test("No pending contribution (nil) is never eligible")
    func isEligible_nilContribution_isFalse() {
        let now = Date()
        #expect(PendingPriceContributionEligibility.isEligible(nil, now: now) == false)
    }

    // MARK: - Presentation safety matrix — every condition falsified one at a time

    private func safeInputs(
        hasCompletedOnboarding: Bool = true,
        isConsentResolutionPending: Bool = false,
        hasConflictingPresentation: Bool = false,
        isPaywallPresented: Bool = false,
        isPurchaseActive: Bool = false,
        isAppActive: Bool = true
    ) -> Bool {
        PendingPriceContributionEligibility.isSafeToPresent(
            hasCompletedOnboarding: hasCompletedOnboarding,
            isConsentResolutionPending: isConsentResolutionPending,
            hasConflictingPresentation: hasConflictingPresentation,
            isPaywallPresented: isPaywallPresented,
            isPurchaseActive: isPurchaseActive,
            isAppActive: isAppActive
        )
    }

    @Test("Every condition satisfied allows presentation")
    func isSafeToPresent_allClear_isTrue() {
        #expect(safeInputs() == true)
    }

    @Test("Onboarding not complete blocks presentation")
    func isSafeToPresent_onboardingIncomplete_isFalse() {
        #expect(safeInputs(hasCompletedOnboarding: false) == false)
    }

    @Test("Pending UMP consent resolution blocks presentation")
    func isSafeToPresent_consentPending_isFalse() {
        #expect(safeInputs(isConsentResolutionPending: true) == false)
    }

    @Test("A conflicting root-level presentation (e.g. What's New, a widget sheet) blocks presentation")
    func isSafeToPresent_conflictingPresentation_isFalse() {
        #expect(safeInputs(hasConflictingPresentation: true) == false)
    }

    @Test("The paywall being presented blocks presentation")
    func isSafeToPresent_paywallPresented_isFalse() {
        #expect(safeInputs(isPaywallPresented: true) == false)
    }

    @Test("An active purchase in progress blocks presentation")
    func isSafeToPresent_purchaseActive_isFalse() {
        #expect(safeInputs(isPurchaseActive: true) == false)
    }

    @Test("The app not being active blocks presentation")
    func isSafeToPresent_appNotActive_isFalse() {
        #expect(safeInputs(isAppActive: false) == false)
    }

    // MARK: - Combined shouldPresent

    private func shouldPresent(
        directionsOpenedAt: Date,
        now: Date,
        hasCompletedOnboarding: Bool = true,
        isConsentResolutionPending: Bool = false,
        hasConflictingPresentation: Bool = false,
        isPaywallPresented: Bool = false,
        isPurchaseActive: Bool = false,
        isAppActive: Bool = true
    ) -> Bool {
        PendingPriceContributionEligibility.shouldPresent(
            pending: makeContribution(directionsOpenedAt: directionsOpenedAt),
            now: now,
            hasCompletedOnboarding: hasCompletedOnboarding,
            isConsentResolutionPending: isConsentResolutionPending,
            hasConflictingPresentation: hasConflictingPresentation,
            isPaywallPresented: isPaywallPresented,
            isPurchaseActive: isPurchaseActive,
            isAppActive: isAppActive
        )
    }

    @Test("shouldPresent requires BOTH time-window eligibility and presentation safety")
    func shouldPresent_eligibleAndSafe_isTrue() {
        let now = Date()
        #expect(shouldPresent(directionsOpenedAt: now.addingTimeInterval(-3 * 60), now: now) == true)
    }

    @Test("shouldPresent is false when eligible but not yet safe to present")
    func shouldPresent_eligibleButUnsafe_isFalse() {
        let now = Date()
        #expect(
            shouldPresent(
                directionsOpenedAt: now.addingTimeInterval(-3 * 60),
                now: now,
                hasConflictingPresentation: true
            ) == false
        )
    }

    @Test("shouldPresent is false when safe but not yet time-eligible")
    func shouldPresent_safeButNotYetEligible_isFalse() {
        let now = Date()
        #expect(shouldPresent(directionsOpenedAt: now.addingTimeInterval(-30), now: now) == false)
    }

    @Test("shouldPresent is false for a nil pending contribution regardless of every other input")
    func shouldPresent_nilPending_isFalse() {
        let now = Date()
        #expect(
            PendingPriceContributionEligibility.shouldPresent(
                pending: nil,
                now: now,
                hasCompletedOnboarding: true,
                isConsentResolutionPending: false,
                hasConflictingPresentation: false,
                isPaywallPresented: false,
                isPurchaseActive: false,
                isAppActive: true
            ) == false
        )
    }

    // MARK: - Free/Pro parity

    /// Structural, compile-time guard: `isSafeToPresent`/`shouldPresent` take exactly the
    /// parameters listed below — no `isPro`/`isProUser`/subscription-tier parameter exists. If
    /// one is ever added, every call above (and this one) fails to compile, forcing a conscious
    /// decision rather than a silent Pro-gate regression. Mirrors the same structural idiom
    /// already used by CommunityReportCelebrationPresentationTests.swift/
    /// CommunityPriceEligibilityTests.swift. Community price reporting must remain available to
    /// Free and Pro users alike.
    @Test("isSafeToPresent has no provenance/subscription-tier parameter")
    func isSafeToPresent_hasNoSubscriptionTierParameter() {
        let result = PendingPriceContributionEligibility.isSafeToPresent(
            hasCompletedOnboarding: true,
            isConsentResolutionPending: false,
            hasConflictingPresentation: false,
            isPaywallPresented: false,
            isPurchaseActive: false,
            isAppActive: true
        )
        #expect(result == true)
    }
}
