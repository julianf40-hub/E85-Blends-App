//
//  ReviewRequestManagerTests.swift
//  EightyFiveBlendsTests
//
//  Tests for ReviewRequestManager's stateful persistence/orchestration — session counting,
//  first-use persistence, station-direction recording, and review-request attempt/cooldown
//  bookkeeping. Each test constructs its own manager backed by an isolated UserDefaults suite
//  (never `.standard`) so these tests never race with each other or with production state —
//  mirrors the isolation pattern already used by NearbyE85RefreshRequest/NearbyE85MapZoom's
//  tests. `ReviewRequestManager` is `@MainActor`, so this suite is too.
//

import Foundation
import Testing
@testable import EightyFiveBlends

@MainActor
struct ReviewRequestManagerTests {
    private func makeManager() -> ReviewRequestManager {
        let suiteName = "review-request-manager-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ReviewRequestManager(defaults: defaults)
    }

    // MARK: - 7. First-use persistence

    @Test("First launch date is written once")
    func recordLaunch_writesFirstLaunchDateOnce() {
        let manager = makeManager()
        let firstDate = Date(timeIntervalSince1970: 1_000_000)
        manager.recordLaunch(now: firstDate)
        #expect(manager.firstLaunchDate == firstDate)
    }

    @Test("A later call to recordLaunch does not overwrite the existing first-launch date")
    func recordLaunch_doesNotOverwriteFirstLaunchDate() {
        let manager = makeManager()
        let firstDate = Date(timeIntervalSince1970: 1_000_000)
        let laterDate = firstDate.addingTimeInterval(999_999)
        manager.recordLaunch(now: firstDate)
        manager.recordLaunch(now: laterDate)
        #expect(manager.firstLaunchDate == firstDate)
    }

    // MARK: - 6. Session counting

    @Test("The initial launch counts as session 1")
    func recordLaunch_countsSessionOne() {
        let manager = makeManager()
        manager.recordLaunch(now: Date())
        #expect(manager.sessionCount == 1)
    }

    @Test("Becoming active with no prior backgrounding does not increment the session count")
    func recordSceneBecameActive_withoutBackgrounding_doesNotIncrement() {
        let manager = makeManager()
        let now = Date()
        manager.recordLaunch(now: now)
        manager.recordSceneBecameActive(now: now.addingTimeInterval(5)) // e.g. a brief .inactive blip
        #expect(manager.sessionCount == 1)
    }

    @Test("Backgrounded for under 60 seconds does not increment the session count")
    func recordSceneBecameActive_shortBackground_doesNotIncrement() {
        let manager = makeManager()
        let now = Date()
        manager.recordLaunch(now: now)
        manager.recordSceneBackgrounded(now: now.addingTimeInterval(10))
        manager.recordSceneBecameActive(now: now.addingTimeInterval(40)) // 30s backgrounded
        #expect(manager.sessionCount == 1)
    }

    @Test("Backgrounded for at least 60 seconds increments the session count")
    func recordSceneBecameActive_longBackground_increments() {
        let manager = makeManager()
        let now = Date()
        manager.recordLaunch(now: now)
        manager.recordSceneBackgrounded(now: now.addingTimeInterval(10))
        manager.recordSceneBecameActive(now: now.addingTimeInterval(10 + 60)) // exactly 60s backgrounded
        #expect(manager.sessionCount == 2)
    }

    @Test("Repeated short Maps-handoff-style background/active cycles never inflate the session count")
    func recordSceneBecameActive_repeatedShortHandoffs_neverInflate() {
        let manager = makeManager()
        var t = Date()
        manager.recordLaunch(now: t)
        for _ in 0..<5 {
            t = t.addingTimeInterval(5)
            manager.recordSceneBackgrounded(now: t)
            t = t.addingTimeInterval(15) // well under the 60s threshold each time
            manager.recordSceneBecameActive(now: t)
        }
        #expect(manager.sessionCount == 1)
    }

    @Test("Multiple genuine backgroundings each add exactly one session")
    func recordSceneBecameActive_multipleLongBackgrounds_incrementEachTime() {
        let manager = makeManager()
        var t = Date()
        manager.recordLaunch(now: t)
        for _ in 0..<3 {
            manager.recordSceneBackgrounded(now: t)
            t = t.addingTimeInterval(120)
            manager.recordSceneBecameActive(now: t)
        }
        #expect(manager.sessionCount == 4) // 1 (launch) + 3 genuine returns
    }

    // MARK: - 3 / 8. Station direction recording

    @Test("Recording a station direction increments the count exactly once")
    func recordStationDirection_incrementsOnce() {
        let manager = makeManager()
        manager.recordStationDirection()
        #expect(manager.stationDirectionsCount == 1)
    }

    @Test("Multiple separate intentional successes increment individually")
    func recordStationDirection_multipleCallsIncrementIndividually() {
        let manager = makeManager()
        manager.recordStationDirection()
        manager.recordStationDirection()
        manager.recordStationDirection()
        #expect(manager.stationDirectionsCount == 3)
    }

    // MARK: - 9. Review request attempt / cooldown recording

    @Test("An attempt is refused when isSafeToPresent is false, even if fully engagement-eligible")
    func attemptReviewRequest_refusedWhenUnsafe() {
        let manager = makeManager()
        seedEngagementEligible(manager)
        let attempted = manager.attemptReviewRequestIfAppropriate(
            isSafeToPresent: false, currentVersion: "2.4.0", now: Date()
        )
        #expect(attempted == false)
        #expect(manager.lastReviewRequestAttemptDate == nil)
    }

    @Test("An attempt is refused when engagement eligibility has not been reached")
    func attemptReviewRequest_refusedWhenNotEligible() {
        let manager = makeManager()
        manager.recordLaunch(now: Date()) // 1 session, 0 directions, 0 days elapsed — not eligible
        let attempted = manager.attemptReviewRequestIfAppropriate(
            isSafeToPresent: true, currentVersion: "2.4.0", now: Date()
        )
        #expect(attempted == false)
    }

    @Test("A successful attempt records the current date and app version")
    func attemptReviewRequest_recordsDateAndVersion() {
        let manager = makeManager()
        seedEngagementEligible(manager)
        let now = Date()
        let attempted = manager.attemptReviewRequestIfAppropriate(
            isSafeToPresent: true, currentVersion: "2.4.0", now: now
        )
        #expect(attempted)
        #expect(manager.lastReviewRequestAttemptDate == now)
        #expect(manager.lastReviewRequestAppVersion == "2.4.0")
    }

    @Test("The manager cannot immediately request again for the same version")
    func attemptReviewRequest_cannotImmediatelyRepeatSameVersion() {
        let manager = makeManager()
        seedEngagementEligible(manager)
        let now = Date()
        #expect(manager.attemptReviewRequestIfAppropriate(isSafeToPresent: true, currentVersion: "2.4.0", now: now))
        // Immediately again, same version, same instant.
        #expect(
            manager.attemptReviewRequestIfAppropriate(isSafeToPresent: true, currentVersion: "2.4.0", now: now) == false
        )
    }

    @Test("A new version well past the cooldown allows a second attempt")
    func attemptReviewRequest_newVersionAfterCooldown_allowsSecondAttempt() {
        let manager = makeManager()
        seedEngagementEligible(manager)
        let firstAttempt = Date()
        #expect(
            manager.attemptReviewRequestIfAppropriate(isSafeToPresent: true, currentVersion: "2.4.0", now: firstAttempt)
        )
        let secondAttempt = firstAttempt.addingTimeInterval(121 * 86_400)
        #expect(
            manager.attemptReviewRequestIfAppropriate(isSafeToPresent: true, currentVersion: "2.5.0", now: secondAttempt)
        )
        #expect(manager.lastReviewRequestAppVersion == "2.5.0")
    }

    // MARK: - 10. Offline

    @Test("Manager persistence and eligibility work with no network dependency (pure UserDefaults + Foundation)")
    func manager_hasNoNetworkDependency() {
        let manager = makeManager()
        seedEngagementEligible(manager)
        #expect(manager.attemptReviewRequestIfAppropriate(isSafeToPresent: true, currentVersion: "2.4.0", now: Date()))
    }

    // MARK: - Helpers

    /// Directly seeds a manager so `ReviewRequestEligibility.isEngagementEligible` reads back
    /// `true` — first launch 8 days ago, 5 sessions, 3 station directions.
    private func seedEngagementEligible(_ manager: ReviewRequestManager) {
        let now = Date()
        let firstLaunch = now.addingTimeInterval(-8 * 86_400)
        manager.recordLaunch(now: firstLaunch)
        var t = firstLaunch
        for _ in 0..<4 { // +4 more genuine sessions on top of launch's session 1 = 5 total
            manager.recordSceneBackgrounded(now: t)
            t = t.addingTimeInterval(120)
            manager.recordSceneBecameActive(now: t)
        }
        manager.recordStationDirection(now: now)
        manager.recordStationDirection(now: now)
        manager.recordStationDirection(now: now)
    }
}

// MARK: - 13 / 14. Manual Rate / Share destinations

struct AppStoreDestinationTests {
    @Test("Rate 85Blends opens the exact App Store write-review URL")
    func writeReview_isExactURL() {
        #expect(AppStoreDestination.writeReview.absoluteString == "https://apps.apple.com/app/id6762037468?action=write-review")
    }

    @Test("Share 85Blends shares the exact plain App Store listing URL")
    func share_isExactURL() {
        #expect(AppStoreDestination.share.absoluteString == "https://apps.apple.com/app/id6762037468")
    }
}
