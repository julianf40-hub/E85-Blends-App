import Foundation
import Testing
import WidgetKit
@testable import EightyFiveBlends

/// 85Blends 2.4.1 — NearbyE85WidgetRefreshCoordinator, the widget's own app-closed refresh. Every
/// dependency is faked (location, NLR transport, cache file, App Group defaults); nothing here
/// touches Core Location, the network, or the real App Group.
@MainActor
struct NearbyE85WidgetRefreshTests {
    private let now = Date()
    private let phoenix = (latitude: 33.4484, longitude: -112.0740)
    private let tucson = (latitude: 32.2226, longitude: -110.9747)

    // MARK: - Fakes

    final class FakeLocation: NearbyE85LocationFixing {
        var authorized = true
        var result: Result<NearbyE85LocationFix, Error>
        var hangs = false
        var calls = 0
        var wasCancelled = false
        init(_ fix: NearbyE85LocationFix) { result = .success(fix) }
        func isAuthorizedForWidgetUpdates() -> Bool { authorized }
        func requestFix() async throws -> NearbyE85LocationFix {
            calls += 1
            if hangs {
                do { try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) } catch { wasCancelled = true; throw error }
            }
            return try result.get()
        }
    }

    final class FakeSearch: NearbyE85StationSearching {
        var results: [NearbyE85SearchResult] = []
        /// nil = a fresh fetch "now" (min(now, distantFuture) == now in the coordinator).
        var sourceFetchedAt: Date?
        var coverageComplete = true
        var warning: StationCatalogueWarning?
        /// When set, the search runs the REAL widget adapter (NearbyE85ProxyStationSearch.response) on this result.
        var catalogueResult: StationCatalogueSearchResult?
        var error: Error?
        var calls = 0
        var gated = false
        var gate: CheckedContinuation<Void, Never>?
        var onSearch: (() -> Void)?
        func search(latitude: Double, longitude: Double, radiusMiles: Double, limit: Int) async throws -> NearbyE85SearchResponse {
            calls += 1
            onSearch?()
            if gated { await withCheckedContinuation { gate = $0 } }
            if let error { throw error }
            if let catalogueResult { return try NearbyE85ProxyStationSearch.response(from: catalogueResult) }
            return NearbyE85SearchResponse(results: results, sourceFetchedAt: sourceFetchedAt ?? .distantFuture,
                                           coverageComplete: coverageComplete, warning: warning)
        }
    }

    private struct Harness {
        let coordinator: NearbyE85WidgetRefreshCoordinator
        let cache: NearbyE85Cache
        let statusStore: NearbyE85RefreshStatusStore
        let areaStore: NearbyE85AreaRelevanceStore
        let requestStore: NearbyE85RefreshRequestStore
    }

    private func harness(location: FakeLocation, search: FakeSearch, immediateDeadlines: Bool = false) -> Harness {
        let cache = NearbyE85Cache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbyE85WidgetRefreshTests-\(UUID().uuidString)/snapshot.json"))
        let defaults = UserDefaults(suiteName: "NearbyE85WidgetRefreshTests-\(UUID().uuidString)")!
        let statusStore = NearbyE85RefreshStatusStore(fileURL: tempStatusURL())
        let areaStore = NearbyE85AreaRelevanceStore(defaults: defaults)
        let requestStore = NearbyE85RefreshRequestStore(defaults: defaults)
        requestStore.markRequested(at: now)
        let fixedNow = now
        let sleeper: NearbyE85WidgetRefreshCoordinator.Sleeper = immediateDeadlines
            ? { @Sendable _ in }
            : { @Sendable _ in try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }
        let coordinator = NearbyE85WidgetRefreshCoordinator(location: location, search: search, cache: cache,
                                                             statusStore: statusStore, requestStore: requestStore, areaRelevanceStore: areaStore,
                                                             now: { fixedNow }, sleep: sleeper)
        return Harness(coordinator: coordinator, cache: cache, statusStore: statusStore, areaStore: areaStore,
                       requestStore: requestStore)
    }

    private func fix(_ point: (latitude: Double, longitude: Double), age: TimeInterval = 5) -> NearbyE85LocationFix {
        NearbyE85LocationFix(latitude: point.latitude, longitude: point.longitude, horizontalAccuracy: 30,
                             timestamp: now.addingTimeInterval(-age))
    }

    private func result(_ name: String, street: String, at point: (latitude: Double, longitude: Double)) -> NearbyE85SearchResult {
        NearbyE85SearchResult(name: name, address: street, city: "Somewhere", state: "AZ", zip: "85001",
                              latitude: point.latitude, longitude: point.longitude, distanceMiles: 0)
    }

    private func key(for result: NearbyE85SearchResult) -> String {
        CommunityStationKey.canonicalKey(name: result.name, streetAddress: result.address, city: result.city,
                                         state: result.state, zip: result.zip,
                                         latitude: result.latitude, longitude: result.longitude)!
    }

    /// A ready snapshot near Phoenix, fetched an hour ago, with one priced/ethanol-reported station.
    private func seedPhoenixCache(_ cache: NearbyE85Cache, station: NearbyE85SearchResult,
                                  priceReportedAt: Date, ethanolReportedAt: Date) throws -> NearbyE85Snapshot {
        let snapshot = NearbyE85Snapshot.make(
            stations: [NearbyE85Station(id: key(for: station), name: station.name, address: station.address,
                                        latitude: station.latitude, longitude: station.longitude, distanceMiles: 0.5,
                                        price: NearbyE85Price(dollarsPerGallon: 2.79, reportedAt: priceReportedAt, source: .community),
                                        ethanol: NearbyE85Ethanol(percentage: 80, reportedAt: ethanolReportedAt))],
            radiusMiles: 25, updatedAt: now.addingTimeInterval(-3_600), locationAt: now.addingTimeInterval(-3_600),
            userLatitude: phoenix.latitude, userLongitude: phoenix.longitude)
        try cache.write(snapshot, now: now)
        return snapshot
    }

    // MARK: - Tests

    @Test func successPublishesNewSnapshotWithSeparateClocks() async throws {
        let fix = fix(phoenix, age: 5)
        let location = FakeLocation(fix)
        let search = FakeSearch()
        search.results = [result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))]
        let h = harness(location: location, search: search)

        let outcome = await h.coordinator.refresh()

        #expect(outcome == .updated)
        let snapshot = try #require(h.cache.read(now: now))
        #expect(snapshot.state == .ready)
        #expect(snapshot.locationAt == fix.timestamp) // the fix's own time, not the attempt time
        #expect(snapshot.updatedAt == now)             // station-fetch time
        #expect(snapshot.stations.first?.price == nil) // a brand-new station never gets an invented price
        let status = try #require(h.statusStore.read())
        #expect(status.outcome == .updated)
        #expect(status.locationFixAt == fix.timestamp)
        #expect(status.stationsFetchedAt == now)
        #expect(NearbyE85RefreshFeedback.isRefreshing(status: status, now: now) == false)
        #expect(NearbyE85RefreshFeedback.notice(status: status, now: now) == nil)
        // Success makes the app-open fallback redundant.
        #expect(h.requestStore.pendingRequestDate() == nil)
    }

    // MARK: - Proxy catalogue semantics

    @Test func incompleteCoverageWithNothingInRadiusIsNeverNoStations() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        search.error = NLRServiceError.partialCoverage
        let h = harness(location: location, search: search)
        let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        let seeded = try seedPhoenixCache(h.cache, station: station, priceReportedAt: now.addingTimeInterval(-7_200),
                                          ethanolReportedAt: now.addingTimeInterval(-9_000))

        #expect(await h.coordinator.refresh() == .coverageIncomplete)
        #expect(h.cache.read(now: now) == seeded, "no .noStations snapshot replaces the cached stations")
        #expect(NearbyE85RefreshFeedback.notice(status: h.statusStore.read(), now: now) == "Couldn't confirm stations")
        #expect(h.requestStore.pendingRequestDate() == now, "app-open fallback kept")
    }

    @Test func incompleteCoverageWithStationsPublishesThemButStaysIncomplete() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        search.results = [result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))]
        search.coverageComplete = false
        let h = harness(location: location, search: search)

        #expect(await h.coordinator.refresh() == .coverageIncomplete)
        let snapshot = try #require(h.cache.read(now: now))
        #expect(snapshot.state == .ready && snapshot.stations.count == 1, "useful partial stations published")
        #expect(h.statusStore.read()?.outcome == .coverageIncomplete)
        #expect(NearbyE85RefreshFeedback.notice(status: h.statusStore.read(), now: now) == "Couldn't confirm stations")
        #expect(h.requestStore.pendingRequestDate() == now, "app-open fallback stays pending")
    }

    @Test func cachedCatalogueAnswerKeepsItsRealFetchTimeAndReportDates() async throws {
        let fix = fix(phoenix, age: 5)
        let location = FakeLocation(fix)
        let search = FakeSearch()
        let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        search.results = [station]
        search.sourceFetchedAt = now.addingTimeInterval(-600) // proxy cache hit fetched 10 min ago
        let h = harness(location: location, search: search)
        let priceAt = now.addingTimeInterval(-7_200), ethanolAt = now.addingTimeInterval(-9_000)
        _ = try seedPhoenixCache(h.cache, station: station, priceReportedAt: priceAt, ethanolReportedAt: ethanolAt)

        #expect(await h.coordinator.refresh() == .updated)
        let snapshot = try #require(h.cache.read(now: now))
        #expect(snapshot.updatedAt == now, "local search time drives labels/staleness, not catalogue age")
        #expect(snapshot.sourceFetchedAt == now.addingTimeInterval(-600), "catalogue NLR read time kept as provenance")
        #expect(snapshot.locationAt == fix.timestamp, "fix time kept separate")
        #expect(snapshot.isStale(at: now) == false, "a 10-minute-old catalogue answer with a fresh fix is not stale")
        #expect(snapshot.stations.first?.price?.reportedAt == priceAt, "community report never re-dated")
        #expect(snapshot.stations.first?.ethanol?.reportedAt == ethanolAt)
        #expect(h.statusStore.read()?.stationsFetchedAt == now)
    }

    @Test func sixHourOldCatalogueAnswerWithFreshFixIsNotAnOldLocation() async throws {
        let fix = fix(phoenix, age: 5)
        let search = FakeSearch()
        search.results = [result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))]
        search.sourceFetchedAt = now.addingTimeInterval(-6 * 3_600)
        let h = harness(location: FakeLocation(fix), search: search)
        #expect(await h.coordinator.refresh() == .updated)
        let snapshot = try #require(h.cache.read(now: now))
        #expect(snapshot.updatedAt == now && snapshot.locationAt == fix.timestamp)
        #expect(snapshot.isStale(at: now) == false && snapshot.isValid(at: now.addingTimeInterval(23 * 3_600)))
        #expect(snapshot.sourceFetchedAt == now.addingTimeInterval(-6 * 3_600))
    }

    @Test func staleFallbackPublishesStationsButReportsTheRealOutcome() async throws {
        let cases: [(StationCatalogueWarning.Code, NearbyE85RefreshStatus.Outcome, String)] = [
            (.rateLimited, .rateLimited, "Search busy · showing saved"),
            (.upstreamFailed, .networkFailed, "Couldn't reach stations"),
            (.timeout, .timedOut, "Refresh timed out"),
        ]
        for (code, outcome, notice) in cases {
            let search = FakeSearch()
            search.results = [result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))]
            search.sourceFetchedAt = now.addingTimeInterval(-3 * 3_600)
            search.warning = StationCatalogueWarning(code: code, retryAfterSeconds: code == .rateLimited ? 120 : nil)
            let h = harness(location: FakeLocation(fix(phoenix)), search: search)

            #expect(await h.coordinator.refresh() == outcome, "\(code)")
            let snapshot = try #require(h.cache.read(now: now))
            #expect(snapshot.stations.count == 1, "useful stale stations published")
            #expect(snapshot.sourceFetchedAt == now.addingTimeInterval(-3 * 3_600), "original catalogue source time kept")
            #expect(NearbyE85RefreshFeedback.notice(status: h.statusStore.read(), now: now) == notice)
            #expect(h.requestStore.pendingRequestDate() == now, "not a successful refresh: fallback stays pending")
        }
    }

    @Test func completeEmptyStaleFallbackKeepsCachedStationsAndReportsTheFailure() async throws {
        let cases: [(StationCatalogueWarning.Code, NearbyE85RefreshStatus.Outcome)] = [(.rateLimited, .rateLimited), (.upstreamFailed, .networkFailed)]
        for (code, outcome) in cases {
            let search = FakeSearch()
            search.catalogueResult = StationCatalogueSearchResult(
                stations: [], coverageComplete: true, candidateCount: 0, sourceFetchedAt: now.addingTimeInterval(-7_200),
                servedAt: now, cacheState: "stale", warning: StationCatalogueWarning(code: code, retryAfterSeconds: nil))
            let h = harness(location: FakeLocation(fix(phoenix)), search: search)
            let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
            let seeded = try seedPhoenixCache(h.cache, station: station, priceReportedAt: now.addingTimeInterval(-7_200),
                                              ethanolReportedAt: now.addingTimeInterval(-9_000))

            #expect(await h.coordinator.refresh() == outcome, "\(code)")
            #expect(h.cache.read(now: now) == seeded, "useful cached stations are not replaced by an authoritative empty snapshot")
            #expect(h.cache.read(now: now)?.state == .ready)
            #expect(h.requestStore.pendingRequestDate() == now, "failed refresh: app-open fallback stays pending")
        }
    }

    @Test func snapshotValidityChecksOptionalSourceProvenance() throws {
        func snapshot(sourceOffset: TimeInterval?) throws -> NearbyE85Snapshot {
            let base = NearbyE85Snapshot.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now)
            var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
            if let sourceOffset { json["sourceFetchedAt"] = now.addingTimeInterval(sourceOffset).timeIntervalSinceReferenceDate }
            return try JSONDecoder().decode(NearbyE85Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(try snapshot(sourceOffset: nil).isValid(at: now), "legacy: missing provenance is valid")
        #expect(try snapshot(sourceOffset: -600).isValid(at: now), "valid provenance before the search")
        #expect(try snapshot(sourceOffset: 60).isValid(at: now) == false, "provenance after updatedAt is corrupt")
        #expect(try snapshot(sourceOffset: 86_400 * 400).isValid(at: now) == false, "future provenance is corrupt")
    }

    @Test func legacySnapshotWithoutSourceTimeStillDecodes() throws {
        let legacy = NearbyE85Snapshot.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "sourceFetchedAt")
        let decoded = try JSONDecoder().decode(NearbyE85Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.sourceFetchedAt == nil && decoded.updatedAt == legacy.updatedAt)
        let withSource = NearbyE85Snapshot.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now,
                                                sourceFetchedAt: now.addingTimeInterval(-60))
        #expect(try JSONDecoder().decode(NearbyE85Snapshot.self, from: JSONEncoder().encode(withSource)).sourceFetchedAt == now.addingTimeInterval(-60))
        #expect(NearbyE85Snapshot.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now,
                                       sourceFetchedAt: now.addingTimeInterval(60)).sourceFetchedAt == nil, "never newer than the search")
    }

    /// A cached snapshot of the SAME catalogue query (Phoenix cell, 25 mi) whose catalogue source time is -1 h.
    private func seedPhoenixQuery(_ cache: NearbyE85Cache, sourceAge: TimeInterval) throws -> NearbyE85Snapshot {
        let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        let snapshot = NearbyE85Snapshot.make(
            stations: [NearbyE85Station(id: key(for: station), name: station.name, address: station.address,
                                        latitude: station.latitude, longitude: station.longitude, distanceMiles: 0.5)],
            radiusMiles: 25, updatedAt: now.addingTimeInterval(-3_600), locationAt: now.addingTimeInterval(-3_600),
            userLatitude: phoenix.latitude, userLongitude: phoenix.longitude, sourceFetchedAt: now.addingTimeInterval(-sourceAge))
        try cache.write(snapshot, now: now)
        return snapshot
    }

    @Test func olderCatalogueAnswerForTheSameQueryNeverReplacesNewerCachedData() async throws {
        let search = FakeSearch()
        search.results = [result("Other E85", street: "9 Elm St", at: (33.46, -112.06))]
        search.sourceFetchedAt = now.addingTimeInterval(-7_200) // older than the cached query's -3,600 source
        let h = harness(location: FakeLocation(fix(phoenix)), search: search)
        let seeded = try seedPhoenixQuery(h.cache, sourceAge: 3_600)

        #expect(await h.coordinator.refresh() == .superseded)
        #expect(h.cache.read(now: now) == seeded)
    }

    @Test func changedAreaPublishesEvenWithAnOlderCatalogueSourceThanTheCachedArea() async throws {
        // Cached: Phoenix, catalogue source -1 h. Fresh fix in Tucson; Tucson's valid catalogue answer is -2 h old.
        let search = FakeSearch()
        search.results = [result("Tucson E85", street: "5 Speedway", at: (32.23, -110.97))]
        search.sourceFetchedAt = now.addingTimeInterval(-7_200)
        let h = harness(location: FakeLocation(fix(tucson)), search: search)
        _ = try seedPhoenixQuery(h.cache, sourceAge: 3_600)

        #expect(await h.coordinator.refresh() == .updated, "different geography: catalogue ages are not comparable")
        let snapshot = try #require(h.cache.read(now: now))
        #expect(snapshot.stations.first?.name == "Tucson E85")
        #expect(snapshot.sourceFetchedAt == now.addingTimeInterval(-7_200), "source time kept, never re-dated")
        #expect(snapshot.updatedAt == now)
    }

    @Test func changedAreaStillCannotOverwriteWorkWrittenAfterTheAttemptStarted() async throws {
        let search = FakeSearch()
        search.results = [result("Tucson E85", street: "5 Speedway", at: (32.23, -110.97))]
        let h = harness(location: FakeLocation(fix(tucson)), search: search)
        // A newer write lands while this attempt is in flight (e.g. the app published at `now`).
        search.onSearch = { [cache = h.cache, now] in
            let newer = NearbyE85Snapshot.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now,
                                               userLatitude: 33.4484, userLongitude: -112.074)
            try? cache.write(newer, now: now)
        }
        #expect(await h.coordinator.refresh() == .superseded)
        #expect(h.cache.read(now: now)?.stations.isEmpty == true, "the newer write survives")
    }

    @Test func totalTimeoutCancelsLocationAndPreservesCache() async throws {
        let location = FakeLocation(fix(tucson))
        location.hangs = true
        let search = FakeSearch()
        let h = harness(location: location, search: search, immediateDeadlines: true)
        let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        let seeded = try seedPhoenixCache(h.cache, station: station, priceReportedAt: now.addingTimeInterval(-86_400),
                                          ethanolReportedAt: now.addingTimeInterval(-86_400))

        let outcome = await h.coordinator.refresh()

        #expect(outcome == .timedOut)
        #expect(search.calls == 0)
        #expect(location.calls == 0 || location.wasCancelled) // never left running
        #expect(h.cache.read(now: now) == seeded)
        #expect(NearbyE85RefreshFeedback.notice(status: h.statusStore.read(), now: now) == "Refresh timed out")
    }

    @Test func widgetLocationNotAuthorizedNeverRequestsLocationOrNetwork() async throws {
        let location = FakeLocation(fix(phoenix))
        location.authorized = false
        let search = FakeSearch()
        let h = harness(location: location, search: search)
        let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        let seeded = try seedPhoenixCache(h.cache, station: station, priceReportedAt: now, ethanolReportedAt: now)

        let outcome = await h.coordinator.refresh()

        #expect(outcome == .widgetLocationNotAuthorized)
        #expect(location.calls == 0)
        #expect(search.calls == 0)
        #expect(h.cache.read(now: now) == seeded)
        #expect(NearbyE85RefreshFeedback.notice(status: h.statusStore.read(), now: now) == "Widget location off")
    }

    @Test func offlineKeepsCachedStationsAndReportsFixTime() async throws {
        let fix = fix(phoenix)
        let location = FakeLocation(fix)
        let search = FakeSearch()
        search.error = URLError(.notConnectedToInternet)
        let h = harness(location: location, search: search)
        let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        let seeded = try seedPhoenixCache(h.cache, station: station, priceReportedAt: now, ethanolReportedAt: now)

        let outcome = await h.coordinator.refresh()

        #expect(outcome == .offline)
        #expect(h.cache.read(now: now) == seeded)
        let status = try #require(h.statusStore.read())
        #expect(status.locationFixAt == fix.timestamp)
        #expect(status.stationsFetchedAt == nil)
        #expect(NearbyE85RefreshFeedback.notice(status: status, now: now) == "Offline · showing saved")
        // Failure keeps the app-open fallback request so opening the app still retries.
        #expect(h.requestStore.pendingRequestDate() == now)
    }

    @Test func staleCachedFixIsRejectedWithoutSearching() async throws {
        let location = FakeLocation(fix(phoenix, age: 10 * 60))
        let search = FakeSearch()
        let h = harness(location: location, search: search)

        #expect(await h.coordinator.refresh() == .locationUnavailable)
        #expect(search.calls == 0)
    }

    @Test func changedAreaDiscoversNewlyCloserStationAndClearsOutOfArea() async throws {
        let location = FakeLocation(fix(tucson))
        let search = FakeSearch()
        let tucsonStation = result("Tucson E85", street: "9 Speedway", at: (32.23, -110.97))
        search.results = [tucsonStation]
        let h = harness(location: location, search: search)
        _ = try seedPhoenixCache(h.cache, station: result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07)),
                                 priceReportedAt: now, ethanolReportedAt: now)
        _ = h.areaStore.markOutOfArea(at: now)

        #expect(await h.coordinator.refresh() == .updated)

        let snapshot = try #require(h.cache.read(now: now))
        #expect(snapshot.stations.map(\.id) == [key(for: tucsonStation)])
        #expect(snapshot.stations[0].distanceMiles < 2)
        #expect(snapshot.userLatitude == tucson.latitude)
        #expect(h.areaStore.read().isOutOfArea == false)
    }

    @Test func matchingStationKeepsOriginalReportDatesAndNewStationGetsNone() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        let existing = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        let newcomer = result("New E85", street: "2 Oak Ave", at: (33.452, -112.072))
        search.results = [existing, newcomer]
        let h = harness(location: location, search: search)
        let priceAt = now.addingTimeInterval(-2 * 86_400)
        let ethanolAt = now.addingTimeInterval(-3 * 86_400)
        _ = try seedPhoenixCache(h.cache, station: existing, priceReportedAt: priceAt, ethanolReportedAt: ethanolAt)

        #expect(await h.coordinator.refresh() == .updated)

        let snapshot = try #require(h.cache.read(now: now))
        let kept = try #require(snapshot.stations.first { $0.id == key(for: existing) })
        #expect(kept.price?.reportedAt == priceAt)
        #expect(kept.price?.dollarsPerGallon == 2.79)
        #expect(kept.ethanol?.reportedAt == ethanolAt)
        let added = try #require(snapshot.stations.first { $0.id == key(for: newcomer) })
        #expect(added.price == nil)
        #expect(added.ethanol == nil)
    }

    @Test func repeatedTapsShareOneInFlightAttempt() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        search.results = [result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))]
        search.gated = true
        let h = harness(location: location, search: search)

        async let first = h.coordinator.refresh()
        async let second = h.coordinator.refresh()
        while search.gate == nil { await Task.yield() }
        #expect(NearbyE85RefreshFeedback.isRefreshing(status: h.statusStore.read(), now: now))
        search.gate?.resume()
        let outcomes = await [first, second]

        #expect(outcomes == [.updated, .updated])
        #expect(location.calls == 1)
        #expect(search.calls == 1)
        #expect(h.requestStore.pendingRequestDate() == nil)
    }

    @Test func supersededGenerationNeverPublishesOrOverwritesNewerStatus() async throws {
        let location = FakeLocation(fix(tucson))
        let search = FakeSearch()
        search.results = [result("Tucson E85", street: "9 Speedway", at: (32.23, -110.97))]
        let h = harness(location: location, search: search)
        let seeded = try seedPhoenixCache(h.cache, station: result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07)),
                                          priceReportedAt: now, ethanolReportedAt: now)
        // Another process starts a newer attempt while this one's search is in flight.
        var newer: NearbyE85RefreshStatus?
        search.onSearch = { newer = h.statusStore.begin(at: self.now) }

        #expect(await h.coordinator.refresh() == .superseded)

        #expect(h.cache.read(now: now) == seeded)
        #expect(h.statusStore.read() == newer)
        #expect(h.statusStore.read()?.outcome == .inProgress)
    }

    @Test func appSnapshotWrittenDuringSearchAtSameLocationIsNeverClobbered() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        search.results = [station]
        let h = harness(location: location, search: search)
        _ = try seedPhoenixCache(h.cache, station: station, priceReportedAt: now, ethanolReportedAt: now)
        // The app publishes a richer snapshot (same place, older fix, new saved price) while the
        // widget's search is in flight.
        let appSnapshot = NearbyE85Snapshot.make(
            stations: [NearbyE85Station(id: key(for: station), name: station.name, address: station.address,
                                        latitude: station.latitude, longitude: station.longitude, distanceMiles: 0.4,
                                        price: NearbyE85Price(dollarsPerGallon: 2.59, reportedAt: now, source: .saved))],
            radiusMiles: 25, updatedAt: now, locationAt: now.addingTimeInterval(-60),
            userLatitude: phoenix.latitude, userLongitude: phoenix.longitude)
        search.onSearch = { _ = try? h.cache.write(appSnapshot, now: self.now) }

        #expect(await h.coordinator.refresh() == .superseded)
        #expect(h.cache.read(now: now) == appSnapshot)
        #expect(h.requestStore.pendingRequestDate() == now)
    }

    @Test func publishMergesFromLatestCacheNotThePreNetworkRead() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        search.results = [station]
        let h = harness(location: location, search: search)
        _ = try seedPhoenixCache(h.cache, station: station, priceReportedAt: now.addingTimeInterval(-86_400),
                                 ethanolReportedAt: now.addingTimeInterval(-86_400))
        // An older-attempt write lands mid-search: older than this attempt, older fix, but a
        // different (earlier-reported) price. The publish must merge from THIS latest snapshot.
        let laterPriceAt = now.addingTimeInterval(-2 * 3_600)
        let midSearch = NearbyE85Snapshot.make(
            stations: [NearbyE85Station(id: key(for: station), name: station.name, address: station.address,
                                        latitude: station.latitude, longitude: station.longitude, distanceMiles: 0.4,
                                        price: NearbyE85Price(dollarsPerGallon: 2.49, reportedAt: laterPriceAt, source: .community))],
            radiusMiles: 25, updatedAt: now.addingTimeInterval(-1_800), locationAt: now.addingTimeInterval(-1_800),
            userLatitude: phoenix.latitude, userLongitude: phoenix.longitude)
        search.onSearch = { _ = try? h.cache.write(midSearch, now: self.now) }

        #expect(await h.coordinator.refresh() == .updated)
        let published = try #require(h.cache.read(now: now)?.stations.first)
        #expect(published.price?.dollarsPerGallon == 2.49)
        #expect(published.price?.reportedAt == laterPriceAt)
        #expect(published.ethanol == nil) // the latest snapshot carried none; never resurrected
    }

    @Test func cancellingOneWaiterDoesNotCancelWorkAnotherStillAwaits() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        search.results = [result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))]
        search.gated = true
        let h = harness(location: location, search: search)

        let first = Task { await h.coordinator.refresh() }
        while search.gate == nil { await Task.yield() }
        let second = Task { await h.coordinator.refresh() }
        for _ in 0..<20 { await Task.yield() }
        first.cancel()
        for _ in 0..<20 { await Task.yield() }
        search.gate?.resume()

        #expect(await second.value == .updated)
        #expect(await first.value == .updated)
        #expect(search.calls == 1)
    }

    @Test func cancellingEveryWaiterCancelsTheAttemptAndPreservesCache() async throws {
        let location = FakeLocation(fix(phoenix))
        location.hangs = true
        let search = FakeSearch()
        let h = harness(location: location, search: search)
        let seeded = try seedPhoenixCache(h.cache, station: result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07)),
                                          priceReportedAt: now, ethanolReportedAt: now)

        let task = Task { await h.coordinator.refresh() }
        while location.calls == 0 { await Task.yield() }
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(location.wasCancelled)
        #expect(search.calls == 0)
        #expect(h.cache.read(now: now) == seeded)
        #expect(h.requestStore.pendingRequestDate() == now)
    }

    @Test func fixerCancelledBeforeStartNeverStartsCoreLocation() async {
        let fixer = NearbyE85CoreLocationFixer()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixer.requestFix()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func staleAttemptCompletionIsRejectedExplicitly() {
        let store = NearbyE85RefreshStatusStore(fileURL: tempStatusURL())
        var older = store.begin(at: now)
        let newer = store.begin(at: now)
        #expect(older.attemptID != newer.attemptID)
        older.outcome = .updated
        older.finishedAt = now
        #expect(store.finish(older) == false)
        #expect(store.read() == newer)
    }

    @Test func refreshFeedbackIsVisibleAndAnnouncedInEveryFamily() {
        let snapshot = NearbyE85Snapshot.make(
            stations: [NearbyE85Station(id: "a", name: "Phoenix E85", address: "1 Main St", latitude: 33.45, longitude: -112.07,
                                        distanceMiles: 0.5, price: NearbyE85Price(dollarsPerGallon: 2.79, reportedAt: now.addingTimeInterval(-5 * 86_400), source: .community))],
            radiusMiles: 25, updatedAt: now.addingTimeInterval(-120), locationAt: now.addingTimeInterval(-600),
            userLatitude: phoenix.latitude, userLongitude: phoenix.longitude)
        for family in [WidgetFamily.systemSmall, .systemMedium, .systemLarge] {
            let entry = NearbyE85Entry(date: now, snapshot: snapshot, access: .pro, refreshNotice: "Offline · showing saved")
            let suffix = NearbyE85WidgetView(entry: entry, family: family).statusAccessibilitySuffix
            #expect(suffix.contains("Offline · showing saved"))
            #expect(suffix.contains("Location from 10 minutes ago"))
            #expect(suffix.contains("Stations searched 2 minutes ago"))
            #expect(!suffix.contains("5 days")) // the price's own report age is never relabeled
            let fallback = NearbyE85Entry(date: now, snapshot: nil, access: .pro, refreshNotice: "Widget location off")
            #expect(NearbyE85WidgetView(entry: fallback, family: family).fallbackAccessibilityLabel.hasSuffix("Widget location off."))
        }
    }

    // MARK: - Coordinated cache writes (shared by the app publisher and the widget)

    private func radiusSnapshot(_ radius: Double) -> NearbyE85Snapshot {
        .make(stations: [], radiusMiles: radius, updatedAt: now, locationAt: now,
              userLatitude: phoenix.latitude, userLongitude: phoenix.longitude)
    }

    @Test func conditionalWriteEvaluatesPreconditionAgainstLatestBytesAndRejectsCleanly() throws {
        let cache = NearbyE85Cache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbyE85WidgetRefreshTests-\(UUID().uuidString)/snapshot.json"))
        // An "app" write lands first; the "widget" decision must see exactly those bytes.
        try cache.write(radiusSnapshot(10), now: now)
        var seen: NearbyE85Snapshot?
        let rejected = try cache.update(now: now) { latest in seen = latest; return nil }
        #expect(rejected == .rejected)
        #expect(seen == radiusSnapshot(10))
        #expect(cache.read(now: now) == radiusSnapshot(10))
        #expect(try cache.update(now: now) { _ in self.radiusSnapshot(10) } == .unchanged)
        #expect(try cache.update(now: now) { _ in self.radiusSnapshot(11) } == .written)
    }

    // nonisolated: the 30 blocking coordinated writes run on background threads and must never
    // hold the main actor that the rest of the test target shares.
    @Test nonisolated func concurrentCompareAndWritesNeverLoseAnUpdate() throws {
        let now = Date()
        let phoenix = (latitude: 33.4484, longitude: -112.0740)
        let radiusSnapshot = { (radius: Double) in
            NearbyE85Snapshot.make(stations: [], radiusMiles: radius, updatedAt: now, locationAt: now,
                                   userLatitude: phoenix.latitude, userLongitude: phoenix.longitude)
        }
        let cache = NearbyE85Cache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbyE85WidgetRefreshTests-\(UUID().uuidString)/snapshot.json"))
        try cache.write(radiusSnapshot(1), now: now)
        let base = radiusSnapshot(1)
        let fixedNow = now
        // 30 writers each read-modify-write (+1 radius). Without coordination spanning the read
        // and the replace, increments would be lost.
        DispatchQueue.concurrentPerform(iterations: 30) { _ in
            _ = try? cache.update(now: fixedNow) { latest in
                let radius = (latest?.radiusMiles ?? 0) + 1
                return .make(stations: [], radiusMiles: radius, updatedAt: base.updatedAt, locationAt: fixedNow,
                             userLatitude: base.userLatitude, userLongitude: base.userLongitude)
            }
        }
        #expect(cache.read(now: now)?.radiusMiles == 31)
    }

    @Test func spinnerIsCompletionBasedAndSelfSettles() {
        let started = NearbyE85RefreshStatus(attemptID: UUID(), attemptStartedAt: now, outcome: .inProgress)
        #expect(NearbyE85RefreshFeedback.isRefreshing(status: started, now: now.addingTimeInterval(15)))
        #expect(NearbyE85RefreshFeedback.isRefreshing(status: started, now: now.addingTimeInterval(NearbyE85RefreshFeedback.maxInFlight)) == false)
        var done = started
        done.outcome = .updated
        done.finishedAt = now.addingTimeInterval(1)
        #expect(NearbyE85RefreshFeedback.isRefreshing(status: done, now: now.addingTimeInterval(2)) == false)
    }
    // MARK: - Automatic refresh (timeline-driven)

    private var inArea: NearbyE85AreaRelevanceState { NearbyE85AreaRelevanceState(isOutOfArea: false, determinedAt: now) }

    private func freshSnapshot(age: TimeInterval = 60) -> NearbyE85Snapshot {
        let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        return .make(stations: [NearbyE85Station(id: key(for: station), name: station.name, address: station.address,
                                                 latitude: station.latitude, longitude: station.longitude, distanceMiles: 0.5)],
                     radiusMiles: 25, updatedAt: now.addingTimeInterval(-age), locationAt: now.addingTimeInterval(-age),
                     userLatitude: phoenix.latitude, userLongitude: phoenix.longitude)
    }

    @Test func automaticPolicyRunsOnlyWhenDue() {
        func due(_ access: NearbyE85WidgetAccessStatus = .pro, authorized: Bool = true, snapshot: NearbyE85Snapshot?,
                 area: NearbyE85AreaRelevanceState? = nil, last: Date? = nil, status: NearbyE85RefreshStatus? = nil) -> Bool {
            NearbyE85AutomaticRefresh.isDue(access: access, locationAuthorized: authorized, snapshot: snapshot,
                                            areaRelevance: area ?? inArea, lastAutomaticAttemptAt: last, status: status, now: now)
        }
        // Fresh cache skips; missing / stale / out-of-area runs.
        #expect(due(snapshot: freshSnapshot()) == false)
        #expect(due(snapshot: nil))
        #expect(due(snapshot: freshSnapshot(age: NearbyE85Snapshot.staleAfter + 1)))
        #expect(due(snapshot: freshSnapshot(), area: NearbyE85AreaRelevanceState(isOutOfArea: true, determinedAt: now.addingTimeInterval(-10))))
        // Free / unknown / widget-location-off never run.
        #expect(due(.free, snapshot: nil) == false)
        #expect(due(.unknown, snapshot: nil) == false)
        #expect(due(authorized: false, snapshot: nil) == false)
        // Throttled by a recent automatic attempt OR a recent manual attempt; due again after the interval.
        #expect(due(snapshot: nil, last: now.addingTimeInterval(-60)) == false)
        let manual = NearbyE85RefreshStatus(attemptID: UUID(), attemptStartedAt: now.addingTimeInterval(-60), outcome: .networkFailed,
                                            finishedAt: now.addingTimeInterval(-50))
        #expect(due(snapshot: nil, status: manual) == false)
        #expect(due(snapshot: nil, last: now.addingTimeInterval(-NearbyE85AutomaticRefresh.minInterval - 1)))
        // An in-flight attempt is never duplicated.
        let running = NearbyE85RefreshStatus(attemptID: UUID(), attemptStartedAt: now.addingTimeInterval(-5), outcome: .inProgress)
        #expect(due(snapshot: nil, status: running) == false)
    }

    private func autoRun(_ h: Harness, attemptStore: NearbyE85AutomaticRefreshStore, access: NearbyE85WidgetAccessStatus = .pro,
                         refresh: (() async -> NearbyE85RefreshStatus.Outcome)? = nil) async -> Bool {
        await NearbyE85AutomaticRefresh.runIfDue(access: access, now: now, locationAuthorized: { true }, cache: h.cache,
                                                 statusStore: h.statusStore, areaRelevanceStore: h.areaStore,
                                                 attemptStore: attemptStore,
                                                 refresh: refresh ?? { await h.coordinator.refresh() })
    }

    private func attemptStore() -> NearbyE85AutomaticRefreshStore {
        NearbyE85AutomaticRefreshStore(defaults: UserDefaults(suiteName: "NearbyE85WidgetRefreshTests-auto-\(UUID().uuidString)")!)
    }

    @Test func automaticMissingCacheRunsOnceAwaitedThenThrottles() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        search.results = [result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))]
        let h = harness(location: location, search: search)
        h.requestStore.clear()
        let attempts = attemptStore()

        #expect(await autoRun(h, attemptStore: attempts))
        // Awaited: the published cache and final status are visible as soon as runIfDue returns.
        #expect(h.cache.read(now: now)?.state == .ready)
        #expect(h.statusStore.read()?.outcome == .updated)
        #expect(attempts.lastAttemptDate() == now)
        #expect(search.calls == 1 && location.calls == 1)
        // Never marks the manual app-open fallback.
        #expect(h.requestStore.pendingRequestDate() == nil)

        // Second invocation: fresh cache and recent attempt — no location/network work.
        #expect(await autoRun(h, attemptStore: attempts) == false)
        #expect(search.calls == 1 && location.calls == 1)
    }

    @Test func automaticFreshCacheAndNonProDoNoWork() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        let h = harness(location: location, search: search)
        try h.cache.write(freshSnapshot(), now: now)
        let attempts = attemptStore()
        #expect(await autoRun(h, attemptStore: attempts) == false)

        let empty = harness(location: location, search: search)
        for access in [NearbyE85WidgetAccessStatus.free, .unknown] {
            var refreshed = false
            #expect(await autoRun(empty, attemptStore: attempts, access: access, refresh: { refreshed = true; return .updated }) == false)
            #expect(refreshed == false)
        }
        #expect(location.calls == 0 && search.calls == 0)
        #expect(attempts.lastAttemptDate() == nil)
        #expect(empty.statusStore.read() == nil)
    }

    @Test func automaticFailurePreservesCacheAndReportsOutcome() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        search.error = URLError(.notConnectedToInternet)
        let h = harness(location: location, search: search)
        let station = result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))
        let seeded = try seedPhoenixCache(h.cache, station: station, priceReportedAt: now.addingTimeInterval(-7_200),
                                          ethanolReportedAt: now.addingTimeInterval(-9_000))
        let attempts = attemptStore()

        #expect(await autoRun(h, attemptStore: attempts))
        #expect(h.cache.read(now: now) == seeded)
        #expect(h.statusStore.read()?.outcome == .offline)
        #expect(NearbyE85RefreshFeedback.notice(status: h.statusStore.read(), now: now) == "Offline · showing saved")
        // The manual fallback flag seeded by the harness is untouched by an automatic failure.
        #expect(h.requestStore.pendingRequestDate() == now)
        // Throttled after the failure too.
        #expect(await autoRun(h, attemptStore: attempts) == false)
        #expect(search.calls == 1)
    }

    @Test func automaticNeverDuplicatesInFlightManualRefresh() async throws {
        let location = FakeLocation(fix(phoenix))
        let search = FakeSearch()
        search.results = [result("Phoenix E85", street: "1 Main St", at: (33.45, -112.07))]
        search.gated = true
        let h = harness(location: location, search: search)
        let manual = Task { await h.coordinator.refresh() }
        while search.gate == nil { await Task.yield() }
        // The policy sees the in-flight attempt and starts no duplicate location/network work.
        #expect(await autoRun(h, attemptStore: attemptStore()) == false)
        search.gate?.resume()
        #expect(await manual.value == .updated)
        #expect(search.calls == 1 && location.calls == 1)
    }

    @Test func timelineAwaitsAutomaticRefreshBeforeLoadingInputsAndOnlyForPro() async {
        var order: [String] = []
        let inputs = NearbyE85Provider.ProInputs(snapshot: nil, zoomLevel: .default, mapRender: nil, pendingRefreshAt: nil,
                                                 areaRelevance: inArea)
        _ = await NearbyE85Provider.timeline(access: .pro, now: now, refreshIfDue: { order.append("refresh") }) {
            order.append("load"); return inputs
        }
        #expect(order == ["refresh", "load"])
        for access in [NearbyE85WidgetAccessStatus.free, .unknown] {
            order = []
            _ = await NearbyE85Provider.timeline(access: access, now: now, refreshIfDue: { order.append("refresh") }) {
                order.append("load"); return inputs
            }
            #expect(order.isEmpty)
        }
    }
    // MARK: - Review regressions

    /// Never the real App Group: a per-test status file (its lock file sits beside it).
    private func tempStatusURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbyE85WidgetRefreshTests-\(UUID().uuidString)/refresh-status.json")
    }

    @Test func timelinePresentsWithTimeCapturedAfterAutomaticRefresh() async {
        // The automatic attempt fails 5 s after getTimeline began; the clock reads 6 s on return.
        let failedAt = now.addingTimeInterval(5)
        let afterRefresh = now.addingTimeInterval(6)
        let failed = NearbyE85RefreshStatus(attemptID: UUID(), attemptStartedAt: now, outcome: .offline, finishedAt: failedAt)
        let inputs = NearbyE85Provider.ProInputs(snapshot: nil, zoomLevel: .default, mapRender: nil, pendingRefreshAt: nil,
                                                 areaRelevance: inArea, refreshStatus: failed)
        let timeline = await NearbyE85Provider.timeline(access: .pro, now: now, refreshIfDue: {},
                                                        currentDate: { afterRefresh }) { inputs }
        let first = timeline.entries.first
        #expect(first?.date == afterRefresh)
        #expect(first?.refreshNotice == "Offline · showing saved")
        #expect(timeline.entries.contains { $0.date == failedAt.addingTimeInterval(NearbyE85RefreshFeedback.noticeLifetime) })
        #expect(timeline.entries.allSatisfy { $0.date >= afterRefresh })
        // A clock that reads earlier than the request never moves the timeline backwards.
        let skewed = await NearbyE85Provider.timeline(access: .pro, now: now, currentDate: { now.addingTimeInterval(-60) }) { inputs }
        #expect(skewed.entries.first?.date == now)
    }

    /// Controlled cross-process interleaving: A has validated its identity inside `finish` when
    /// "process" B (an independent store instance on another thread, sharing only the status
    /// file and its lock file) calls `begin`. B must not be able to install its generation until
    /// A's write is done, so A's completion can never overwrite B's newer in-progress status.
    @Test nonisolated func olderFinishCannotOverwriteNewerBeginAcrossProcesses() async {
        let statusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbyE85WidgetRefreshTests-\(UUID().uuidString)/refresh-status.json")
        let start = Date()
        let bID = UUID()
        // The test only ever awaits B — it never blocks the test thread waiting on another thread.
        let bDone = DispatchGroup()
        bDone.enter()
        let processB = NearbyE85RefreshStatusStore(fileURL: statusURL)
        let processA = NearbyE85RefreshStatusStore(fileURL: statusURL, beforeFinishWrite: {
            let bStarted = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                bStarted.signal()
                _ = processB.begin(at: start.addingTimeInterval(1), attemptID: bID)
                bDone.leave()
            }
            bStarted.wait()
            // Give B every chance to write mid-finish; with the lock it must block instead.
            Thread.sleep(forTimeInterval: 0.2)
        })
        var a = processA.begin(at: start)
        // A's begin is visible to the independent instance B through the file.
        #expect(processB.read()?.attemptID == a.attemptID)
        a.outcome = .updated
        a.finishedAt = start.addingTimeInterval(2)

        #expect(processA.finish(a))
        await withCheckedContinuation { continuation in bDone.notify(queue: .global()) { continuation.resume() } }
        let final = processB.read()
        #expect(final?.attemptID == bID)
        #expect(final?.outcome == .inProgress)
        #expect(processB.isCurrent(bID))
        // B's own later completion is therefore still recorded, not dropped.
        var b = final!
        b.outcome = .offline
        b.finishedAt = start.addingTimeInterval(3)
        #expect(processB.finish(b))
        #expect(processA.finish(a) == false)
        // B's completed write is what A — and a brand-new instance — read back.
        #expect(processA.read() == b)
        #expect(NearbyE85RefreshStatusStore(fileURL: statusURL).read() == b)
    }

    /// Lock unavailable (a directory squats on the lock path, so `open` fails): no mutation
    /// happens unlocked — begin writes nothing, finish is rejected — while the last status
    /// written under the lock stays readable.
    @Test func statusMutationFailsClosedWhenLockUnavailable() throws {
        let statusURL = tempStatusURL()
        let store = NearbyE85RefreshStatusStore(fileURL: statusURL)
        let existing = store.begin(at: now)
        #expect(store.read() == existing)

        let lockURL = statusURL.appendingPathExtension("lock")
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)

        var finished = existing
        finished.outcome = .updated
        finished.finishedAt = now
        #expect(store.finish(finished) == false)
        let newer = store.begin(at: now.addingTimeInterval(1))
        #expect(newer.attemptID != existing.attemptID)
        #expect(store.isCurrent(newer.attemptID) == false)
        #expect(store.read() == existing)
    }

    /// No App Group container: nothing is read or written, and a finish is never "recorded".
    @Test func unavailableStatusFileFailsClosed() {
        let store = NearbyE85RefreshStatusStore(fileURL: nil)
        var status = store.begin(at: now)
        #expect(store.read() == nil)
        status.outcome = .updated
        #expect(store.finish(status) == false)
    }
}
