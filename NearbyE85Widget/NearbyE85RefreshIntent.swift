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
        NearbyE85RefreshRequestStore().markRequested(at: .now)
        WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind)
        return .result()
    }
}
