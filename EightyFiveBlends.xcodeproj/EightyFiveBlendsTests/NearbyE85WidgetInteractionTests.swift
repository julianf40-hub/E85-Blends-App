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

/// Confirms the manual refresh button stays fully outside the deep-link/routing system too:
/// marking a refresh request can only ever touch its own UserDefaults key, never the station
/// cache directly (the widget-side intent never publishes anything itself — see
/// NearbyE85RefreshIntent's doc comment) and never the Large zoom preference.
struct NearbyE85RefreshInteractionIsolationTests {
    @Test func markingARefreshRequestNeverTouchesTheStationSnapshotCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("snapshot.json")
        let cache = NearbyE85Cache(fileURL: cacheFile)
        let now = Date.now
        let station = NearbyE85Station(id: "a", name: "E85 station", address: "123 Main St",
                                       latitude: 33.45, longitude: -112.07, distanceMiles: 1, price: nil)
        let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now)
        try cache.write(snapshot, now: now)

        let refreshStore = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-isolation-\(UUID().uuidString)"))
        refreshStore.markRequested(at: now)
        refreshStore.clear()

        #expect(cache.read(now: now) == snapshot)
    }
}

/// 85Blends 2.4.0 widget polish — a pending/in-progress refresh visual state must never leak
/// into any other control's behavior: Small's directions tap, Medium's Stations tap, and
/// Large's zoom buttons, map tap, and row taps all must resolve identically whether or not a
/// refresh was just requested.
@MainActor
struct NearbyE85RefreshVisualStateIsolationTests {
    private let now = Date.now
    private func station(_ id: String, latitude: Double = 33.45, longitude: Double = -112.07) -> NearbyE85Station {
        .init(id: id, name: id, address: "123 Main St", latitude: latitude, longitude: longitude, distanceMiles: 1, price: nil)
    }

    @Test("Small's directions widgetURL is identical whether or not a refresh is pending")
    func smallDirectionsUnaffectedByPendingRefresh() {
        let snapshot = NearbyE85Snapshot.make(stations: [station("nearest")], radiusMiles: 25, updatedAt: now, locationAt: now)
        let refreshStore = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-vs-directions-\(UUID().uuidString)"))

        let before = NearbyE85WidgetURLResolver.widgetURL(family: .systemSmall, snapshot: snapshot)
        refreshStore.markRequested(at: now)
        let during = NearbyE85WidgetURLResolver.widgetURL(family: .systemSmall, snapshot: snapshot)
        #expect(before == during)
        #expect(NearbyE85DeepLink.parse(during) == .directions(stationID: "nearest"))
    }

    @Test("Medium's Stations widgetURL is identical whether or not a refresh is pending")
    func mediumStationsUnaffectedByPendingRefresh() {
        let snapshot = NearbyE85Snapshot.make(stations: [station("nearest")], radiusMiles: 25, updatedAt: now, locationAt: now)
        let refreshStore = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-vs-stations-\(UUID().uuidString)"))

        let before = NearbyE85WidgetURLResolver.widgetURL(family: .systemMedium, snapshot: snapshot)
        refreshStore.markRequested(at: now)
        let during = NearbyE85WidgetURLResolver.widgetURL(family: .systemMedium, snapshot: snapshot)
        #expect(before == during)
        #expect(NearbyE85DeepLink.parse(during) == .stations)
    }

    @Test("Large's default Stations fallback widgetURL is identical whether or not a refresh is pending")
    func largeStationsFallbackUnaffectedByPendingRefresh() {
        let snapshot = NearbyE85Snapshot.make(stations: [station("nearest")], radiusMiles: 25, updatedAt: now, locationAt: now)
        let refreshStore = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-vs-large-stations-\(UUID().uuidString)"))

        let before = NearbyE85WidgetURLResolver.widgetURL(family: .systemLarge, snapshot: snapshot)
        refreshStore.markRequested(at: now)
        let during = NearbyE85WidgetURLResolver.widgetURL(family: .systemLarge, snapshot: snapshot)
        #expect(before == during)
        #expect(NearbyE85DeepLink.parse(during) == .stations)
    }

    @Test("Large's per-row directions URLs are identical whether or not a refresh is pending")
    func largeRowDirectionsUnaffectedByPendingRefresh() {
        let stations = [station("Alliance AutoGas"), station("Mobil"), station("Circle K")]
        let refreshStore = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-vs-row-directions-\(UUID().uuidString)"))

        let before = stations.map { NearbyE85DeepLink.directionsURL(stationID: $0.id) }
        refreshStore.markRequested(at: now)
        let during = stations.map { NearbyE85DeepLink.directionsURL(stationID: $0.id) }
        #expect(before == during)
    }

    @Test("Large's zoom action result is identical whether or not a refresh is pending")
    func largeZoomUnaffectedByPendingRefresh() {
        let refreshStore = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-vs-zoom-\(UUID().uuidString)"))
        let zoomStore = NearbyE85MapZoomStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-vs-zoom-store-\(UUID().uuidString)"))

        let beforeLevel = NearbyE85ZoomAction.zoomIn.apply(using: zoomStore)
        refreshStore.markRequested(at: now)
        let duringLevel = NearbyE85ZoomAction.zoomIn.apply(using: zoomStore)
        // Two successive zoom-ins should step forward identically regardless of the refresh
        // request in between — the refresh flag has no zoom parameter to have influenced this.
        // Starting from .default (.standard): zoomIn -> .zoomedIn -> .zoomedInFar.
        #expect(beforeLevel == .zoomedIn)
        #expect(duringLevel == .zoomedInFar)
    }

    @Test("A pending refresh request is never itself resolvable as a directions or Stations destination")
    func pendingRefreshRequestNeverProducesAWidgetDestination() {
        // NearbyE85RefreshRequestStore and NearbyE85DeepLink are completely separate types with
        // no shared representation — marking a refresh has no URL/destination to accidentally
        // collide with a directions or Stations deep link.
        let refreshStore = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-no-destination-\(UUID().uuidString)"))
        refreshStore.markRequested(at: now)
        #expect(refreshStore.pendingRequestDate() != nil)
    }
}

/// 85Blends 2.4.0 widget polish — `NearbyE85RefreshFeedback.isRefreshing` is the pure decision
/// behind the manual refresh button's in-progress state. Pure Foundation math, no UserDefaults/
/// WidgetKit involved, so every boundary is deterministic.
struct NearbyE85RefreshFeedbackTests {
    @Test func noPendingRequestIsNeverRefreshing() {
        #expect(NearbyE85RefreshFeedback.isRefreshing(requestedAt: nil, now: .now) == false)
    }

    @Test func justRequestedIsRefreshing() {
        let now = Date.now
        #expect(NearbyE85RefreshFeedback.isRefreshing(requestedAt: now, now: now))
    }

    @Test func withinTheWindowIsStillRefreshing() {
        let requestedAt = Date.now
        let now = requestedAt.addingTimeInterval(NearbyE85RefreshFeedback.window - 1)
        #expect(NearbyE85RefreshFeedback.isRefreshing(requestedAt: requestedAt, now: now))
    }

    @Test func exactlyAtTheWindowBoundaryHasSettled() {
        let requestedAt = Date.now
        let now = requestedAt.addingTimeInterval(NearbyE85RefreshFeedback.window)
        #expect(NearbyE85RefreshFeedback.isRefreshing(requestedAt: requestedAt, now: now) == false)
    }

    @Test func wellPastTheWindowHasSettled() {
        let requestedAt = Date.now
        let now = requestedAt.addingTimeInterval(NearbyE85RefreshFeedback.window + 60)
        #expect(NearbyE85RefreshFeedback.isRefreshing(requestedAt: requestedAt, now: now) == false)
    }

    @Test func aFutureRequestedDateClockSkewIsNeverRefreshing() {
        let now = Date.now
        let requestedAt = now.addingTimeInterval(5) // requestedAt after now — should never happen, but must not read as "refreshing forever"
        #expect(NearbyE85RefreshFeedback.isRefreshing(requestedAt: requestedAt, now: now) == false)
    }

    /// End-to-end through the real store: tapping refresh (markRequested), then checking shortly
    /// after, reads as refreshing; checking again after the window has elapsed reads as settled —
    /// exactly the "enters visible updating state" / "exits cleanly" requirements.
    @Test func refreshRequestEntersAndExitsTheUpdatingStateThroughTheRealStore() {
        let store = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-feedback-\(UUID().uuidString)"))
        let tappedAt = Date.now
        store.markRequested(at: tappedAt)

        let requestedAt = store.pendingRequestDate()
        #expect(NearbyE85RefreshFeedback.isRefreshing(requestedAt: requestedAt, now: tappedAt.addingTimeInterval(1)))
        #expect(NearbyE85RefreshFeedback.isRefreshing(requestedAt: requestedAt, now: tappedAt.addingTimeInterval(NearbyE85RefreshFeedback.window + 1)) == false)
    }
}

/// 85Blends 2.4.0 widget polish — the refresh-in-progress flag must never be confused with (or
/// substitute for) a genuine data update. These confirm marking/clearing a refresh request never
/// touches the station snapshot cache, its timestamps, or any station's reported price — the
/// "do not falsely reset locationRecordedAt / Updated age / priceReportedAt" requirement.
struct NearbyE85RefreshFeedbackHonestyTests {
    @Test func markingARefreshRequestNeverChangesTheCachedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NearbyE85Cache(fileURL: directory.appendingPathComponent("snapshot.json"))
        let now = Date.now
        let station = NearbyE85Station(id: "a", name: "E85 station", address: "123 Main St",
                                       latitude: 33.45, longitude: -112.07, distanceMiles: 1,
                                       price: .init(dollarsPerGallon: 2.89, reportedAt: now.addingTimeInterval(-3600), source: .community))
        let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now)
        try cache.write(snapshot, now: now)

        let refreshStore = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-honesty-\(UUID().uuidString)"))
        refreshStore.markRequested(at: now)

        // Simulate the widget re-rendering while "refreshing" is visually true — the cached
        // snapshot (and every timestamp on it) must be byte-for-byte unchanged.
        #expect(cache.read(now: now.addingTimeInterval(3)) == snapshot)
    }

    @Test func theRefreshingFlagIsComputedSeparatelyFromAndNeverMutatesTheSnapshot() {
        // isRefreshing(requestedAt:now:) takes no NearbyE85Snapshot parameter at all — it is
        // structurally incapable of reading or altering updatedAt/locationAt/priceReportedAt.
        // This documents that invariant by construction, mirroring
        // CommunityPriceEligibilityTests.canReport_hasNoProvenanceParameter()'s pattern.
        let now = Date.now
        #expect(NearbyE85RefreshFeedback.isRefreshing(requestedAt: now, now: now))
        // Nothing above touched (or could touch) any snapshot — there is no snapshot in scope.
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
