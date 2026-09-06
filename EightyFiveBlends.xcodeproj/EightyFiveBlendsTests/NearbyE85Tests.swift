import Foundation
import MapKit
import Testing
@testable import EightyFiveBlends

struct NearbyE85Tests {
    private let now = Date(timeIntervalSince1970: 1_788_600_000)
    private func station(_ id: String = "station|a & b", miles: Double = 1, price: NearbyE85Price? = nil) -> NearbyE85Station {
        .init(id: id, name: "E85 station", address: "123 Main St", latitude: 33.45, longitude: -112.07,
              distanceMiles: miles, price: price)
    }
    private func snapshot(stations: [NearbyE85Station]? = nil) -> NearbyE85Snapshot {
        .make(stations: stations ?? [station()], radiusMiles: 25, updatedAt: now, locationAt: now)
    }

    @Test func nearestValidStationsAreSortedDeduplicatedAndBounded() {
        let result = snapshot(stations: [station("far", miles: 26), station("bad", miles: .nan),
            station("c", miles: 3), station("a", miles: 1), station("b", miles: 2), station("a", miles: 4), station("d", miles: 4)])
        #expect(result.stations.map(\.id) == ["a", "b", "c"])
        #expect(result.stations[0].price == nil)
        #expect(result.isValid(at: now))
    }
    @Test func zeroDistanceIsValidAndUnknownCoordinatesAreRejected() {
        #expect(snapshot(stations: [station(miles: 0)]).stations.count == 1)
        let bad = NearbyE85Station(id: "bad", name: "Bad", address: "", latitude: 0, longitude: 0, distanceMiles: 0, price: nil)
        #expect(snapshot(stations: [bad]).state == .noStations)
    }
    @Test func userCoordinateIsKeptWhenValidAndDroppedWhenNot() {
        let withCoordinate = NearbyE85Snapshot.make(stations: [station()], radiusMiles: 25, updatedAt: now, locationAt: now,
                                                     userLatitude: 33.44, userLongitude: -112.08)
        #expect(withCoordinate.userCoordinate?.latitude == 33.44)
        #expect(withCoordinate.userCoordinate?.longitude == -112.08)
        #expect(withCoordinate.isValid(at: now))

        let nullIsland = NearbyE85Snapshot.make(stations: [station()], radiusMiles: 25, updatedAt: now, locationAt: now,
                                                 userLatitude: 0, userLongitude: 0)
        #expect(nullIsland.userCoordinate == nil)

        let missing = NearbyE85Snapshot.make(stations: [station()], radiusMiles: 25, updatedAt: now, locationAt: now)
        #expect(missing.userCoordinate == nil)
        #expect(missing.isValid(at: now))
    }
    @Test func mismatchedUserCoordinateHalfIsInvalid() {
        let value = NearbyE85Snapshot(version: NearbyE85Snapshot.schemaVersion, state: .ready, stations: [station()],
                                       radiusMiles: 25, updatedAt: now, locationAt: now, userLatitude: 33.44, userLongitude: nil)
        #expect(!value.isValid(at: now))
    }
    @Test func emptyResultsPermissionAndMissingCacheAreDistinct() {
        #expect(snapshot(stations: []).state == .noStations)
        #expect(NearbyE85Snapshot.permissionRequired(at: now).state == .permissionRequired)
        #expect(NearbyE85Cache(fileURL: nil).read(now: now) == nil)
        #expect(throws: (any Error).self) { try NearbyE85Cache(fileURL: nil).write(snapshot(), now: now) }
    }
    @Test func oldLocationExpiresEvenWhenSearchJustFinished() {
        let value = NearbyE85Snapshot.make(stations: [station()], radiusMiles: 25, updatedAt: now,
                                           locationAt: now.addingTimeInterval(-NearbyE85Snapshot.expiresAfter))
        #expect(!value.isValid(at: now))
    }
    @Test func freshnessAndExpiryHaveExplicitBoundaries() {
        #expect(!snapshot().isStale(at: now.addingTimeInterval(3599)))
        #expect(snapshot().isStale(at: now.addingTimeInterval(3600)))
        #expect(snapshot().isValid(at: now.addingTimeInterval(86399)))
        #expect(!snapshot().isValid(at: now.addingTimeInterval(86400)))
    }
    @Test func invalidPricesNeverBecomeZeroOrFreshPrices() {
        for amount in [0, -1, .nan, .infinity, 999] {
            #expect(NearbyE85Price.validated(amount, reportedAt: now, source: .community, now: now) == nil)
        }
        let future = NearbyE85Price.validated(2.89, reportedAt: now.addingTimeInterval(600), source: .community, now: now)
        #expect(future?.reportedAt == nil)
        #expect(future?.status(at: now) == "Age unknown")
        let old = NearbyE85Price.validated(2.89, reportedAt: now.addingTimeInterval(-20 * 86400), source: .saved, now: now)
        #expect(old?.status(at: now) == "Stale · 20d ago")
    }
    @Test func cacheRoundTripRevocationCorruptionAndVersioning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        let cache = NearbyE85Cache(fileURL: file)
        #expect(cache.read(now: now) == nil)
        #expect(try cache.write(snapshot(), now: now))
        #expect(cache.read(now: now) == snapshot())
        #expect(try !cache.write(snapshot(), now: now))
        #expect(cache.read(now: now.addingTimeInterval(86400)) == nil)
        try cache.write(.permissionRequired(at: now), now: now)
        #expect(cache.read(now: now)?.stations.isEmpty == true)
        try Data("invalid json".utf8).write(to: file)
        #expect(cache.read(now: now) == nil)
        let unknown = NearbyE85Snapshot(version: 99, state: .ready, stations: [station()], radiusMiles: 25, updatedAt: now, locationAt: now)
        try JSONEncoder().encode(unknown).write(to: file)
        #expect(cache.read(now: now) == nil)
        try Data(repeating: 0, count: 65_537).write(to: file)
        #expect(cache.read(now: now) == nil)
    }
    @Test func readingDoesNotRefreshTimestampAndInvalidWritesPreserveLastGoodSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NearbyE85Cache(fileURL: directory.appendingPathComponent("snapshot.json"))
        try cache.write(snapshot(), now: now)
        #expect(cache.read(now: now.addingTimeInterval(100))?.updatedAt == now)
        let bad = NearbyE85Snapshot(version: 1, state: .noStations, stations: [station()], radiusMiles: 25, updatedAt: now, locationAt: now)
        #expect(throws: (any Error).self) { try cache.write(bad, now: now) }
        #expect(cache.read(now: now) == snapshot())
    }
    @Test func stationLinksRoundTripAndRejectMalformedOrForeignURLs() {
        let key = "station|a & b?#/é"
        let link = NearbyE85DeepLink.url(stationID: key, scheme: "e85blends")
        #expect(NearbyE85DeepLink.parse(link, scheme: "e85blends") == .station(key))
        #expect(NearbyE85DeepLink.parse(NearbyE85DeepLink.url(scheme: "e85blends"), scheme: "e85blends") == .nearby)
        for raw in ["https://nearby", "e85blends://evil", "e85blends://nearby/path", "e85blends://nearby?station=", "e85blends://nearby?station=a&station=b", "e85blends://nearby?other=a", "e85blends://nearby#test", "e85blends-internal://nearby"] {
            #expect(NearbyE85DeepLink.parse(URL(string: raw)!, scheme: "e85blends") == nil)
        }
    }
    @Test func publicationRejectsTypedSearchesRevokedPermissionTravelAndRestoredPreviews() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("search.json")
        let store = StationsRecentSearchStore(persistenceURL: url)
        let center = StationCoordinate(latitude: 33.45, longitude: -112.07)
        store.recordCurrentLocationSearchResult(stations: [], center: center, radiusMiles: 25,
                                               fetchedAt: now, locationAt: now)
        func eligible(_ source: StationsRecentSearchStore, current: Bool = true, authorized: Bool = true,
                      coordinate: StationCoordinate? = nil, fix: Date? = nil) -> StationsSearchSnapshot? {
            NearbyE85Publisher.eligibleSearch(from: source, isCurrentLocationSearch: current, authorized: authorized,
                                             coordinate: coordinate ?? center, fixTimestamp: fix ?? now, now: now)
        }
        #expect(eligible(store) != nil)
        #expect(eligible(store, current: false) == nil)
        #expect(eligible(store, authorized: false) == nil)
        #expect(eligible(store, coordinate: .init(latitude: 40, longitude: -80)) == nil)
        #expect(eligible(store, fix: now.addingTimeInterval(-181)) == nil)
        #expect(eligible(store, fix: now.addingTimeInterval(600)) == nil)
        #expect(eligible(StationsRecentSearchStore(persistenceURL: url)) == nil)
    }

}

/// Pure geometry for the medium widget's map. Phoenix-area coordinates throughout so distances
/// are realistic; assertions check behavior against the algorithm's own named bounds rather than
/// recomputing exact spans, so they stay meaningful if the constants are retuned later.
struct NearbyE85MapRegionTests {
    private let user = CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740)
    private func milesPerDegreeLongitude(at latitude: Double) -> Double {
        max(69.0 * cos(latitude * .pi / 180), 1)
    }
    private func offset(_ coordinate: CLLocationCoordinate2D, latitude: Double = 0, longitude: Double = 0) -> CLLocationCoordinate2D {
        .init(latitude: coordinate.latitude + latitude, longitude: coordinate.longitude + longitude)
    }

    @Test func oneVeryCloseStationDoesNotOverZoom() {
        // A station essentially on top of the user must not collapse the map to street level.
        let station = offset(user, latitude: 0.0005)
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [station], aspectRatio: 2.0)
        let latitudeSpanMiles = region.span.latitudeDelta * 69.0
        #expect(abs(latitudeSpanMiles - NearbyE85MapRegion.minimumSpanMiles) < 0.05)
    }

    @Test func severalNearbyStationsRemainInFrame() {
        let stations = [offset(user, latitude: 0.01, longitude: 0.01),
                         offset(user, latitude: -0.01, longitude: -0.02),
                         offset(user, latitude: 0.02, longitude: -0.01)]
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0)
        let latitudeSpanMiles = region.span.latitudeDelta * 69.0
        let longitudeSpanMiles = region.span.longitudeDelta * milesPerDegreeLongitude(at: region.center.latitude)
        #expect(latitudeSpanMiles >= NearbyE85MapRegion.minimumSpanMiles - 0.01)
        #expect(latitudeSpanMiles <= NearbyE85MapRegion.maximumSpanMiles)
        #expect(longitudeSpanMiles >= NearbyE85MapRegion.minimumSpanMiles - 0.01)
        for station in stations + [user] {
            #expect(abs(station.latitude - region.center.latitude) <= region.span.latitudeDelta / 2 + 0.0001)
            #expect(abs(station.longitude - region.center.longitude) <= region.span.longitudeDelta / 2 + 0.0001)
        }
    }

    @Test func distantOutlierDoesNotZoomOutToMetroScale() {
        let close = offset(user, latitude: 0.01)
        let farOutlier = offset(user, longitude: 1.0) // ~55 miles east at this latitude
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [close, farOutlier], aspectRatio: 2.0)
        let longitudeSpanMiles = region.span.longitudeDelta * milesPerDegreeLongitude(at: region.center.latitude)
        #expect(longitudeSpanMiles <= NearbyE85MapRegion.maximumSpanMiles + 0.5)
        // The outlier's own presence must not have driven the span past the metro-scale ceiling.
        #expect(longitudeSpanMiles < 1.0 * milesPerDegreeLongitude(at: user.latitude) * NearbyE85MapRegion.paddingFactor)
    }

    @Test func aspectRatioWidensTheShorterAxisWithoutShrinkingTheOther() {
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [], aspectRatio: 3.0)
        let latitudeSpanMiles = region.span.latitudeDelta * 69.0
        let longitudeSpanMiles = region.span.longitudeDelta * milesPerDegreeLongitude(at: region.center.latitude)
        #expect(abs(latitudeSpanMiles - NearbyE85MapRegion.minimumSpanMiles) < 0.05)
        #expect(abs(longitudeSpanMiles / latitudeSpanMiles - 3.0) < 0.05)
    }

    @Test func centerIsTheMidpointOfUserAndStations() {
        let station = offset(user, latitude: 0.02, longitude: 0.02)
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [station], aspectRatio: 2.0)
        #expect(abs(region.center.latitude - (user.latitude + station.latitude) / 2) < 0.0001)
        #expect(abs(region.center.longitude - (user.longitude + station.longitude) / 2) < 0.0001)
    }

    @Test func userMarkerIsNudgedAwayFromAnAlmostCoincidingStationPin() {
        // The nearest station is often almost exactly where the user is standing (e.g. at the
        // pump); the blue dot must not disappear underneath that pin.
        let stationPoint = CGPoint(x: 100, y: 100)
        let userPoint = CGPoint(x: 101, y: 100.5) // sub-pixel apart before decluttering
        let result = NearbyE85MapRegion.declutteredUserPoint(userPoint, avoiding: [stationPoint], minimumSeparation: 24)
        let dx = result.x - stationPoint.x, dy = result.y - stationPoint.y
        #expect((dx * dx + dy * dy).squareRoot() >= 23.99)
    }

    @Test func userMarkerIsLeftAloneWhenAlreadyWellSeparated() {
        let stationPoint = CGPoint(x: 100, y: 100)
        let userPoint = CGPoint(x: 160, y: 160)
        let result = NearbyE85MapRegion.declutteredUserPoint(userPoint, avoiding: [stationPoint], minimumSeparation: 24)
        #expect(result == userPoint)
    }
}
