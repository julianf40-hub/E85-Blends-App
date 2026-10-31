import AppIntents
import WidgetKit
#if NEARBY_WIDGET_TESTING
@testable import EightyFiveBlends
#endif

/// The one shared manual-refresh action for every Nearby E85 widget family (Small/Medium/Large
/// all use this exact intent — no per-family duplication).
///
/// 85Blends 2.4.1 — performs the refresh itself, so it works with the app fully closed:
/// `perform()` awaits NearbyE85WidgetRefreshCoordinator (bounded one-shot location → new nearby
/// search → atomic cache write) to completion before reloading and returning. The pending-request
/// flag is still marked too, so the app's existing app-active path remains a fallback.
struct NearbyE85RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Nearby E85"
    static var isDiscoverable: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let reload = { WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind) }
        // Pro gate first; a non-Pro access never reaches location or network.
        guard Self.handle(access: NearbyE85WidgetAccessStore().read().status,
                          requestStore: NearbyE85RefreshRequestStore(), now: .now, reloadTimelines: reload) else {
            return .result()
        }
        _ = await NearbyE85WidgetRefreshCoordinator.shared.refresh()
        reload()
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
        NearbyE85Diagnostics.logReloadRequested(source: "refreshIntent")
        reloadTimelines()
        return true
    }
}
