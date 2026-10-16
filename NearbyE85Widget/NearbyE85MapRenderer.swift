import SwiftUI
import MapKit
#if NEARBY_WIDGET_TESTING
@testable import EightyFiveBlends
#endif

/// A single pin to draw over the static map snapshot.
///
/// 85Blends 2.4.1 Phase 2F — Codex P2 finding: this previously carried a pre-formatted
/// `priceLabel: String?`, with the fresh/not-fresh decision baked in once at `render(...)` time.
/// Since one `NearbyE85MapRender` is reused across every entry in a timeline (region/zoom/pins
/// don't change — see `render`'s own comment), a price that was fresh when the map was generated
/// could cross into `.checkPrice` by the time a LATER entry's own date arrives (e.g. the explicit
/// midnight boundary entry `NearbyE85Provider.timeline` schedules), yet the stale baked-in label
/// would still show with no age indicator until the provider happened to run again. `price` now
/// carries the raw, unevaluated data; `NearbyE85MapView.markerView` decides freshness itself
/// against each entry's own `date` at actual display time — the same pattern `isOutOfArea`/
/// `isRefreshing` already use for exactly this reason (see `NearbyE85Entry`'s own header).
nonisolated struct NearbyE85MapMarker: Identifiable {
    enum Kind { case user, nearestStation, station }
    let id: String
    let kind: Kind
    let point: CGPoint
    /// Only ever non-nil for `.nearestStation` — see `priceBadgeLabel(at:)` below for how this
    /// becomes (or doesn't become) a visible badge.
    let price: NearbyE85Price?

    /// Pure, directly-testable version of the exact decision `NearbyE85WidgetView.markerView`
    /// makes for the nearest-station price badge — pulled out specifically because a unit test
    /// can observe this deterministically, while a rendered-pixel test can't reliably tell "no
    /// badge drawn" apart from unrelated SwiftUI/ImageRenderer compositing artifacts.
    func priceBadgeLabel(at referenceDate: Date) -> String? {
        price.flatMap { price in
            price.isFreshEnoughForMapBadge(at: referenceDate) ? price.dollarsPerGallon.formatted(.currency(code: "USD")) : nil
        }
    }
}

/// A rendered static map plus the pixel-space positions of every marker on it. The image and
/// markers travel together so the widget view never has to re-derive one from the other.
/// Produced and consumed entirely on the main actor, so it's never sent across an isolation
/// boundary — UIImage doesn't need to conform to Sendable here.
nonisolated struct NearbyE85MapRender {
    let image: UIImage
    let size: CGSize
    let markers: [NearbyE85MapMarker]
}

// WidgetKit renders a snapshot, not a live map: MKMapSnapshotter produces the raster tile
// image once per timeline, and marker positions are baked in via MapKit's own
// coordinate-to-point conversion so pins land accurately without an interactive MKMapView.
enum NearbyE85MapRenderer {
    /// - Parameter heightFraction: How much of the widget's full canvas the map should occupy —
    ///   `1.0` for the medium family's edge-to-edge map, a smaller fraction (e.g. `0.6`) for the
    ///   large family, which reserves the remainder for its station list. The map always spans
    ///   the widget's full width; only the height is fractional.
    static func mapSize(for displaySize: CGSize, heightFraction: Double = 1.0) -> CGSize {
        guard displaySize.width > 0, displaySize.height > 0 else { return CGSize(width: 300, height: 114) }
        let height = displaySize.height * min(max(heightFraction, 0.1), 1.0)
        return CGSize(width: displaySize.width, height: max(height, 80))
    }

    @MainActor
    static func render(userLatitude: Double, userLongitude: Double, stations: [NearbyE85Station],
                        size: CGSize, zoomLevel: NearbyE85MapZoomLevel = .default) async -> NearbyE85MapRender? {
        // 85Blends 2.4.1 performance audit (Phase 2A) — purely observational; see
        // NearbyE85Diagnostics's own header for the no-PII rule this call site follows.
        let signpostState = NearbyE85Diagnostics.begin("MapRenderer.render")
        defer { NearbyE85Diagnostics.end("MapRenderer.render", signpostState) }
        guard size.width >= 1, size.height >= 1 else { return nil }
        let userCoordinate = CLLocationCoordinate2D(latitude: userLatitude, longitude: userLongitude)
        let stationCoordinates = stations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let region = NearbyE85MapRegion.region(userCoordinate: userCoordinate, stationCoordinates: stationCoordinates,
                                               aspectRatio: size.width / size.height, zoomLevel: zoomLevel)
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        // 85Blends 2.4.0 widget quality pass — deliberately NOT setting `options.scale`. It was
        // previously hardcoded to 2, which under-rendered on 3x-density hardware (the original
        // softness complaint). `options.scale` is documented as deprecated in favor of trait-based
        // scale resolution, and a WidgetKit TimelineProvider has no trustworthy view/trait
        // environment to resolve that from — UITraitCollection.current isn't populated the way it
        // would be for a live view/view-controller update. Leaving `.scale` unset lets
        // MKMapSnapshotter fall back to its own native, device-appropriate default raster density
        // instead of guessing at one, which is both simpler and sharper on modern hardware.
        options.mapType = .standard
        options.showsBuildings = false

        guard let snapshot = await snapshot(options: options) else {
            NearbyE85Diagnostics.logger.debug("MapRenderer.render: MKMapSnapshotter returned no snapshot")
            return nil
        }

        // 85Blends 2.4.1 Phase 2F — the raw price travels with the marker; whether it's fresh
        // enough to actually show as a badge is decided per timeline entry at display time (see
        // NearbyE85MapMarker's own header for why a render-time decision isn't safe here).
        let stationMarkers = stations.enumerated().map { index, station -> NearbyE85MapMarker in
            let coordinate = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
            let isNearest = index == 0
            return NearbyE85MapMarker(
                id: station.id, kind: isNearest ? .nearestStation : .station,
                point: snapshot.point(for: coordinate), price: isNearest ? station.price : nil)
        }
        // The nearest station is frequently almost co-located with the user (e.g. standing at
        // the pump); nudge the user dot so it never disappears underneath that larger pin.
        let userPoint = NearbyE85MapRegion.declutteredUserPoint(snapshot.point(for: userCoordinate),
                                                                avoiding: stationMarkers.map(\.point), minimumSeparation: 24)
        let markers = [NearbyE85MapMarker(id: "user", kind: .user, point: userPoint, price: nil)] + stationMarkers
        NearbyE85Diagnostics.logger.debug(
            "MapRenderer.render: ok width=\(Int(size.width), privacy: .public) height=\(Int(size.height), privacy: .public) stationCount=\(stations.count, privacy: .public)")
        return NearbyE85MapRender(image: snapshot.image, size: size, markers: markers)
    }

    @MainActor
    private static func snapshot(options: MKMapSnapshotter.Options) async -> MKMapSnapshotter.Snapshot? {
        let snapshotter = MKMapSnapshotter(options: options)
        return await withCheckedContinuation { continuation in
            snapshotter.start { snapshot, _ in continuation.resume(returning: snapshot) }
        }
    }
}
