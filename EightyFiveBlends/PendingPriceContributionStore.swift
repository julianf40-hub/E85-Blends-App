//
//  PendingPriceContributionStore.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — persistence for the single in-flight PendingPriceContribution (see that
//  type's own header), modeled after ReviewRequestManager's own local-only, injectable-
//  UserDefaults pattern (ReviewRequestManager.swift) so this feature's persistence is
//  independently unit-testable the same way. Device-local only — never SwiftData, never
//  CloudKit, never Keychain — this state is ephemeral (see
//  PendingPriceContributionEligibility.maximumAge) and has no reason to sync across a user's
//  devices.
//
//  Holds at most ONE contribution at a time: recording a new one always replaces whatever was
//  already pending, matching "the newest navigation wins" rather than accumulating a history.
//

import Foundation

@MainActor
@Observable
final class PendingPriceContributionStore {
    static let shared = PendingPriceContributionStore()

    /// Injectable for tests (mirrors ReviewRequestManager's own `defaults:` seam) — production
    /// always uses `.standard`.
    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The single persisted contribution, or `nil` if none exists — or if the persisted payload
    /// is corrupt/unreadable, which fails closed to `nil` rather than crashing. A decode failure
    /// is not itself repaired (the corrupt bytes stay on disk) — the next `record(_:)` or
    /// `clear()` call overwrites/removes them normally.
    var current: PendingPriceContribution? {
        guard let data = defaults.data(forKey: AppPreferenceKey.pendingPriceContribution) else {
            return nil
        }
        return try? decoder.decode(PendingPriceContribution.self, from: data)
    }

    /// Persists `contribution`, replacing any contribution already pending. A JSON-encoding
    /// failure (not reachable for this all-scalar-field type in practice) fails silently rather
    /// than throwing — recording a contribution is never allowed to interrupt or fail the
    /// Directions handoff that triggered it (see MapsRoutingHelper.openDirections).
    func record(_ contribution: PendingPriceContribution) {
        guard let data = try? encoder.encode(contribution) else { return }
        defaults.set(data, forKey: AppPreferenceKey.pendingPriceContribution)
    }

    /// Always safe to call, including when nothing is pending (`removeObject` is a no-op in
    /// that case) — used to consume a handled contribution (reported, dismissed, or a cancelled
    /// compact sheet) and, by callers, to discard an expired one.
    func clear() {
        defaults.removeObject(forKey: AppPreferenceKey.pendingPriceContribution)
    }
}

/// 85Blends 2.4.0 — the narrow, one-shot signal that lets the post-navigation banner (owned by
/// ContentView) ask the Stations tab (StationsView) to open its existing, otherwise-private
/// community-reporting sheet for a specific PendingPriceContribution, without widening
/// StationsView's access level or duplicating any of its submission logic. Purely transient,
/// in-memory state — never persisted, never confused with PendingPriceContributionStore's own
/// durable contribution record above. Mirrors the `.shared`-singleton coordination style
/// ReviewRequestManager/SubscriptionManager/AdManager already use elsewhere in this app for
/// exactly this kind of cross-view signal (ContentView already reads
/// SubscriptionManager.shared.isPaywallPresented from a completely different view hierarchy);
/// this is that same pattern, just in the opposite direction — a small, focused, precedented
/// coordination point, not a general-purpose sheet-toggling singleton.
@MainActor
@Observable
final class PriceContributionPresentationRequest {
    static let shared = PriceContributionPresentationRequest()

    /// Set by ContentView when the user taps "Report Price" on the banner; consumed (set back
    /// to `nil`) by StationsView the instant it opens the compact sheet for it.
    var pendingRequest: PendingPriceContribution?

    private init() {}
}
