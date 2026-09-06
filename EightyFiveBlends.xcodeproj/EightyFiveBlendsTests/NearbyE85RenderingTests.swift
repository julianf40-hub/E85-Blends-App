import XCTest
import SwiftUI
import WidgetKit
import MapKit
@testable import EightyFiveBlends

@MainActor
final class NearbyE85RenderingTests: XCTestCase {
    func testSmallAndMediumFallbackAndPriceLayouts() throws {
        let now = Date.now
        let first = NearbyE85Station(id: "one", name: "Long Station Name E85 Fuel Center", address: "Example address",
            latitude: 33.45, longitude: -112.07, distanceMiles: 1.2,
            price: .init(dollarsPerGallon: 2.89, reportedAt: now.addingTimeInterval(-20 * 86400), source: .community))
        let second = NearbyE85Station(id: "two", name: "Second station", address: "Example address",
            latitude: 33.46, longitude: -112.08, distanceMiles: 2.8, price: nil)
        let ready = NearbyE85Snapshot.make(stations: [first, second], radiusMiles: 25, updatedAt: now, locationAt: now)
        let empty = NearbyE85Snapshot.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now)
        let cases: [(String, NearbyE85Snapshot?)] = [("stations-stale-price", ready), ("empty", empty),
            ("permission", .permissionRequired(at: now)), ("no-cache", nil)]
        for (name, snapshot) in cases {
            for (familyName, family, width) in [("small", WidgetFamily.systemSmall, 142.0), ("medium", .systemMedium, 306.0)] {
                let view = NearbyE85WidgetView(entry: .init(date: now, snapshot: snapshot), family: family).content
                    .environment(\.colorScheme, .light)
                    .frame(width: width, height: 142).padding(16).background(Color.white)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage)
                let attachment = XCTAttachment(image: image)
                attachment.name = "nearby-\(familyName)-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    // Phoenix-area fixture coordinates so the map region/marker placement is realistic rather
    // than degenerate (e.g. all points identical).
    private static let phoenixUser = (latitude: 33.4484, longitude: -112.0740)
    private static let mediumSize = CGSize(width: 306, height: 142)

    private func phoenixStations(now: Date) -> (nearest: NearbyE85Station, second: NearbyE85Station, third: NearbyE85Station) {
        (nearest: NearbyE85Station(id: "nearest", name: "Circle K", address: "1 N Central Ave, Phoenix, AZ",
            latitude: 33.4501, longitude: -112.0731, distanceMiles: 0.4,
            price: .init(dollarsPerGallon: 2.89, reportedAt: now.addingTimeInterval(-2 * 86400), source: .community)),
         second: NearbyE85Station(id: "second", name: "QuikTrip", address: "500 E Van Buren St, Phoenix, AZ",
            latitude: 33.4472, longitude: -112.0601, distanceMiles: 1.3, price: nil),
         third: NearbyE85Station(id: "third", name: "Shell", address: "2100 N 7th Ave, Phoenix, AZ",
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

    func testMediumMapLayoutAcrossStates() throws {
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

        let mapSize = NearbyE85MapRenderer.mapSize(for: Self.mediumSize)
        let cases: [(String, NearbyE85Snapshot)] = [
            ("ready-three-stations", ready), ("stale-location", stale), ("no-price-nearest", noPrice), ("one-station", oneStation),
        ]
        for (name, snapshot) in cases {
            let entry = NearbyE85Entry(date: now, snapshot: snapshot, mapRender: syntheticRender(for: snapshot, size: mapSize))
            let view = NearbyE85WidgetView(entry: entry, family: .systemMedium).content
                .environment(\.colorScheme, .light)
                .frame(width: Self.mediumSize.width, height: Self.mediumSize.height).padding(16).background(Color.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "nearby-medium-map-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Best-effort real MKMapSnapshotter capture for the final visual review — skipped, not
    /// failed, if this environment has no route to Apple's map tile servers.
    func testMediumMapRealSnapshotterBestEffort() async throws {
        let now = Date.now
        let (nearest, second, _) = phoenixStations(now: now)
        let stations = [nearest, second]
        let size = NearbyE85MapRenderer.mapSize(for: Self.mediumSize)
        guard let render = await NearbyE85MapRenderer.render(
            userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude,
            stations: stations, size: size, scale: 2) else {
            throw XCTSkip("No network route to MapKit tile servers in this environment.")
        }
        let snapshot = NearbyE85Snapshot.make(stations: stations, radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let entry = NearbyE85Entry(date: now, snapshot: snapshot, mapRender: render)
        let view = NearbyE85WidgetView(entry: entry, family: .systemMedium).content
            .environment(\.colorScheme, .light)
            .frame(width: Self.mediumSize.width, height: Self.mediumSize.height).padding(16).background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "nearby-medium-map-real-snapshot"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
