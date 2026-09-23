import AppIntents
import WidgetKit
#if NEARBY_WIDGET_TESTING
@testable import EightyFiveBlends
#endif

/// The one shared manual-refresh action for every Nearby E85 widget family (Small/Medium/Large
/// all use this exact intent — no per-family duplication).
///
/// Widget-extension/AppIntent execution has no reliable, supported way to obtain a fresh Core
/// Location fix: widgets get only a brief execution window per interaction, with no guarantee a
/// CLLocationManager delegate callback (which can take an unbounded amount of time waiting on
/// GPS) completes before that window closes, and WidgetKit's own interactivity guidance is to
/// keep `perform()` fast and defer anything slower to the containing app. So this intent does
/// only what's honestly possible from here: mark that a refresh was requested, and reload the
/// timeline with whatever data is already cached — never a faked "Updated now."
///
/// The actual attempt to obtain a newer location happens when the app next becomes active and
/// finds this pending request — see EightyFiveBlendsApp's scenePhase handling and
/// NearbyE85RefreshRequestStore's own doc comment.
struct NearbyE85RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Nearby E85"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        Self.handle(access: NearbyE85WidgetAccessStore().read().status,
                    requestStore: NearbyE85RefreshRequestStore(), now: .now) {
            WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind)
        }
        return .result()
    }

    /// 85Blends 2.4.0 Pro gate — `perform()`'s actual body, with its I/O injected so it's unit-
    /// testable (NearbyE85WidgetProGateTests). A non-Pro access status (`.free` OR `.unknown`) is
    /// a complete no-op: no pending-refresh flag is written (so the app never performs a location
    /// refresh on a locked widget's behalf) and no timeline reload is requested. Defensive rather
    /// than reachable in practice — a non-Pro shell renders no refresh button at all (see
    /// NearbyE85WidgetView.lockedContent) — but an AppIntent is an entry point of its own, so the
    /// gate lives here too, not only in the view. Returns whether the refresh was recorded.
    @discardableResult
    nonisolated static func handle(access: NearbyE85WidgetAccessStatus, requestStore: NearbyE85RefreshRequestStore,
                                   now: Date, reloadTimelines: () -> Void) -> Bool {
        guard access.permitsWidgetInteraction else { return false }
        requestStore.markRequested(at: now)
        reloadTimelines()
        return true
    }
}
