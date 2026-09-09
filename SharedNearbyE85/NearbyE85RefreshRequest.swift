import Foundation

/// A one-shot "please refresh when you get the chance" flag, set by the widget extension's
/// manual refresh AppIntent and consumed by the main app the next time it becomes active — see
/// EightyFiveBlendsApp's scenePhase handling. Widget/AppIntent execution cannot reliably obtain
/// a fresh Core Location fix itself (see NearbyE85RefreshIntent's own doc comment), so this is
/// the honest hand-off: the intent marks the request and reloads the timeline with the data it
/// already has, and the app performs the actual location refresh once it's able to.
///
/// Deliberately minimal — a single App-Group-shared timestamp, not a second general settings
/// system. Mirrors NearbyE85MapZoomStore's injectable-UserDefaults shape for the same reason:
/// testable without the real App Group entitlement or a live widget host.
nonisolated struct NearbyE85RefreshRequestStore {
    static let key = "NearbyE85PendingManualRefreshRequestedAt"

    let defaults: UserDefaults?

    init(defaults: UserDefaults? = NearbyE85Configuration.appGroup.flatMap { UserDefaults(suiteName: $0) }) {
        self.defaults = defaults
    }

    /// When the most recent manual refresh tap happened, or nil if none is pending (never
    /// requested, already consumed, or the App Group is unavailable).
    func pendingRequestDate() -> Date? {
        guard let defaults, let raw = defaults.object(forKey: Self.key) as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    func markRequested(at date: Date) {
        defaults?.set(date.timeIntervalSinceReferenceDate, forKey: Self.key)
    }

    /// Consumed exactly once by the app-active handler, regardless of whether a fresh location
    /// was actually obtainable — a request that couldn't be fulfilled this launch isn't retried
    /// indefinitely; the ordinary significant-location-change/foreground-movement paths remain
    /// the primary way the widget stays current.
    func clear() {
        defaults?.removeObject(forKey: Self.key)
    }
}

/// 85Blends 2.4.0 widget polish — pure, testable rule for how long the manual-refresh button
/// shows its "in progress" appearance after a tap, before settling back to normal on its own if
/// nothing new has arrived by then. Deliberately separate from NearbyE85RefreshRequestStore's
/// own persistence: the timing math has no dependency on UserDefaults/App Group access, so it's
/// directly unit-testable, and it never touches — or needs to know about — the station snapshot,
/// its timestamps, or whether a genuinely fresh location was ever obtained. This is honest by
/// construction: it can only ever say "a refresh was recently requested," never "new data
/// arrived" (that remains entirely up to whether a new NearbyE85Snapshot was actually published).
nonisolated enum NearbyE85RefreshFeedback {
    /// Long enough to be noticed on a glance back at the Home Screen after tapping refresh;
    /// short enough that the control never looks permanently "stuck" if the app is never
    /// reopened to attempt the actual location refresh (see NearbyE85RefreshIntent's header —
    /// the widget extension alone cannot obtain a fresh fix).
    static let window: TimeInterval = 8

    /// True when `requestedAt` (the most recent manual-refresh tap, from
    /// `NearbyE85RefreshRequestStore.pendingRequestDate()`) is recent enough, relative to `now`,
    /// that the refresh control should still show its in-progress appearance. `now` is normally
    /// a specific timeline entry's own `date` (not wall-clock time), so this produces the correct
    /// answer for every entry a single timeline computation schedules. Negative elapsed time
    /// (a clock-skew/future timestamp, which should never happen in practice) is treated as "not
    /// refreshing" rather than indefinitely true.
    static func isRefreshing(requestedAt: Date?, now: Date) -> Bool {
        guard let requestedAt else { return false }
        let elapsed = now.timeIntervalSince(requestedAt)
        return elapsed >= 0 && elapsed < window
    }
}
