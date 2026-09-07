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
