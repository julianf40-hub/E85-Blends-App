import Foundation
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
