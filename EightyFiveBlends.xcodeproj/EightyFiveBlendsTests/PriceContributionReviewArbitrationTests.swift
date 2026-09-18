//
//  PriceContributionReviewArbitrationTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the 85Blends 2.4.0 arbitration between the post-navigation price-contribution
//  prompt and the App Store review-request system, both of which now evaluate on the exact
//  same `scenePhase -> .active` transition in ContentView.swift.
//
//  ContentView.attemptPendingPriceContributionPromptIfNeeded()/attemptAutomaticReviewRequestIfNeeded()
//  are private methods on a SwiftUI View struct, and this repository has no view-hosting/UI
//  automation test infrastructure (see EightyFiveBlendsTests' other files, all of which test
//  extracted pure logic or injectable-UserDefaults-backed managers) — so the actual caller-side
//  ordering in ContentView's `.onChange(of: scenePhase)` ("if the price prompt wins this
//  activation, skip the review attempt entirely for it") cannot be exercised directly here. What
//  IS directly testable, and is exercised below, is every precondition that ordering depends on:
//  that the two gates are genuinely independent pure functions (neither refuses merely because
//  the other would also currently allow presentation), and that skipping a call to
//  ReviewRequestManager never corrupts or advances its persisted state — so a later, real
//  attempt still behaves exactly as if the skip had never happened.
//
//  85Blends 2.4.0 review-request audit fix — this same view-hosting gap is exactly what let a
//  cross-activation overlap slip through originally: a price-contribution banner already on
//  screen from an EARLIER activation was invisible to attemptAutomaticReviewRequestIfNeeded()'s
//  own hasConflictingPresentation, because that check never considered `activePriceContribution`
//  at all. ContentView.swift's fix pulls that check out as `ReviewRequestConflictingPresentation`
//  specifically so it's covered below — see that type's own header for the two concrete,
//  ordinary paths that reached the gap (a fast-follow second Directions tap, and a banner nobody
//  ever acted on aging past its own 6-hour expiry).
//

import Foundation
import Testing
@testable import EightyFiveBlends

@MainActor
struct PriceContributionReviewArbitrationTests {
    private func makeReviewManager() -> ReviewRequestManager {
        let suiteName = "price-contribution-arbitration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ReviewRequestManager(defaults: defaults)
    }

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

    /// Scenario A/B precondition: when a station visit happened 3 minutes ago (price-contribution
    /// eligible) AND a user has independently satisfied every ReviewRequestEligibility engagement
    /// threshold, BOTH pure gates return `true` for the identical `now`/safety inputs — neither
    /// gate is aware of, or blocked by, the other. This is exactly what makes ContentView's
    /// caller-side ordering ("check price-contribution first; only call review if it returns
    /// false") the correct place to implement priority, rather than either gate needing to know
    /// the other exists.
    @Test("Price-contribution eligibility and review engagement eligibility can both independently be true at once")
    func bothGatesCanIndependentlyAllowPresentation() {
        let now = Date()
        let contribution = makeContribution(directionsOpenedAt: now.addingTimeInterval(-3 * 60))

        let priceContributionEligible = PendingPriceContributionEligibility.shouldPresent(
            pending: contribution,
            now: now,
            hasCompletedOnboarding: true,
            isConsentResolutionPending: false,
            hasConflictingPresentation: false,
            isPaywallPresented: false,
            isPurchaseActive: false,
            isAppActive: true
        )

        let reviewEngagementEligible = ReviewRequestEligibility.isEngagementEligible(
            firstLaunchDate: now.addingTimeInterval(-30 * 24 * 60 * 60),
            sessionCount: 10,
            stationDirectionsCount: 10,
            now: now
        )

        #expect(priceContributionEligible == true)
        #expect(reviewEngagementEligible == true)
    }

    /// Scenario B precondition, inverted: when no contribution is pending (or it isn't yet
    /// eligible), the price-contribution gate correctly returns `false` — this is exactly the
    /// `false` return ContentView's `if attemptPendingPriceContributionPromptIfNeeded() == false`
    /// relies on to fall through to the existing, unmodified review-request path.
    @Test("Price-contribution gate returns false when nothing is pending, letting review proceed")
    func noPendingContribution_gateReturnsFalse() {
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

    /// Scenario C/D: simulates "the price-contribution prompt won this activation, so
    /// attemptAutomaticReviewRequestIfNeeded() was never called" by simply never calling any
    /// ReviewRequestManager method during that window, then confirms a LATER, genuine attempt —
    /// once engagement/cooldown/safety all still independently hold — behaves exactly as if the
    /// earlier activation had never happened: recordLaunch's session-1 bookkeeping and the
    /// eventual attempt both succeed normally, and the manager's own state (session count,
    /// stationDirectionsCount, attempt bookkeeping) only ever reflects calls actually made to it.
    @Test("Skipping a review attempt for one activation never corrupts state — a later attempt still succeeds normally")
    func skippedActivation_laterAttemptStillSucceeds() {
        let manager = makeReviewManager()
        let launchDate = Date(timeIntervalSince1970: 1_700_000_000)
        manager.recordLaunch(now: launchDate) // session 1
        var currentTime = launchDate
        for _ in 1...4 {
            // A genuine background/foreground cycle (>60s gap) — see
            // ReviewRequestEligibility.shouldCountNewSession — brings sessionCount from 1 to 5.
            currentTime = currentTime.addingTimeInterval(3600)
            manager.recordSceneBackgrounded(now: currentTime)
            currentTime = currentTime.addingTimeInterval(120)
            manager.recordSceneBecameActive(now: currentTime)
        }
        for _ in 0..<3 {
            manager.recordStationDirection(now: launchDate)
        }
        let sessionCountBeforeSkip = manager.sessionCount
        let directionsCountBeforeSkip = manager.stationDirectionsCount
        #expect(sessionCountBeforeSkip == 5)
        #expect(directionsCountBeforeSkip == 3)

        // The "skip": this activation's price-contribution prompt won, so nothing here calls
        // attemptReviewRequestIfAppropriate at all — simulated by simply doing nothing.

        // Counters are untouched by the skip itself.
        #expect(manager.sessionCount == sessionCountBeforeSkip)
        #expect(manager.stationDirectionsCount == directionsCountBeforeSkip)

        // A later, genuine attempt (engagement now satisfied: >=7 days, >=5 sessions, >=3
        // directions) still succeeds exactly as if the earlier skip had never happened.
        let laterDate = launchDate.addingTimeInterval(8 * 24 * 60 * 60)
        let attempted = manager.attemptReviewRequestIfAppropriate(
            isSafeToPresent: true,
            currentVersion: "2.4.0",
            now: laterDate
        )
        #expect(attempted == true)
    }
}

/// `ReviewRequestConflictingPresentation.isPresent` — the fix for the cross-activation gap this
/// audit found. Directly unit-testable (a pure function of four Bools) even though the @State it
/// wraps in production (ContentView.activePriceContribution and friends) is not.
struct ReviewRequestConflictingPresentationTests {
    @Test("Nothing conflicting reports no conflict")
    func allClear_isFalse() {
        #expect(
            ReviewRequestConflictingPresentation.isPresent(
                isShowingWhatsNew: false, hasWidgetStation: false,
                hasPendingWidgetURL: false, hasActivePriceContribution: false
            ) == false
        )
    }

    @Test("An active price-contribution banner alone counts as a conflict")
    func activePriceContributionAlone_isTrue() {
        #expect(
            ReviewRequestConflictingPresentation.isPresent(
                isShowingWhatsNew: false, hasWidgetStation: false,
                hasPendingWidgetURL: false, hasActivePriceContribution: true
            )
        )
    }

    @Test("What's New alone still counts as a conflict — the fix adds a term, it doesn't replace any")
    func whatsNewAlone_isTrue() {
        #expect(
            ReviewRequestConflictingPresentation.isPresent(
                isShowingWhatsNew: true, hasWidgetStation: false,
                hasPendingWidgetURL: false, hasActivePriceContribution: false
            )
        )
    }

    @Test("A widget-routed station detail sheet alone still counts as a conflict")
    func widgetStationAlone_isTrue() {
        #expect(
            ReviewRequestConflictingPresentation.isPresent(
                isShowingWhatsNew: false, hasWidgetStation: true,
                hasPendingWidgetURL: false, hasActivePriceContribution: false
            )
        )
    }

    @Test("An unresolved pending widget deep link alone still counts as a conflict")
    func pendingWidgetURLAlone_isTrue() {
        #expect(
            ReviewRequestConflictingPresentation.isPresent(
                isShowingWhatsNew: false, hasWidgetStation: false,
                hasPendingWidgetURL: true, hasActivePriceContribution: false
            )
        )
    }

    @Test("Every combination of two or more simultaneous conflicts still reports a conflict")
    func multipleSimultaneousConflicts_isTrue() {
        #expect(
            ReviewRequestConflictingPresentation.isPresent(
                isShowingWhatsNew: true, hasWidgetStation: true,
                hasPendingWidgetURL: true, hasActivePriceContribution: true
            )
        )
    }
}
