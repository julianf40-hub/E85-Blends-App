//
//  PendingPriceContributionEligibility.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — pure decision logic behind the post-navigation price-contribution prompt.
//  Kept independent of SwiftUI/UserDefaults, mirroring ReviewRequestEligibility.swift's own
//  separation of pure rules from the stateful code that calls them (PendingPriceContributionStore
//  for persistence, ContentView for presentation), so every threshold here is directly
//  unit-testable. See EightyFiveBlendsTests/PendingPriceContributionEligibilityTests.swift.
//
//  Free and Pro users must see identical results from every function here — subscription tier
//  is never a parameter. Community price reporting is a core capability, not a Pro benefit (see
//  CLAUDE.md's Product Policy), and this prompt is simply a discoverability affordance for that
//  same, already-available-to-everyone capability.
//

import Foundation

enum PendingPriceContributionEligibility {
    // MARK: - Centralized thresholds

    /// A successful Directions handoff must be at least this old before the prompt may appear —
    /// filters out an immediate bounce-back to 85Blends (e.g. Maps failed to load, or the tap
    /// was accidental) without needing to prove a fuel purchase actually happened.
    static let minimumElapsedTime: TimeInterval = 2 * 60
    /// Beyond this age, a pending contribution is no longer worth surfacing — recall of "what
    /// was the price" degrades, and the visit itself is no longer recent news. The boundary is
    /// inclusive (exactly `maximumAge` old is still eligible; see `isEligible`/`isExpired`
    /// below) — documented once here so both functions can never define the boundary
    /// differently.
    static let maximumAge: TimeInterval = 6 * 60 * 60

    // MARK: - Time window

    /// True once `contribution` is old enough (`minimumElapsedTime`) and not yet too old
    /// (`maximumAge`, inclusive) to prompt for. `nil` is never eligible — there is nothing to
    /// prompt about.
    static func isEligible(_ contribution: PendingPriceContribution?, now: Date) -> Bool {
        guard let contribution else { return false }
        let elapsed = now.timeIntervalSince(contribution.directionsOpenedAt)
        return elapsed >= minimumElapsedTime && elapsed <= maximumAge
    }

    /// True once `contribution` has aged past `maximumAge` (exclusive — exactly `maximumAge`
    /// old is not yet expired, matching `isEligible`'s own inclusive upper bound) and should be
    /// silently discarded rather than ever prompted for. Callers are responsible for actually
    /// clearing an expired contribution from the store (see PendingPriceContributionStore.
    /// clear()) — this function only classifies, it never mutates anything.
    static func isExpired(_ contribution: PendingPriceContribution, now: Date) -> Bool {
        now.timeIntervalSince(contribution.directionsOpenedAt) > maximumAge
    }

    // MARK: - Presentation safety

    /// Pure gate for "is this a safe moment to show the price-contribution banner right now."
    /// Deliberately mirrors ReviewRequestEligibility.isSafeToPresent's exact input shape — same
    /// onboarding/consent/paywall/purchase/app-active conditions, same
    /// `hasConflictingPresentation` summary bool for whatever other sheet/modal/pending action
    /// ContentView already tracks (What's New, the widget-routed detail sheet, an unresolved
    /// widget deep link) — so a caller that already computes review-request's own gate inputs
    /// can pass the identical values here with no new state to invent.
    ///
    /// This function has no visibility into presentation state StationsView owns privately
    /// (e.g. its own StationPriceUpdateSheet, currently being shown for an unrelated Classic
    /// station) — ContentView cannot see that state, and this file must not fabricate a flag for
    /// it. The banner this gate protects is a non-modal `.safeAreaInset`, not a sheet, so a
    /// StationsView-owned sheet already structurally covers/obscures it whenever one is
    /// showing, without this function needing to know that sheet exists at all — see this
    /// feature's implementation report for the full architectural note.
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

    // MARK: - Combined decision

    /// The single entry point ContentView calls at a calm, settled foreground moment — the exact
    /// same `scenePhase -> .active` hook ReviewRequestManager's own attempt already uses — true
    /// only when a genuinely pending, time-window-eligible contribution exists AND presentation
    /// is safe. `now` is a plain value parameter (never a closure/protocol clock — see this
    /// feature's implementation report for why that matches this codebase's one existing
    /// precedent, `ReviewRequestEligibility`/`ReviewRequestManager`, rather than introducing a
    /// second time-injection pattern).
    static func shouldPresent(
        pending: PendingPriceContribution?,
        now: Date,
        hasCompletedOnboarding: Bool,
        isConsentResolutionPending: Bool,
        hasConflictingPresentation: Bool,
        isPaywallPresented: Bool,
        isPurchaseActive: Bool,
        isAppActive: Bool
    ) -> Bool {
        guard isEligible(pending, now: now) else { return false }
        return isSafeToPresent(
            hasCompletedOnboarding: hasCompletedOnboarding,
            isConsentResolutionPending: isConsentResolutionPending,
            hasConflictingPresentation: hasConflictingPresentation,
            isPaywallPresented: isPaywallPresented,
            isPurchaseActive: isPurchaseActive,
            isAppActive: isAppActive
        )
    }
}
