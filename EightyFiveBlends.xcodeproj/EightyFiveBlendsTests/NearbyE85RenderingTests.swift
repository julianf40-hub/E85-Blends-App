import XCTest
import SwiftUI
import WidgetKit
import MapKit
@testable import EightyFiveBlends

@MainActor
final class NearbyE85RenderingTests: XCTestCase {
    // Approximate current-generation iPhone reference sizes (points). Real on-device sizes vary
    // slightly by model, but these are close enough to catch clipping/overlap/truncation.
    private static let smallSize = CGSize(width: 155, height: 155)
    private static let mediumSize = CGSize(width: 329, height: 155)
    private static let largeSize = CGSize(width: 329, height: 345)
    private func render(_ entry: NearbyE85Entry, family: WidgetFamily, size: CGSize) throws -> UIImage {
        // `widgetContentMargins` is read-only, so tests can't inject a stand-in value the way
        // production gets it from the real widget host — NearbyE85WidgetView reads whatever
        // default this environment resolves to outside an actual widget render context. Visual
        // captures below confirm small/large still get sensible breathing room from it.
        let view = NearbyE85WidgetView(entry: entry, family: family).content
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static let familySizes: [(String, WidgetFamily, CGSize)] = [
        ("small", .systemSmall, smallSize), ("medium", .systemMedium, mediumSize), ("large", .systemLarge, largeSize),
    ]

    func testFallbackStatesAcrossAllFamilies() throws {
        let now = Date.now
        let first = NearbyE85Station(id: "one", name: "Long Station Name E85 Fuel Center", address: "Example address",
            latitude: 33.45, longitude: -112.07, distanceMiles: 1.2,
            price: .init(dollarsPerGallon: 2.89, reportedAt: now.addingTimeInterval(-20 * 86400), source: .community))
        let second = NearbyE85Station(id: "two", name: "Second station", address: "Example address",
            latitude: 33.46, longitude: -112.08, distanceMiles: 2.8, price: nil)
        // Deliberately no userLatitude/userLongitude — exercises the "ready but no map yet"
        // degraded path (informationCard) for medium/large, since no mapRender is supplied.
        let readyNoMap = NearbyE85Snapshot.make(stations: [first, second], radiusMiles: 25, updatedAt: now, locationAt: now)
        let noStations = NearbyE85Snapshot.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now)
        let cases: [(String, NearbyE85Snapshot?)] = [
            ("ready-no-map-yet", readyNoMap), ("no-stations", noStations),
            ("permission-required", .permissionRequired(at: now)), ("no-cache", nil),
        ]
        for (stateName, snapshot) in cases {
            for (familyName, family, size) in Self.familySizes {
                let image = try render(.init(date: now, snapshot: snapshot), family: family, size: size)
                attach(image, name: "nearby-\(familyName)-\(stateName)")
            }
        }
    }

    // Phoenix-area fixture coordinates so the map region/marker placement is realistic rather
    // than degenerate (e.g. all points identical).
    private static let phoenixUser = (latitude: 33.4484, longitude: -112.0740)

    private func phoenixStations(now: Date) -> (nearest: NearbyE85Station, second: NearbyE85Station, third: NearbyE85Station) {
        (nearest: NearbyE85Station(id: "nearest", name: "Circle K", address: "1 N Central Ave, Phoenix, AZ",
            latitude: 33.4501, longitude: -112.0731, distanceMiles: 0.4,
            price: .init(dollarsPerGallon: 2.89, reportedAt: now.addingTimeInterval(-2 * 86400), source: .community)),
         second: NearbyE85Station(id: "second", name: "QuikTrip", address: "500 E Van Buren St, Phoenix, AZ",
            latitude: 33.4472, longitude: -112.0601, distanceMiles: 1.3, price: nil),
         third: NearbyE85Station(id: "third", name: "Really Long Alliance AutoGas Fuel Center Name", address: "2100 N 7th Ave, Phoenix, AZ",
            latitude: 33.4675, longitude: -112.0850, distanceMiles: 2.1,
            price: .init(dollarsPerGallon: 3.05, reportedAt: now, source: .saved)))
    }

    /// A synthetic (network-free) map render: a flat background plus markers placed with the
    /// same region math the real renderer uses, so the widget's map layout is exercised
    /// deterministically for every state without depending on MapKit tile availability.
    private func syntheticRender(for snapshot: NearbyE85Snapshot, size: CGSize) -> NearbyE85MapRender {
        let user = snapshot.userCoordinate.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            ?? CLLocationCoordinate2D(latitude: Self.phoenixUser.latitude, longitude: Self.phoenixUser.longitude)
        let stationCoordinates = snapshot.stations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stationCoordinates,
                                               aspectRatio: size.width / size.height)
        func point(for coordinate: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(x: size.width * (0.5 + (coordinate.longitude - region.center.longitude) / region.span.longitudeDelta),
                    y: size.height * (0.5 - (coordinate.latitude - region.center.latitude) / region.span.latitudeDelta))
        }
        let backgroundColor = UIColor(red: 0.86, green: 0.90, blue: 0.87, alpha: 1)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let stationMarkers = snapshot.stations.enumerated().map { index, station -> NearbyE85MapMarker in
            let coordinate = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
            let isNearest = index == 0
            return NearbyE85MapMarker(
                id: station.id, kind: isNearest ? .nearestStation : .station, point: point(for: coordinate),
                priceLabel: isNearest ? station.price.map { $0.dollarsPerGallon.formatted(.currency(code: "USD")) } : nil)
        }
        let userPoint = NearbyE85MapRegion.declutteredUserPoint(point(for: user), avoiding: stationMarkers.map(\.point), minimumSeparation: 24)
        let markers = [NearbyE85MapMarker(id: "user", kind: .user, point: userPoint, priceLabel: nil)] + stationMarkers
        return NearbyE85MapRender(image: image, size: size, markers: markers)
    }

    func testMediumMapOnlyLayoutAcrossStates() throws {
        let now = Date.now
        let (nearest, second, third) = phoenixStations(now: now)
        let ready = NearbyE85Snapshot.make(stations: [nearest, second, third], radiusMiles: 25, updatedAt: now, locationAt: now,
                                          userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let stale = NearbyE85Snapshot.make(stations: [nearest], radiusMiles: 25,
                                          updatedAt: now.addingTimeInterval(-2 * 3600), locationAt: now.addingTimeInterval(-2 * 3600),
                                          userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let noPrice = NearbyE85Snapshot.make(stations: [second], radiusMiles: 25, updatedAt: now, locationAt: now,
                                             userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let oneStation = NearbyE85Snapshot.make(stations: [nearest], radiusMiles: 25, updatedAt: now, locationAt: now,
                                                userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)

        let mapSize = NearbyE85MapRenderer.mapSize(for: Self.mediumSize, heightFraction: 1.0)
        let cases: [(String, NearbyE85Snapshot)] = [
            ("ready-three-stations", ready), ("stale-location", stale), ("no-price-nearest", noPrice), ("one-station", oneStation),
        ]
        for (name, snapshot) in cases {
            let entry = NearbyE85Entry(date: now, snapshot: snapshot, mapRender: syntheticRender(for: snapshot, size: mapSize))
            let image = try render(entry, family: .systemMedium, size: Self.mediumSize)
            attach(image, name: "nearby-medium-map-\(name)")
        }
    }

    func testLargeMapAndStationListAcrossStates() throws {
        let now = Date.now
        let (nearest, second, third) = phoenixStations(now: now)
        let mapSize = NearbyE85MapRenderer.mapSize(for: Self.largeSize, heightFraction: 0.6)

        func snapshot(_ stations: [NearbyE85Station], stale: Bool = false) -> NearbyE85Snapshot {
            let timestamp = stale ? now.addingTimeInterval(-2 * 3600) : now
            return .make(stations: stations, radiusMiles: 25, updatedAt: timestamp, locationAt: timestamp,
                        userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        }
        let mixedPrices = snapshot([nearest, second, third])
        let single = snapshot([nearest])
        let noPriceOnly = snapshot([second])
        let stale = snapshot([nearest, second], stale: true)

        let cases: [(String, NearbyE85Snapshot)] = [
            ("mixed-prices", mixedPrices), ("single-station", single),
            ("no-price-rows", noPriceOnly), ("stale-location", stale),
        ]
        for (name, snap) in cases {
            let entry = NearbyE85Entry(date: now, snapshot: snap, mapRender: syntheticRender(for: snap, size: mapSize))
            let image = try render(entry, family: .systemLarge, size: Self.largeSize)
            attach(image, name: "nearby-large-\(name)")
        }
    }

    /// Best-effort real MKMapSnapshotter captures for the final visual review — skipped, not
    /// failed, if this environment has no route to Apple's map tile servers.
    func testMediumMapRealSnapshotterBestEffort() async throws {
        let now = Date.now
        let (nearest, second, _) = phoenixStations(now: now)
        let stations = [nearest, second]
        let size = NearbyE85MapRenderer.mapSize(for: Self.mediumSize, heightFraction: 1.0)
        guard let mapRender = await NearbyE85MapRenderer.render(
            userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude,
            stations: stations, size: size, scale: 2) else {
            throw XCTSkip("No network route to MapKit tile servers in this environment.")
        }
        // MKMapSnapshotter's image must come back in the exact point-space it was asked to
        // render at — this is the invariant that lets marker.point (computed against `size`)
        // line up with the image the widget displays, with no separate scale step anywhere.
        XCTAssertEqual(mapRender.image.size, size)
        let snapshot = NearbyE85Snapshot.make(stations: stations, radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let entry = NearbyE85Entry(date: now, snapshot: snapshot, mapRender: mapRender)
        let image = try render(entry, family: .systemMedium, size: Self.mediumSize)
        attach(image, name: "nearby-medium-map-real-snapshot")
    }

    func testLargeMapRealSnapshotterBestEffort() async throws {
        let now = Date.now
        let (nearest, second, third) = phoenixStations(now: now)
        let stations = [nearest, second, third]
        let size = NearbyE85MapRenderer.mapSize(for: Self.largeSize, heightFraction: 0.6)
        guard let mapRender = await NearbyE85MapRenderer.render(
            userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude,
            stations: stations, size: size, scale: 2) else {
            throw XCTSkip("No network route to MapKit tile servers in this environment.")
        }
        XCTAssertEqual(mapRender.image.size, size)
        let snapshot = NearbyE85Snapshot.make(stations: stations, radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let entry = NearbyE85Entry(date: now, snapshot: snapshot, mapRender: mapRender)
        let image = try render(entry, family: .systemLarge, size: Self.largeSize)
        attach(image, name: "nearby-large-map-real-snapshot")
    }
}

/// `NearbyE85MapView.markerView` — the geographic-anchor fix. `.position(marker.point)` centers
/// a marker view on its coordinate using that view's own layout size, so any decoration (the
/// nearest station's price badge) that grows the view's reported size would silently drag the
/// visible pin away from `marker.point`. These compare the marker's ideal (unconstrained) size
/// with and without a badge — bug regresses the instant they diverge, no MapKit or pixel
/// inspection required.
@MainActor
final class NearbyE85MapMarkerAnchorTests: XCTestCase {
    private func idealSize(of view: some View) -> CGSize {
        let renderer = ImageRenderer(content: view)
        return renderer.uiImage?.size ?? .zero
    }
    private var blankMapView: NearbyE85MapView {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        return NearbyE85MapView(render: NearbyE85MapRender(image: image, size: CGSize(width: 1, height: 1), markers: []))
    }

    func testNearestStationMarkerSizeIsIdenticalWithAndWithoutAPriceBadge() {
        let withoutBadge = NearbyE85MapMarker(id: "n", kind: .nearestStation, point: .zero, priceLabel: nil)
        let withBadge = NearbyE85MapMarker(id: "n", kind: .nearestStation, point: .zero, priceLabel: "$2.89")
        let sizeWithoutBadge = idealSize(of: blankMapView.markerView(withoutBadge))
        let sizeWithBadge = idealSize(of: blankMapView.markerView(withBadge))
        XCTAssertEqual(sizeWithoutBadge.width, sizeWithBadge.width, accuracy: 0.5)
        XCTAssertEqual(sizeWithoutBadge.height, sizeWithBadge.height, accuracy: 0.5)
    }

    func testNearestStationMarkerSizeIsStableAcrossDifferentPriceLabelLengths() {
        let short = NearbyE85MapMarker(id: "n", kind: .nearestStation, point: .zero, priceLabel: "$2.89")
        let long = NearbyE85MapMarker(id: "n", kind: .nearestStation, point: .zero, priceLabel: "$12,345.67")
        let sizeShort = idealSize(of: blankMapView.markerView(short))
        let sizeLong = idealSize(of: blankMapView.markerView(long))
        // The badge can grow wider/taller for a longer label, but only via the size-neutral
        // overlay — the marker's own (circle) footprint used for `.position()` never changes.
        XCTAssertEqual(sizeShort.width, sizeLong.width, accuracy: 0.5)
        XCTAssertEqual(sizeShort.height, sizeLong.height, accuracy: 0.5)
    }

    func testUserMarkerSizeMatchesItsOuterRing() {
        let user = NearbyE85MapMarker(id: "user", kind: .user, point: .zero, priceLabel: nil)
        let size = idealSize(of: blankMapView.markerView(user))
        XCTAssertEqual(size.width, 16, accuracy: 0.5)
        XCTAssertEqual(size.height, 16, accuracy: 0.5)
    }

    func testPlainStationMarkerNeverCarriesAPriceLabel() {
        // .station (non-nearest) markers never receive a priceLabel from the renderer, so their
        // anchor can't be affected by the same badge-decoration failure mode at all.
        let station = NearbyE85MapMarker(id: "s", kind: .station, point: .zero, priceLabel: nil)
        XCTAssertNil(station.priceLabel)
        XCTAssertGreaterThan(idealSize(of: blankMapView.markerView(station)).width, 0)
    }
}
