import AppIntents
import WidgetKit
#if NEARBY_WIDGET_TESTING
@testable import EightyFiveBlends
#endif

/// Zooms the Large Nearby E85 widget's map in one step. Presentation-only: mutates the shared
/// zoom preference and reloads this widget's timeline so the Provider re-renders the map at the
/// new level — never requests location, never refetches stations.
struct NearbyE85ZoomInIntent: AppIntent {
    static var title: LocalizedStringResource = "Zoom In Nearby E85 Map"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        NearbyE85ZoomIntentHandler.handle(.zoomIn, access: NearbyE85WidgetAccessStore().read().status,
                                          zoomStore: NearbyE85MapZoomStore()) {
            WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind)
        }
        return .result()
    }
}

/// Zooms the Large Nearby E85 widget's map out one step. See NearbyE85ZoomInIntent.
struct NearbyE85ZoomOutIntent: AppIntent {
    static var title: LocalizedStringResource = "Zoom Out Nearby E85 Map"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        NearbyE85ZoomIntentHandler.handle(.zoomOut, access: NearbyE85WidgetAccessStore().read().status,
                                          zoomStore: NearbyE85MapZoomStore()) {
            WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind)
        }
        return .result()
    }
}

/// 85Blends 2.4.0 Pro gate — the shared, injectable body of both zoom intents' `perform()`, unit-
/// tested in NearbyE85WidgetProGateTests. A non-Pro access status (`.free` OR `.unknown`) is a
/// complete no-op: the zoom preference is never written and no reload is requested. Defensive
/// rather than reachable in practice (a non-Pro shell renders no zoom controls — see
/// NearbyE85WidgetView.lockedContent), but an AppIntent is an entry point of its own, so the gate
/// lives here too. For `.pro`, this is exactly the pre-existing `apply(using:)` + reload sequence.
/// Returns whether the zoom action was applied.
nonisolated enum NearbyE85ZoomIntentHandler {
    @discardableResult
    static func handle(_ action: NearbyE85ZoomAction, access: NearbyE85WidgetAccessStatus,
                       zoomStore: NearbyE85MapZoomStore, reloadTimelines: () -> Void) -> Bool {
        guard access.permitsWidgetInteraction else { return false }
        action.apply(using: zoomStore)
        reloadTimelines()
        return true
    }
}
