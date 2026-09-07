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
        NearbyE85ZoomAction.zoomIn.apply(using: NearbyE85MapZoomStore())
        WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind)
        return .result()
    }
}

/// Zooms the Large Nearby E85 widget's map out one step. See NearbyE85ZoomInIntent.
struct NearbyE85ZoomOutIntent: AppIntent {
    static var title: LocalizedStringResource = "Zoom Out Nearby E85 Map"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        NearbyE85ZoomAction.zoomOut.apply(using: NearbyE85MapZoomStore())
        WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind)
        return .result()
    }
}
