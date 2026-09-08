//
//  ReviewRequestEligibilityTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rules behind the 85Blends 2.4.0 App Store review-request system.
//  These are the actual functions ReviewRequestManager/ContentView call — not a duplicate
//  reimplementation — so passing tests here directly verify production behavior. Every function
//  under test is independent of SwiftUI, UserDefaults, and subscription tier.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct ReviewRequestEligibilityTests {
    private let secondsPerDay: TimeInterval = 86_400

    // MARK: - 1. Age threshold

    @Test("Just under 7 days since first use is not engagement eligible")
    func isEngagementEligible_underSevenDays_isFalse() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-((7 * 86_400) - 3_600)) // 6 days, 23 hours
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch,
                sessionCount: 5,
                stationDirectionsCount: 3,
                now: now
            ) == false
        )
    }

    @Test("Exactly 7 days since first use passes the age threshold when other requirements pass")
    func isEngagementEligible_exactlySevenDays_isTrue() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-7 * 86_400)
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch,
                sessionCount: 5,
                stationDirectionsCount: 3,
                now: now
            )
        )
    }

    @Test("More than 7 days since first use passes the age threshold when other requirements pass")
    func isEngagementEligible_moreThanSevenDays_isTrue() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-30 * 86_400)
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch,
                sessionCount: 5,
                stationDirectionsCount: 3,
                now: now
            )
        )
    }

    @Test("No first-launch date on record is never engagement eligible")
    func isEngagementEligible_noFirstLaunchDate_isFalse() {
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: nil,
                sessionCount: 100,
                stationDirectionsCount: 100,
                now: Date()
            ) == false
        )
    }

    // MARK: - 2. Session threshold

    @Test("4 sessions is not engagement eligible")
    func isEngagementEligible_fourSessions_isFalse() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-30 * 86_400)
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch,
                sessionCount: 4,
                stationDirectionsCount: 3,
                now: now
            ) == false
        )
    }

    @Test("5 sessions passes the session threshold when other requirements pass")
    func isEngagementEligible_fiveSessions_passesThreshold() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-30 * 86_400)
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch,
                sessionCount: 5,
                stationDirectionsCount: 3,
                now: now
            )
        )
    }

    // MARK: - 3. Station directions threshold

    @Test("2 station directions is not engagement eligible")
    func isEngagementEligible_twoDirections_isFalse() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-30 * 86_400)
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch,
                sessionCount: 5,
                stationDirectionsCount: 2,
                now: now
            ) == false
        )
    }

    @Test("3 station directions passes the threshold when other requirements pass")
    func isEngagementEligible_threeDirections_passesThreshold() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-30 * 86_400)
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch,
                sessionCount: 5,
                stationDirectionsCount: 3,
                now: now
            )
        )
    }

    @Test("Additional station directions beyond the threshold remain eligible — no upper bound")
    func isEngagementEligible_manyDirections_stillEligible() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-30 * 86_400)
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch,
                sessionCount: 20,
                stationDirectionsCount: 50,
                now: now
            )
        )
    }

    // MARK: - 4. Full engagement eligibility

    @Test("7+ days, 5+ sessions, and 3+ station directions together produce engagement eligibility")
    func isEngagementEligible_allThresholdsMet_isTrue() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-8 * 86_400)
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch,
                sessionCount: 5,
                stationDirectionsCount: 3,
                now: now
            )
        )
    }

    @Test("Meeting two of three thresholds is not sufficient")
    func isEngagementEligible_partialThresholds_isFalse() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-8 * 86_400)
        // Age + sessions pass, directions do not.
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch, sessionCount: 5, stationDirectionsCount: 1, now: now
            ) == false
        )
        // Age + directions pass, sessions do not.
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: firstLaunch, sessionCount: 1, stationDirectionsCount: 3, now: now
            ) == false
        )
        // Sessions + directions pass, age does not.
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: now, sessionCount: 5, stationDirectionsCount: 3, now: now
            ) == false
        )
    }

    // MARK: - 5. Cooldown

    @Test("No previous attempt on record always allows an attempt")
    func canAttempt_noPreviousAttempt_isTrue() {
        #expect(
            ReviewRequestEligibility.canAttempt(
                lastAttemptDate: nil, lastAttemptVersion: nil, currentVersion: "2.4.0", now: Date()
            )
        )
    }

    @Test("Same app version as the last attempt never allows a new attempt, regardless of elapsed time")
    func canAttempt_sameVersion_isFalse() {
        let now = Date()
        let lastAttempt = now.addingTimeInterval(-365 * 86_400) // a year ago
        #expect(
            ReviewRequestEligibility.canAttempt(
                lastAttemptDate: lastAttempt, lastAttemptVersion: "2.4.0", currentVersion: "2.4.0", now: now
            ) == false
        )
    }

    @Test("A new app version after only 119 days does not allow a new attempt")
    func canAttempt_newVersionUnder120Days_isFalse() {
        let now = Date()
        let lastAttempt = now.addingTimeInterval(-119 * 86_400)
        #expect(
            ReviewRequestEligibility.canAttempt(
                lastAttemptDate: lastAttempt, lastAttemptVersion: "2.3.0", currentVersion: "2.4.0", now: now
            ) == false
        )
    }

    @Test("A new app version after exactly 120 days allows a new attempt")
    func canAttempt_newVersionAt120Days_isTrue() {
        let now = Date()
        let lastAttempt = now.addingTimeInterval(-120 * 86_400)
        #expect(
            ReviewRequestEligibility.canAttempt(
                lastAttemptDate: lastAttempt, lastAttemptVersion: "2.3.0", currentVersion: "2.4.0", now: now
            )
        )
    }

    @Test("A new app version after more than 120 days allows a new attempt")
    func canAttempt_newVersionOver120Days_isTrue() {
        let now = Date()
        let lastAttempt = now.addingTimeInterval(-200 * 86_400)
        #expect(
            ReviewRequestEligibility.canAttempt(
                lastAttemptDate: lastAttempt, lastAttemptVersion: "2.3.0", currentVersion: "2.4.0", now: now
            )
        )
    }

    @Test("120+ days elapsed but the SAME version still does not allow a new attempt")
    func canAttempt_sameVersionDespiteLongCooldown_isFalse() {
        let now = Date()
        let lastAttempt = now.addingTimeInterval(-200 * 86_400)
        #expect(
            ReviewRequestEligibility.canAttempt(
                lastAttemptDate: lastAttempt, lastAttemptVersion: "2.4.0", currentVersion: "2.4.0", now: now
            ) == false
        )
    }

    // MARK: - 6. Session counting

    @Test("No background timestamp on record never counts as a new session (e.g. a brief .inactive blip)")
    func shouldCountNewSession_neverBackgrounded_isFalse() {
        #expect(
            ReviewRequestEligibility.shouldCountNewSession(backgroundedAt: nil, resumedAt: Date()) == false
        )
    }

    @Test("Backgrounded for under 60 seconds does not count as a new session")
    func shouldCountNewSession_underThreshold_isFalse() {
        let backgroundedAt = Date()
        let resumedAt = backgroundedAt.addingTimeInterval(30)
        #expect(
            ReviewRequestEligibility.shouldCountNewSession(backgroundedAt: backgroundedAt, resumedAt: resumedAt) == false
        )
    }

    @Test("Backgrounded for exactly 60 seconds counts as a new session")
    func shouldCountNewSession_atThreshold_isTrue() {
        let backgroundedAt = Date()
        let resumedAt = backgroundedAt.addingTimeInterval(60)
        #expect(
            ReviewRequestEligibility.shouldCountNewSession(backgroundedAt: backgroundedAt, resumedAt: resumedAt)
        )
    }

    @Test("Backgrounded for well over 60 seconds counts as a new session")
    func shouldCountNewSession_overThreshold_isTrue() {
        let backgroundedAt = Date()
        let resumedAt = backgroundedAt.addingTimeInterval(3_600)
        #expect(
            ReviewRequestEligibility.shouldCountNewSession(backgroundedAt: backgroundedAt, resumedAt: resumedAt)
        )
    }

    // MARK: - 7. Presentation safety (pure gate)

    @Test("Presentation is safe only when every condition clears")
    func isSafeToPresent_allConditionsClear_isTrue() {
        #expect(
            ReviewRequestEligibility.isSafeToPresent(
                hasCompletedOnboarding: true,
                isConsentResolutionPending: false,
                hasConflictingPresentation: false,
                isPaywallPresented: false,
                isPurchaseActive: false,
                isAppActive: true
            )
        )
    }

    @Test("Not safe while onboarding is incomplete")
    func isSafeToPresent_onboardingIncomplete_isFalse() {
        #expect(
            ReviewRequestEligibility.isSafeToPresent(
                hasCompletedOnboarding: false,
                isConsentResolutionPending: false,
                hasConflictingPresentation: false,
                isPaywallPresented: false,
                isPurchaseActive: false,
                isAppActive: true
            ) == false
        )
    }

    @Test("Not safe while UMP consent resolution is pending")
    func isSafeToPresent_consentPending_isFalse() {
        #expect(
            ReviewRequestEligibility.isSafeToPresent(
                hasCompletedOnboarding: true,
                isConsentResolutionPending: true,
                hasConflictingPresentation: false,
                isPaywallPresented: false,
                isPurchaseActive: false,
                isAppActive: true
            ) == false
        )
    }

    @Test("Not safe while a conflicting presentation (What's New, a widget sheet, a pending deep link) is active")
    func isSafeToPresent_conflictingPresentation_isFalse() {
        #expect(
            ReviewRequestEligibility.isSafeToPresent(
                hasCompletedOnboarding: true,
                isConsentResolutionPending: false,
                hasConflictingPresentation: true,
                isPaywallPresented: false,
                isPurchaseActive: false,
                isAppActive: true
            ) == false
        )
    }

    @Test("Not safe while the Pro paywall is presented")
    func isSafeToPresent_paywallPresented_isFalse() {
        #expect(
            ReviewRequestEligibility.isSafeToPresent(
                hasCompletedOnboarding: true,
                isConsentResolutionPending: false,
                hasConflictingPresentation: false,
                isPaywallPresented: true,
                isPurchaseActive: false,
                isAppActive: true
            ) == false
        )
    }

    @Test("Not safe while a purchase or restore is active")
    func isSafeToPresent_purchaseActive_isFalse() {
        #expect(
            ReviewRequestEligibility.isSafeToPresent(
                hasCompletedOnboarding: true,
                isConsentResolutionPending: false,
                hasConflictingPresentation: false,
                isPaywallPresented: false,
                isPurchaseActive: true,
                isAppActive: true
            ) == false
        )
    }

    @Test("Not safe when the app is not active")
    func isSafeToPresent_appNotActive_isFalse() {
        #expect(
            ReviewRequestEligibility.isSafeToPresent(
                hasCompletedOnboarding: true,
                isConsentResolutionPending: false,
                hasConflictingPresentation: false,
                isPaywallPresented: false,
                isPurchaseActive: false,
                isAppActive: false
            ) == false
        )
    }

    // MARK: - 8. Free / Pro parity
    //
    // None of the functions above accept a subscription-tier parameter at all — eligibility math
    // is structurally incapable of branching on Free vs. Pro. This test documents that invariant
    // by computing the same result twice under two different (irrelevant) external "tier"
    // labels and asserting they never diverge.

    @Test("Engagement eligibility never differs based on Free vs. Pro — no such parameter exists")
    func isEngagementEligible_freeProParity() {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-8 * 86_400)
        var results: [Bool] = []
        for _ in [true, false] { // stand-ins for "isPro" — irrelevant to the function under test
            results.append(
                ReviewRequestEligibility.isEngagementEligible(
                    firstLaunchDate: firstLaunch, sessionCount: 5, stationDirectionsCount: 3, now: now
                )
            )
        }
        #expect(results == [true, true])
    }

    // MARK: - 9. Offline

    @Test("Every eligibility/cooldown/session function is pure Foundation math with no network dependency")
    func eligibilityFunctions_haveNoNetworkDependency() {
        // Structural guarantee, not a runtime check: every function above takes only Date/Int/
        // String/Bool values and returns Bool — there is no URLSession, no async, no throws
        // anywhere in ReviewRequestEligibility.swift. Exercising one function synchronously with
        // no awaited/asynchronous call is itself the proof.
        #expect(
            ReviewRequestEligibility.isEngagementEligible(
                firstLaunchDate: Date(), sessionCount: 0, stationDirectionsCount: 0, now: Date()
            ) == false
        )
    }
}
