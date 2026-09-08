//
//  ReviewRequestEligibility.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — pure decision logic behind the App Store review-request system. Kept
//  independent of SwiftUI/UserDefaults/StoreKit, mirroring WhatsNewPresentation/
//  AppExperienceNavigation's separation of pure rules from the stateful code that calls them
//  (ReviewRequestManager for persistence, ContentView for presentation), so every threshold and
//  cooldown rule here is directly unit-testable. See EightyFiveBlendsTests/
//  ReviewRequestEligibilityTests.swift.
//
//  Free and Pro users must see identical results from every function here — subscription tier
//  is never a parameter.
//

import Foundation

enum ReviewRequestEligibility {
    // MARK: - Centralized thresholds (production values — never lowered for a shipping build)

    static let minimumAgeDays: Double = 7
    static let minimumSessions = 5
    static let minimumStationDirections = 3
    static let minimumCooldownDays: Double = 120
    /// How long the app must have been genuinely backgrounded (not just briefly `.inactive`) for
    /// returning to `.active` to count as a new session. See ReviewRequestManager's session
    /// tracking and `shouldCountNewSession(backgroundedAt:resumedAt:)` below.
    static let backgroundSessionThresholdSeconds: TimeInterval = 60

    private static let secondsPerDay: TimeInterval = 86_400

    // MARK: - Engagement eligibility

    /// True once a user has demonstrated meaningful, sustained engagement: enough elapsed time
    /// since first use, enough distinct sessions, and enough successful station-directions
    /// launches (85Blends 2.4.0's primary review signal). This says nothing about cooldown or
    /// presentation safety — see `canAttempt` and `isSafeToPresent` for those, both independent
    /// gates that must ALSO pass before a review request is actually made.
    static func isEngagementEligible(
        firstLaunchDate: Date?,
        sessionCount: Int,
        stationDirectionsCount: Int,
        now: Date
    ) -> Bool {
        guard let firstLaunchDate else { return false }
        guard now.timeIntervalSince(firstLaunchDate) >= minimumAgeDays * secondsPerDay else { return false }
        guard sessionCount >= minimumSessions else { return false }
        guard stationDirectionsCount >= minimumStationDirections else { return false }
        return true
    }

    // MARK: - Cooldown

    /// True only when BOTH hold: the current app version differs from the version a review
    /// request was last attempted for, AND at least `minimumCooldownDays` have passed since that
    /// attempt. A version bump alone never bypasses the cooldown, and an elapsed cooldown alone
    /// never bypasses the version check — both conditions are required together. No prior
    /// attempt (either value `nil`) always allows an attempt.
    static func canAttempt(
        lastAttemptDate: Date?,
        lastAttemptVersion: String?,
        currentVersion: String,
        now: Date
    ) -> Bool {
        guard let lastAttemptDate, let lastAttemptVersion else { return true }
        let versionChanged = currentVersion != lastAttemptVersion
        let cooldownElapsed = now.timeIntervalSince(lastAttemptDate) >= minimumCooldownDays * secondsPerDay
        return versionChanged && cooldownElapsed
    }

    // MARK: - Presentation safety

    /// Pure gate for "is this a safe moment to invoke Apple's review-request API right now." Every
    /// condition must independently allow presentation — this never decides eligibility or
    /// cooldown, only whether the app is currently in a calm-enough state to ask at all.
    /// `hasConflictingPresentation` is the caller's own summary of any other sheet/modal/pending
    /// action already on screen (e.g. What's New, a widget-routed detail sheet, an unresolved
    /// pending deep link) — kept as one bool here so this function stays independent of
    /// ContentView's specific state shape.
    static func isSafeToPresent(
        hasCompletedOnboarding: Bool,
        isConsentResolutionPending: Bool,
        hasConflictingPresentation: Bool,
        isPaywallPresented: Bool,
        isPurchaseActive: Bool,
        isAppActive: Bool
    ) -> Bool {
        hasCompletedOnboarding
            && isConsentResolutionPending == false
            && hasConflictingPresentation == false
            && isPaywallPresented == false
            && isPurchaseActive == false
            && isAppActive
    }

    // MARK: - Session counting

    /// True when the gap between backgrounding and resuming is long enough to count as a new,
    /// meaningful session rather than a brief system-UI blip (Control Center, a permission
    /// dialog, App Switcher, or a quick external-app handoff like Maps). `backgroundedAt == nil`
    /// means the app never actually reached `.background` (e.g. it only went briefly
    /// `.inactive`), which never counts as a new session regardless of elapsed time.
    static func shouldCountNewSession(
        backgroundedAt: Date?,
        resumedAt: Date,
        thresholdSeconds: TimeInterval = backgroundSessionThresholdSeconds
    ) -> Bool {
        guard let backgroundedAt else { return false }
        return resumedAt.timeIntervalSince(backgroundedAt) >= thresholdSeconds
    }
}
