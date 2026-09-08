//
//  ReviewRequestManager.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — App Store review-request system. Persists local-only engagement signals
//  (first use, sessions, successful station directions) and decides whether/when 85Blends may
//  invoke Apple's system review-request API. All policy math lives in
//  ReviewRequestEligibility.swift (pure, independently unit-tested) — this class owns only
//  persistence and orchestration, mirroring how SubscriptionManager/AdManager separate their own
//  pure decision functions from the stateful singleton around them.
//
//  IMPORTANT: this manager never calls Apple's review-request API itself — that's a SwiftUI
//  `@Environment(\.requestReview)` action only a View can hold (see ContentView). This manager's
//  job ends at "is it appropriate to ask right now" — the caller invokes `requestReview()` only
//  when `attemptReviewRequestIfAppropriate` returns true. Apple does not report whether the
//  system sheet actually appeared, and this manager makes no claim that it did — "attempted"
//  means only that 85Blends invoked the mechanism.
//
//  Everything persisted here is local-only (UserDefaults.standard, normal app preferences — not
//  the widget's App Group suite) and is never sent remotely. Review eligibility is completely
//  independent of Free/Pro subscription status — nothing here ever reads `isPro`/`isProUser`.
//

import Foundation
import Observation

@MainActor
@Observable
final class ReviewRequestManager {
    static let shared = ReviewRequestManager()

    /// Injectable for tests (mirrors NearbyE85RefreshRequest/NearbyE85MapZoom's own
    /// `defaults:` seam) — production always uses `.standard`, exactly like every other
    /// preference in this app (see AppPreferenceKey).
    private let defaults: UserDefaults

    /// In-memory only — when the app was last observed transitioning to `.background` (not just
    /// briefly `.inactive`). Never persisted: if the process is killed while backgrounded, the
    /// next launch's `recordLaunch()` establishes session 1 fresh, which is the correct behavior
    /// for "a new process started."
    private var backgroundedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Persisted state (read-only outside this file; see AppPreferenceKey for the keys)

    var firstLaunchDate: Date? {
        defaults.object(forKey: AppPreferenceKey.reviewFirstLaunchDate) as? Date
    }

    private(set) var sessionCount: Int {
        get { defaults.integer(forKey: AppPreferenceKey.reviewSessionCount) }
        set { defaults.set(newValue, forKey: AppPreferenceKey.reviewSessionCount) }
    }

    private(set) var stationDirectionsCount: Int {
        get { defaults.integer(forKey: AppPreferenceKey.reviewStationDirectionsCount) }
        set { defaults.set(newValue, forKey: AppPreferenceKey.reviewStationDirectionsCount) }
    }

    var lastReviewRequestAttemptDate: Date? {
        defaults.object(forKey: AppPreferenceKey.reviewLastRequestAttemptDate) as? Date
    }

    var lastReviewRequestAppVersion: String? {
        defaults.string(forKey: AppPreferenceKey.reviewLastRequestAppVersion)
    }

    /// Debugging/state-clarity only, per design — never read by any gating logic. Recorded once,
    /// the first time engagement eligibility is reached, and never overwritten after that.
    var reviewEligibilityReachedAt: Date? {
        defaults.object(forKey: AppPreferenceKey.reviewEligibilityReachedAt) as? Date
    }

    // MARK: - First use + launch

    /// Call exactly once per process launch (from the app's launch `.task`, alongside RevenueCat/
    /// AdMob configuration). Establishes the first-use timestamp if this is truly the first
    /// launch ever, and counts that launch as session 1. Never overwrites an existing
    /// firstLaunchDate — a reinstall/reset naturally produces a fresh one, which is acceptable
    /// (no forensic App Store install date is ever attempted).
    func recordLaunch(now: Date = Date()) {
        if defaults.object(forKey: AppPreferenceKey.reviewFirstLaunchDate) == nil {
            defaults.set(now, forKey: AppPreferenceKey.reviewFirstLaunchDate)
        }
        if sessionCount == 0 {
            sessionCount = 1
            #if DEBUG
            print("[85Blends][ReviewRequest] Session 1 (first launch) recorded.")
            #endif
        }
        recordEligibilityIfNewlyReached(now: now)
    }

    // MARK: - Session tracking (subsequent foregrounds — see EightyFiveBlendsApp's scenePhase handling)

    /// Call when scenePhase transitions to `.background` (not `.inactive`).
    func recordSceneBackgrounded(now: Date = Date()) {
        backgroundedAt = now
    }

    /// Call when scenePhase transitions to `.active`, for every foreground AFTER the initial
    /// launch (`recordLaunch()` already accounts for launch #1). Only increments the session
    /// count if the app was genuinely backgrounded for at least
    /// `ReviewRequestEligibility.backgroundSessionThresholdSeconds` — a brief `.inactive` blip
    /// (Control Center, a permission dialog, App Switcher, a quick Maps handoff) never counts.
    func recordSceneBecameActive(now: Date = Date()) {
        if ReviewRequestEligibility.shouldCountNewSession(backgroundedAt: backgroundedAt, resumedAt: now) {
            sessionCount += 1
            #if DEBUG
            print("[85Blends][ReviewRequest] New session recorded (count=\(sessionCount)).")
            #endif
        }
        backgroundedAt = nil
        recordEligibilityIfNewlyReached(now: now)
    }

    // MARK: - Station directions (85Blends 2.4.0's primary review signal)

    /// Call exactly once for each deliberate, successful station/navigation launch — see
    /// MapsRoutingHelper.openDirections and TripNavigationLauncher's instrumentation. Never
    /// called for a failed handoff or from raw widget-deep-link parsing; only once routing has
    /// actually resolved to a genuine directions action.
    func recordStationDirection(now: Date = Date()) {
        stationDirectionsCount += 1
        #if DEBUG
        print("[85Blends][ReviewRequest] Station direction recorded (count=\(stationDirectionsCount)).")
        #endif
        recordEligibilityIfNewlyReached(now: now)
    }

    private func recordEligibilityIfNewlyReached(now: Date) {
        guard reviewEligibilityReachedAt == nil else { return }
        guard ReviewRequestEligibility.isEngagementEligible(
            firstLaunchDate: firstLaunchDate,
            sessionCount: sessionCount,
            stationDirectionsCount: stationDirectionsCount,
            now: now
        ) else { return }
        defaults.set(now, forKey: AppPreferenceKey.reviewEligibilityReachedAt)
        #if DEBUG
        print("[85Blends][ReviewRequest] Engagement eligibility reached.")
        #endif
    }

    // MARK: - Review request attempt

    /// The single entry point ContentView calls at a calm, settled foreground moment. Returns
    /// `true` exactly when engagement eligibility, cooldown, AND presentation safety all pass —
    /// and, only in that case, records the attempt (current date + app version) before
    /// returning. The caller is responsible for invoking `@Environment(\.requestReview)`'s
    /// action if and only if this returns `true`; this manager never touches StoreKit directly.
    @discardableResult
    func attemptReviewRequestIfAppropriate(
        isSafeToPresent: Bool,
        currentVersion: String,
        now: Date = Date()
    ) -> Bool {
        guard isSafeToPresent else { return false }
        guard ReviewRequestEligibility.isEngagementEligible(
            firstLaunchDate: firstLaunchDate,
            sessionCount: sessionCount,
            stationDirectionsCount: stationDirectionsCount,
            now: now
        ) else { return false }
        guard ReviewRequestEligibility.canAttempt(
            lastAttemptDate: lastReviewRequestAttemptDate,
            lastAttemptVersion: lastReviewRequestAppVersion,
            currentVersion: currentVersion,
            now: now
        ) else { return false }

        defaults.set(now, forKey: AppPreferenceKey.reviewLastRequestAttemptDate)
        defaults.set(currentVersion, forKey: AppPreferenceKey.reviewLastRequestAppVersion)
        #if DEBUG
        print("[85Blends][ReviewRequest] Review request attempted for version \(currentVersion).")
        #endif
        return true
    }
}

// MARK: - Manual "Rate 85Blends" / "Share 85Blends" destinations

/// Independent of ReviewRequestManager's automatic eligibility system — the manual Settings
/// actions always work regardless of engagement/cooldown state, and never read or write any of
/// the automatic review-request counters above. Kept as plain static values (no dependency on
/// SwiftUI) so the exact URLs are directly unit-testable.
enum AppStoreDestination {
    static let appStoreID = "6762037468"

    /// Opens the public App Store listing directly into the write-a-review flow.
    static var writeReview: URL {
        // Safe to force-unwrap: a literal, hand-verified URL string with no dynamic input.
        URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")!
    }

    /// The plain listing URL, shared via `ShareLink` from "Share 85Blends."
    static var share: URL {
        URL(string: "https://apps.apple.com/app/id\(appStoreID)")!
    }
}
