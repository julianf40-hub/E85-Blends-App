import CoreLocation
import Foundation
import MapKit
import Testing
import WidgetKit
@testable import EightyFiveBlends

/// Confirms the zoom buttons stay fully outside the deep-link/routing system: zooming can only
/// ever mutate the zoom preference (a separate UserDefaults suite from the station cache), and
/// never produces or depends on a `NearbyE85DeepLink` destination, matching this pass's "plus/
/// minus must not open Stations" and "zoom must not refetch stations" requirements.
struct NearbyE85ZoomInteractionIsolationTests {
    @Test func zoomingNeverTouchesTheStationSnapshotCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("snapshot.json")
        let cache = NearbyE85Cache(fileURL: cacheFile)
        let now = Date.now
        let station = NearbyE85Station(id: "a", name: "E85 station", address: "123 Main St",
                                       latitude: 33.45, longitude: -112.07, distanceMiles: 1, price: nil)
        let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now)
        try cache.write(snapshot, now: now)

        let zoomStore = NearbyE85MapZoomStore(defaults: UserDefaults(suiteName: "nearby-e85-zoom-isolation-\(UUID().uuidString)"))
        NearbyE85ZoomAction.zoomIn.apply(using: zoomStore)
        NearbyE85ZoomAction.zoomOut.apply(using: zoomStore)

        #expect(cache.read(now: now) == snapshot)
    }
}

/// `NearbyE85WidgetURLResolver` picks the single default tap destination per family — pure,
/// no rendering required.
struct NearbyE85WidgetURLResolverTests {
    private let now = Date.now
    private func station(_ id: String, distanceMiles: Double = 1) -> NearbyE85Station {
        .init(id: id, name: id, address: "Address", latitude: 33.45, longitude: -112.07, distanceMiles: distanceMiles, price: nil)
    }

    @Test func smallResolvesToDirectionsForTheNearestStation() {
        let snapshot = NearbyE85Snapshot.make(stations: [station("nearest"), station("second", distanceMiles: 2)],
                                              radiusMiles: 25, updatedAt: now, locationAt: now)
        let url = NearbyE85WidgetURLResolver.widgetURL(family: .systemSmall, snapshot: snapshot)
        #expect(NearbyE85DeepLink.parse(url) == .directions(stationID: "nearest"))
    }

    @Test func smallFallsBackToStationsWhenNoActionableStationExists() {
        for snapshot: NearbyE85Snapshot? in [nil, .permissionRequired(at: now), .make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now)] {
            let url = NearbyE85WidgetURLResolver.widgetURL(family: .systemSmall, snapshot: snapshot)
            #expect(NearbyE85DeepLink.parse(url) == .stations)
        }
    }

    @Test func mediumAlwaysResolvesToStationsRegardlessOfState() {
        let ready = NearbyE85Snapshot.make(stations: [station("nearest")], radiusMiles: 25, updatedAt: now, locationAt: now)
        for snapshot: NearbyE85Snapshot? in [ready, nil, .permissionRequired(at: now)] {
            let url = NearbyE85WidgetURLResolver.widgetURL(family: .systemMedium, snapshot: snapshot)
            #expect(NearbyE85DeepLink.parse(url) == .stations)
        }
    }

    @Test func largeDefaultFallbackResolvesToStations() {
        let ready = NearbyE85Snapshot.make(stations: [station("nearest")], radiusMiles: 25, updatedAt: now, locationAt: now)
        let url = NearbyE85WidgetURLResolver.widgetURL(family: .systemLarge, snapshot: ready)
        #expect(NearbyE85DeepLink.parse(url) == .stations)
    }

    @Test func eachLargeRowEncodesItsOwnStationNotTheNearestOne() {
        // Mirrors exactly what NearbyE85Presentation's largeStationList builds per row.
        let stations = [station("Alliance AutoGas"), station("Mobil", distanceMiles: 5.7), station("Circle K", distanceMiles: 7.1)]
        let snapshot = NearbyE85Snapshot.make(stations: stations, radiusMiles: 25, updatedAt: now, locationAt: now)
        let urls = snapshot.stations.map { NearbyE85DeepLink.directionsURL(stationID: $0.id) }
        #expect(NearbyE85DeepLink.parse(urls[0]) == .directions(stationID: "Alliance AutoGas"))
        #expect(NearbyE85DeepLink.parse(urls[1]) == .directions(stationID: "Mobil"))
        #expect(NearbyE85DeepLink.parse(urls[2]) == .directions(stationID: "Circle K"))
        // No two rows ever produce the same URL.
        #expect(Set(urls).count == urls.count)
    }
}

/// `NearbyE85WidgetRouting.resolve` — the pure decision step ContentView dispatches on. No
/// UIApplication/UIKit involved, so every outcome is deterministic.
@MainActor
struct NearbyE85WidgetRoutingTests {
    private let now = Date.now
    private func station(_ id: String, latitude: Double = 33.45, longitude: Double = -112.07) -> NearbyE85Station {
        .init(id: id, name: id, address: "123 Main St", latitude: latitude, longitude: longitude, distanceMiles: 1, price: nil)
    }

    @Test func stationsDestinationAlwaysSwitchesTab() {
        #expect(NearbyE85WidgetRouting.resolve(.stations, snapshot: nil, isAuthorized: false) == .switchToStations)
        let snapshot = NearbyE85Snapshot.make(stations: [station("a")], radiusMiles: 25, updatedAt: now, locationAt: now)
        #expect(NearbyE85WidgetRouting.resolve(.stations, snapshot: snapshot, isAuthorized: true) == .switchToStations)
    }

    @Test func directionsForAKnownAuthorizedStationOpensDirections() {
        let snapshot = NearbyE85Snapshot.make(stations: [station("mobil")], radiusMiles: 25, updatedAt: now, locationAt: now)
        let outcome = NearbyE85WidgetRouting.resolve(.directions(stationID: "mobil"), snapshot: snapshot, isAuthorized: true)
        guard case .openDirections(let destination) = outcome else {
            Issue.record("Expected .openDirections, got \(outcome)")
            return
        }
        #expect(destination.name == "mobil")
        #expect(destination.coordinate?.latitude == 33.45)
        #expect(destination.coordinate?.longitude == -112.07)
    }

    @Test func directionsForAnUnknownStationIDFallsBackToStations() {
        let snapshot = NearbyE85Snapshot.make(stations: [station("mobil")], radiusMiles: 25, updatedAt: now, locationAt: now)
        let outcome = NearbyE85WidgetRouting.resolve(.directions(stationID: "does-not-exist"), snapshot: snapshot, isAuthorized: true)
        #expect(outcome == .switchToStations)
    }

    @Test func directionsWithNoCachedSnapshotFallsBackToStations() {
        let outcome = NearbyE85WidgetRouting.resolve(.directions(stationID: "mobil"), snapshot: nil, isAuthorized: true)
        #expect(outcome == .switchToStations)
    }

    @Test func directionsWhenUnauthorizedFallsBackToStationsEvenIfStationExists() {
        let snapshot = NearbyE85Snapshot.make(stations: [station("mobil")], radiusMiles: 25, updatedAt: now, locationAt: now)
        let outcome = NearbyE85WidgetRouting.resolve(.directions(stationID: "mobil"), snapshot: snapshot, isAuthorized: false)
        #expect(outcome == .switchToStations)
    }

    @Test func directionsForAStationLackingUsableLocationFallsBackToStationDetail() {
        // (0, 0) coordinates alone aren't enough to trigger this — MapsRoutingDestination still
        // falls back to a name/address text query. This only fires when there's truly nothing
        // to route on at all: no usable coordinate AND no name/address text either. Should be
        // unreachable via a real published snapshot (name/address are validated non-empty at
        // publish time) — defensive only, so a corrupted/stale cache can't crash or silently
        // no-op instead of showing something useful.
        let station = NearbyE85Station(id: "bad-coords", name: "", address: "", latitude: 0, longitude: 0,
                                       distanceMiles: 1, price: nil)
        let snapshot = NearbyE85Snapshot(version: NearbyE85Snapshot.schemaVersion, state: .ready, stations: [station],
                                         radiusMiles: 25, updatedAt: now, locationAt: now)
        let outcome = NearbyE85WidgetRouting.resolve(.directions(stationID: "bad-coords"), snapshot: snapshot, isAuthorized: true)
        guard case .showStationDetail(let resolvedStation, let resolvedSnapshot) = outcome else {
            Issue.record("Expected .showStationDetail, got \(outcome)")
            return
        }
        #expect(resolvedStation.id == "bad-coords")
        #expect(resolvedSnapshot == snapshot)
    }
}

/// `MapsRoutingHelper.openDirections` — same production code path widgets/Stations/detail
/// screens all already use, exercised via its injectable I/O seams so no map app needs to be
/// installed for a deterministic result.
/// Serialized — these tests mutate the shared `UserDefaults.standard` preferredMapsApp key
/// (save/restore per test), which would race under Swift Testing's default parallel execution.
@Suite(.serialized)
@MainActor
struct MapsRoutingHelperTests {
    private let destination = MapsRoutingDestination(
        name: "Mobil", streetAddress: "123 Main St", city: "Phoenix", state: "AZ", zip: "85001",
        latitude: 33.45, longitude: -112.07)

    private func withPreferredMapsApp<T>(_ app: MapsAppOption, _ body: () -> T) -> T {
        let previous = UserDefaults.standard.string(forKey: AppPreferenceKey.preferredMapsApp)
        UserDefaults.standard.set(app.rawValue, forKey: AppPreferenceKey.preferredMapsApp)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: AppPreferenceKey.preferredMapsApp) }
            else { UserDefaults.standard.removeObject(forKey: AppPreferenceKey.preferredMapsApp) }
        }
        return body()
    }

    @Test func appleMapsPreferenceOpensAMapItemDirectly() {
        withPreferredMapsApp(.appleMaps) {
            var openedItem: MKMapItem?
            var openedURL: URL?
            let result = MapsRoutingHelper.openDirections(
                to: destination, canOpenURL: { _ in true }, open: { openedURL = $0 }, openMapItem: { openedItem = $0 })
            #expect(result == nil)
            #expect(openedItem != nil)
            #expect(openedURL == nil)
        }
    }

    @Test func googleMapsPreferenceOpensTheGoogleMapsURLWhenInstalled() {
        withPreferredMapsApp(.googleMaps) {
            var openedURL: URL?
            var openedItem: MKMapItem?
            let result = MapsRoutingHelper.openDirections(
                to: destination, canOpenURL: { _ in true }, open: { openedURL = $0 }, openMapItem: { openedItem = $0 })
            #expect(result == nil)
            #expect(openedURL?.scheme == "comgooglemaps")
            #expect(openedURL?.query?.contains("33.45") == true)
            #expect(openedItem == nil)
        }
    }

    @Test func wazePreferenceOpensTheWazeURLWhenInstalled() {
        withPreferredMapsApp(.waze) {
            var openedURL: URL?
            let result = MapsRoutingHelper.openDirections(
                to: destination, canOpenURL: { _ in true }, open: { openedURL = $0 }, openMapItem: { _ in })
            #expect(result == nil)
            #expect(openedURL?.scheme == "waze")
        }
    }

    @Test func missingPreferredThirdPartyAppFallsBackToAppleMaps() {
        for app in [MapsAppOption.googleMaps, .waze] {
            withPreferredMapsApp(app) {
                var openedItem: MKMapItem?
                var openedURL: URL?
                let result = MapsRoutingHelper.openDirections(
                    to: destination, canOpenURL: { _ in false }, open: { openedURL = $0 }, openMapItem: { openedItem = $0 })
                #expect(result == nil)
                #expect(openedItem != nil, "\(app) not installed should fall back to Apple Maps")
                #expect(openedURL == nil)
            }
        }
    }

    @Test func insufficientLocationInformationReturnsAnErrorAndOpensNothing() {
        let empty = MapsRoutingDestination(name: "", streetAddress: "", city: "", state: "", zip: "", latitude: nil, longitude: nil)
        var opened = false
        let result = MapsRoutingHelper.openDirections(
            to: empty, canOpenURL: { _ in true }, open: { _ in opened = true }, openMapItem: { _ in opened = true })
        #expect(result != nil)
        #expect(opened == false)
    }
}
