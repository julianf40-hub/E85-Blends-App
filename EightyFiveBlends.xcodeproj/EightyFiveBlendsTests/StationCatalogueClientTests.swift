//
//  StationCatalogueClientTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.1 — the shared station-catalogue proxy client (NRELStationService.swift): coarse-cell
//  parity with the TypeScript proxy, request shape, candidates-before-filter/sort/limit, incomplete
//  coverage, timestamp separation, and Trip Planner corridor coverage. Every request goes to a stub
//  URLProtocol keyed by a per-test host — no live network, no real key.
//

import CoreLocation
import Foundation
import Testing
@testable import EightyFiveBlends

/// Routes each request to the handler registered for its (per-test, unique) host.
nonisolated final class StationCatalogueStubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, Data)
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func register(host: String, _ handler: @escaping Handler) {
        lock.lock(); handlers[host] = handler; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        let handler = request.url?.host.flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        // Foundation may hand the body over either way; read httpBody first, then the stream.
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        let (status, data) = handler(request, body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

struct StationCatalogueClientTests {
    // MARK: Helpers

    private static let publishable = "sb_publishable_test_fixture_only"

    private func stubbedService(_ handler: @escaping StationCatalogueStubURLProtocol.Handler) -> NLRStationService {
        let host = "t\(UUID().uuidString.lowercased()).example.test"
        StationCatalogueStubURLProtocol.register(host: host, handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StationCatalogueStubURLProtocol.self]
        let config = StationCatalogueConfig.make(url: "https://\(host)/rest/v1/", publishableKey: Self.publishable)
        return NLRStationService(session: URLSession(configuration: configuration), configuration: { config })
    }

    nonisolated private static func requestFields(_ body: Data) -> [String: Int] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Int] ?? [:]
    }

    nonisolated private static func station(_ id: Int, _ lat: Double, _ lon: Double, name: String? = nil) -> [String: Any] {
        ["id": id, "station_name": name ?? "Station \(id)", "street_address": "\(id) Main St", "city": "Phoenix",
         "state": "AZ", "zip": "85001", "latitude": lat, "longitude": lon]
    }

    /// A v2 payload echoing the request's own cell/bucket.
    nonisolated private static func payload(for body: Data, stations: [[String: Any]], complete: Bool, total: Int? = nil,
                                returnedCount: Int? = nil, dropped: Int = 0, coverage: String? = nil,
                                cache: String = "hit", warning: Any? = nil,
                                source: String = "2026-10-30T10:00:00.000Z", served: String = "2026-10-30T12:00:00.000Z") -> Data {
        let f = requestFields(body)
        var object: [String: Any] = [
            "v": 2, "lat_cell": f["lat_cell"] ?? -1, "lon_cell": f["lon_cell"] ?? -1, "radius_miles": f["radius_miles"] ?? -1,
            "complete": complete, "coverage": coverage ?? (complete ? "complete" : "partial"), "total": total ?? stations.count,
            "returned_count": returnedCount ?? stations.count, "dropped": dropped, "cache": cache,
            "source_fetched_at": source, "served_at": served, "fuel_stations": stations,
        ]
        if let warning { object["warning"] = warning }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Cell parity (identical vectors to supabase/functions/station-catalogue-v1/cells_test.ts)

    @Test func cellParityVectorsMatchTypeScript() {
        let vectors: [(Double, Double, Int, Int)] = [
            (0, 0, 1800, 3600), (33.4484, -112.074, 2468, 1358), (-33.8688, 151.2093, 1122, 6624),
            (90, 0, 3599, 3600), (-90, 0, 0, 3600), (89.99, 179.99, 3599, 7199), (-89.99, -179.99, 0, 0),
            (45, 180, 2700, 0), (45, -180, 2700, 0), (-45, 179.999999, 900, 7199), (80, -0.000001, 3400, 3599),
            (0.05, 0.05, 1801, 3601), (0.0499995, 0.0499995, 1801, 3601), (0.0499994, 0.0499994, 1800, 3600),
            (-0.0000005, -0.0000005, 1800, 3600), (-0.0000006, -0.0000006, 1799, 3599),
            (44.95, -93.1, 2699, 1738), (-44.95, 93.1, 901, 5462),
        ]
        for (lat, lon, latCell, lonCell) in vectors {
            #expect(StationCatalogueCells.cell(latitude: lat, longitude: lon) == .init(latCell: latCell, lonCell: lonCell),
                    "cell(\(lat), \(lon))")
        }
    }

    @Test func microdegreeRoundingEpsilonAndNormalization() {
        #expect(StationCatalogueCells.toE6(0.0000005) == 1 && StationCatalogueCells.toE6(0.0000004) == 0)
        #expect(StationCatalogueCells.toE6(-0.0000005) == 0 && StationCatalogueCells.toE6(-0.0000006) == -1)
        for i in stride(from: -1800, through: 1800, by: 7) {
            #expect(StationCatalogueCells.toE6(Double(i) * 0.05) == i * 50_000, "edge \(i)")
        }
        #expect(StationCatalogueCells.normalizeLongitudeE6(180_000_000) == -180_000_000)
        #expect(StationCatalogueCells.normalizeLongitudeE6(540_000_000) == -180_000_000)
        #expect(StationCatalogueCells.normalizeLongitudeE6(-190_000_000) == 170_000_000)
        #expect(StationCatalogueCells.cell(latitude: .nan, longitude: 0) == nil)
        #expect(StationCatalogueCells.cell(latitude: 90.000001, longitude: 0) == nil)
    }

    @Test func radiusBucketsCoverAndNeverShrink() {
        #expect(StationCatalogueCells.bucket(forRadiusMiles: 10) == 10)
        #expect(StationCatalogueCells.bucket(forRadiusMiles: 20) == 25)
        #expect(StationCatalogueCells.bucket(forRadiusMiles: 45) == 50)
        #expect(StationCatalogueCells.bucket(forRadiusMiles: 100) == 100)
        #expect(StationCatalogueCells.bucket(forRadiusMiles: 200) == 200)
        #expect(StationCatalogueCells.bucket(forRadiusMiles: 200.5) == nil)
        #expect(StationCatalogueCells.bucket(forRadiusMiles: 0) == nil)
    }

    // MARK: Configuration and request

    @Test func configUsesOnlyPublicIdentificationAndNormalizesRestV1() throws {
        let config = try #require(StationCatalogueConfig.make(url: "https://abc.supabase.co/rest/v1/", publishableKey: Self.publishable))
        #expect(config.endpoint.absoluteString == "https://abc.supabase.co/functions/v1/station-catalogue-v1")
        #expect(StationCatalogueConfig.make(url: "http://abc.supabase.co", publishableKey: Self.publishable) == nil)
        #expect(StationCatalogueConfig.make(url: "https://abc.supabase.co", publishableKey: "sb_secret_fixture") == nil)
        #expect(StationCatalogueConfig.make(url: "https://abc.supabase.co", publishableKey: "eyJfixture") == nil)
        #expect(StationCatalogueConfig.make(url: nil, publishableKey: Self.publishable) == nil)
    }

    @Test func requestIsStrictCoarseCellPost() throws {
        let config = try #require(StationCatalogueConfig.make(url: "https://abc.supabase.co", publishableKey: Self.publishable))
        let request = NLRStationService.makeRequest(config: config, cell: .init(latCell: 2468, lonCell: 1358), bucket: 25)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "apikey") == Self.publishable)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(decoding: try #require(request.httpBody), as: UTF8.self) == #"{"v":2,"lat_cell":2468,"lon_cell":1358,"radius_miles":25}"#)
        #expect(request.url?.host?.contains("nlr.gov") == false)
    }

    // MARK: Decoding

    @Test func allCandidatesAreFilteredSortedThenLimitedOnDevice() throws {
        let user = (lat: 33.4484, lon: -112.074)
        let cell = try #require(StationCatalogueCells.cell(latitude: user.lat, longitude: user.lon))
        let body = Data(#"{"lat_cell":\#(cell.latCell),"lon_cell":\#(cell.lonCell),"radius_miles":10}"#.utf8)
        // Server order is NOT nearest-first and includes out-of-radius padding candidates.
        let stations = [Self.station(1, 33.60, -112.074), Self.station(2, 33.46, -112.074), Self.station(3, 33.4484, -112.08),
                        Self.station(4, 33.50, -112.074)]
        let result = try NLRStationService.decode(Self.payload(for: body, stations: stations, complete: true), cell: cell, bucket: 10,
                                                  latitude: user.lat, longitude: user.lon, radiusMiles: 10, limit: 2)
        #expect(result.candidateCount == 4)
        #expect(result.stations.map(\.nlrID) == [3, 2], "nearest in-radius first; 4 is in radius but beyond the limit; 1 is out of radius")
        #expect(result.stations.allSatisfy { $0.distanceMiles <= 10 })
        #expect(result.coverageComplete)
    }

    @Test func incompleteZeroIsUnknownNotNoStations() throws {
        let cell = StationCatalogueCells.Cell(latCell: 2468, lonCell: 1358)
        let body = Data(#"{"lat_cell":2468,"lon_cell":1358,"radius_miles":25}"#.utf8)
        let far = [Self.station(1, 34.5, -112.074)]
        let partial = try NLRStationService.decode(Self.payload(for: body, stations: far, complete: false, total: 400), cell: cell, bucket: 25,
                                                   latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        #expect(partial.stations.isEmpty && !partial.coverageComplete)
        #expect(throws: NLRServiceError.partialCoverage) { try NearbyE85ProxyStationSearch.response(from: partial) }
        let complete = try NLRStationService.decode(Self.payload(for: body, stations: [], complete: true), cell: cell, bucket: 25,
                                                    latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        #expect(try NearbyE85ProxyStationSearch.response(from: complete).results.isEmpty, "complete + empty is a real no-stations answer")
        let near = [Self.station(2, 33.45, -112.074)]
        let partialNonEmpty = try NLRStationService.decode(Self.payload(for: body, stations: near, complete: false, total: 400), cell: cell,
                                                           bucket: 25, latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        let mapped = try NearbyE85ProxyStationSearch.response(from: partialNonEmpty)
        #expect(mapped.results.count == 1 && mapped.coverageComplete == false, "partial + stations: kept, explicitly incomplete")
        #expect(try NearbyE85ProxyStationSearch.response(from: complete).coverageComplete)
    }

    @Test func contradictoryCompleteResponsesAreRejected() throws {
        let cell = StationCatalogueCells.Cell(latCell: 2468, lonCell: 1358)
        let body = Data(#"{"lat_cell":2468,"lon_cell":1358,"radius_miles":25}"#.utf8)
        let two = [Self.station(1, 33.45, -112.07), Self.station(2, 33.46, -112.07)]
        var noID = Self.station(3, 33.45, -112.07); noID.removeValue(forKey: "id")
        let cases: [(String, Data)] = [
            ("total != returned_count", Self.payload(for: body, stations: two, complete: true, total: 3)),
            ("returned_count != decoded count", Self.payload(for: body, stations: two, complete: true, total: 3, returnedCount: 3)),
            ("dropped record", Self.payload(for: body, stations: two, complete: true, dropped: 1)),
            ("missing NLR id", Self.payload(for: body, stations: [noID], complete: true)),
            ("0/0 coordinate", Self.payload(for: body, stations: [Self.station(4, 0, 0)], complete: true)),
            ("out-of-range coordinate", Self.payload(for: body, stations: [Self.station(5, 95, -112.07)], complete: true)),
            ("complete flag vs partial coverage", Self.payload(for: body, stations: two, complete: true, coverage: "partial")),
            ("partial flag vs complete coverage", Self.payload(for: body, stations: two, complete: false, coverage: "complete")),
            ("unknown coverage", Self.payload(for: body, stations: two, complete: false, coverage: "mostly")),
            ("over the 200-candidate page", Self.payload(for: body, stations: (1...201).map { Self.station($0, 33.45, -112.07) }, complete: true)),
            ("partial: negative total", Self.payload(for: body, stations: two, complete: false, total: -1)),
            ("partial: negative returned_count", Self.payload(for: body, stations: [], complete: false, total: 5, returnedCount: -1)),
            ("partial: negative dropped", Self.payload(for: body, stations: two, complete: false, total: 5, dropped: -1)),
            ("partial: returned_count above payload", Self.payload(for: body, stations: two, complete: false, total: 9, returnedCount: 3)),
            ("partial: returned_count below payload", Self.payload(for: body, stations: two, complete: false, total: 9, returnedCount: 1)),
            ("partial: total below returned", Self.payload(for: body, stations: two, complete: false, total: 1)),
        ]
        for (label, data) in cases {
            #expect(throws: NLRServiceError.invalidResponse, "\(label)") {
                try NLRStationService.decode(data, cell: cell, bucket: 25, latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
            }
        }
        // Partial: only valid canonical candidates survive (no 0/0, no missing id); still explicitly incomplete.
        let mixed = [Self.station(6, 0, 0), noID, Self.station(7, 33.45, -112.07)]
        let partial = try NLRStationService.decode(Self.payload(for: body, stations: mixed, complete: false, total: 9, dropped: 2), cell: cell,
                                                   bucket: 25, latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        #expect(!partial.coverageComplete && partial.candidateCount == 3)
        #expect(partial.stations.map(\.nlrID) == [7], "only the id-bearing, validly located station is a candidate")
        // Partial metadata may be truthful with total > returned_count, dropped > 0 or an unknown total.
        let unknownTotal = try NLRStationService.decode(
            Self.payload(for: body, stations: two, complete: false, total: nil, dropped: 1).replacingTotalWithNull(), cell: cell,
            bucket: 25, latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        #expect(!unknownTotal.coverageComplete && unknownTotal.stations.count == 2)
    }

    @Test func staleWarningIsDecodedStrictlyAndKeepsStationsAndSourceTime() throws {
        let cell = StationCatalogueCells.Cell(latCell: 2468, lonCell: 1358)
        let body = Data(#"{"lat_cell":2468,"lon_cell":1358,"radius_miles":25}"#.utf8)
        let one = [Self.station(1, 33.45, -112.07)]
        let decode = { (data: Data) in
            try NLRStationService.decode(data, cell: cell, bucket: 25, latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        }
        // Stale complete + rate limit: stations and original source time kept, warning carried.
        let limited = try decode(Self.payload(for: body, stations: one, complete: true, cache: "stale",
                                              warning: ["code": "CATALOGUE_RATE_LIMITED", "retry_after_seconds": 120]))
        #expect(limited.warning == StationCatalogueWarning(code: .rateLimited, retryAfterSeconds: 120))
        #expect(limited.stations.map(\.nlrID) == [1] && limited.coverageComplete)
        #expect(limited.sourceFetchedAt == ISO8601DateFormatter().date(from: "2026-10-30T10:00:00Z"))
        // Stale complete + upstream failure, no retry delay.
        let failed = try decode(Self.payload(for: body, stations: one, complete: true, cache: "stale",
                                             warning: ["code": "CATALOGUE_UPSTREAM_FAILED"]))
        #expect(failed.warning == StationCatalogueWarning(code: .upstreamFailed, retryAfterSeconds: nil))
        #expect(try decode(Self.payload(for: body, stations: one, complete: true)).warning == nil)
        // Unknown/malformed warnings reject the whole response.
        let bad: [(String, Any)] = [
            ("unknown code", ["code": "EVERYTHING_IS_FINE"]),
            ("zero retry", ["code": "CATALOGUE_RATE_LIMITED", "retry_after_seconds": 0]),
            ("negative retry", ["code": "CATALOGUE_RATE_LIMITED", "retry_after_seconds": -5]),
            ("unbounded retry", ["code": "CATALOGUE_RATE_LIMITED", "retry_after_seconds": 100_000]),
            ("string retry", ["code": "CATALOGUE_RATE_LIMITED", "retry_after_seconds": "soon"]),
            ("non-string code", ["code": 7]),
            ("not an object", "rate limited"),
        ]
        for (label, warning) in bad {
            #expect(throws: NLRServiceError.invalidResponse, "\(label)") {
                try decode(Self.payload(for: body, stations: one, complete: true, cache: "stale", warning: warning))
            }
        }
        #expect(throws: NLRServiceError.invalidResponse, "warning on a non-stale answer") {
            try decode(Self.payload(for: body, stations: one, complete: true, cache: "miss", warning: ["code": "CATALOGUE_RATE_LIMITED"]))
        }
    }

    @Test func rateLimitedRetryAcceptsTheFullHourlyBudgetWaitButOtherCodesStayAt900() throws {
        let cell = StationCatalogueCells.Cell(latCell: 2468, lonCell: 1358)
        let body = Data(#"{"lat_cell":2468,"lon_cell":1358,"radius_miles":25}"#.utf8)
        let one = [Self.station(1, 33.45, -112.07)]
        let decode = { (warning: [String: Any]) in
            try NLRStationService.decode(Self.payload(for: body, stations: one, complete: true, cache: "stale", warning: warning),
                                         cell: cell, bucket: 25, latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        }
        for retry in [901, 3600] {
            let result = try decode(["code": "CATALOGUE_RATE_LIMITED", "retry_after_seconds": retry])
            #expect(result.warning == StationCatalogueWarning(code: .rateLimited, retryAfterSeconds: retry), "rate-limited \(retry) s accepted")
            // Survives the widget adapter with the stale stations and their original source time.
            let mapped = try NearbyE85ProxyStationSearch.response(from: result)
            #expect(mapped.warning == StationCatalogueWarning(code: .rateLimited, retryAfterSeconds: retry))
            #expect(mapped.results.map(\.name) == ["Station 1"])
            #expect(mapped.sourceFetchedAt == ISO8601DateFormatter().date(from: "2026-10-30T10:00:00Z"))
        }
        #expect(throws: NLRServiceError.invalidResponse, "rate-limited 3601 s rejected") {
            try decode(["code": "CATALOGUE_RATE_LIMITED", "retry_after_seconds": 3601])
        }
        #expect(throws: NLRServiceError.invalidResponse, "non-rate-limit codes stay capped at 900 s") {
            try decode(["code": "CATALOGUE_UPSTREAM_FAILED", "retry_after_seconds": 901])
        }
        #expect(try decode(["code": "CATALOGUE_BUSY", "retry_after_seconds": 900]).warning?.retryAfterSeconds == 900)
    }

    @Test func widgetAdapterNeverTurnsAStaleEmptyFallbackIntoNoStations() throws {
        let cell = StationCatalogueCells.Cell(latCell: 2468, lonCell: 1358)
        let body = Data(#"{"lat_cell":2468,"lon_cell":1358,"radius_miles":25}"#.utf8)
        let decode = { (data: Data) in
            try NLRStationService.decode(data, cell: cell, bucket: 25, latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        }
        let staleEmpty = try decode(Self.payload(for: body, stations: [], complete: true, cache: "stale",
                                                 warning: ["code": "CATALOGUE_RATE_LIMITED", "retry_after_seconds": 300]))
        #expect(staleEmpty.coverageComplete && staleEmpty.stations.isEmpty && staleEmpty.warning != nil)
        #expect(throws: NearbyE85WidgetRefreshError.catalogueUnavailable(StationCatalogueWarning(code: .rateLimited, retryAfterSeconds: 300))) {
            try NearbyE85ProxyStationSearch.response(from: staleEmpty)
        }
        let failedEmpty = try decode(Self.payload(for: body, stations: [], complete: true, cache: "stale", warning: ["code": "CATALOGUE_UPSTREAM_FAILED"]))
        #expect(throws: NearbyE85WidgetRefreshError.catalogueUnavailable(StationCatalogueWarning(code: .upstreamFailed, retryAfterSeconds: nil))) {
            try NearbyE85ProxyStationSearch.response(from: failedEmpty)
        }
        // A successful complete-empty refresh (no warning) is still the one authoritative "no stations".
        #expect(try NearbyE85ProxyStationSearch.response(from: decode(Self.payload(for: body, stations: [], complete: true))).results.isEmpty)
    }

    @Test func claimedCompleteWithDuplicateNLRIDsIsRejected() {
        let cell = StationCatalogueCells.Cell(latCell: 2468, lonCell: 1358)
        let body = Data(#"{"lat_cell":2468,"lon_cell":1358,"radius_miles":25}"#.utf8)
        #expect(throws: NLRServiceError.invalidResponse) {
            try NLRStationService.decode(Self.payload(for: body, stations: [Self.station(1, 33.45, -112.07), Self.station(1, 33.46, -112.07)],
                                                      complete: true), cell: cell, bucket: 25, latitude: 33.4484, longitude: -112.074,
                                         radiusMiles: 25, limit: 20)
        }
    }

    @Test func sourceFetchServedTimesStaySeparateAndWrongCellIsRejected() throws {
        let cell = StationCatalogueCells.Cell(latCell: 2468, lonCell: 1358)
        let body = Data(#"{"lat_cell":2468,"lon_cell":1358,"radius_miles":25}"#.utf8)
        let result = try NLRStationService.decode(Self.payload(for: body, stations: [], complete: true), cell: cell, bucket: 25,
                                                  latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        #expect(result.sourceFetchedAt == ISO8601DateFormatter().date(from: "2026-10-30T10:00:00Z"))
        #expect(result.servedAt == ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z"))
        #expect(result.cacheState == "hit")
        let other = Data(#"{"lat_cell":1,"lon_cell":1358,"radius_miles":25}"#.utf8)
        #expect(throws: NLRServiceError.invalidResponse) {
            try NLRStationService.decode(Self.payload(for: other, stations: [], complete: true), cell: cell, bucket: 25,
                                         latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        }
    }

    @Test func stationsMessageOnlySaysNoStationsForCompleteEmpty() {
        let msg = { (complete: Bool, empty: Bool) in StationsView.liveSearchMessage(coverageComplete: complete, isEmpty: empty, radius: "25 mi", place: "your location") }
        #expect(msg(true, false) == nil)
        #expect(msg(true, true)?.hasPrefix("No E85 stations found") == true)
        #expect(msg(false, true)?.hasPrefix("Couldn't confirm") == true)
        #expect(msg(false, false)?.contains("couldn't be confirmed") == true)
        #expect(msg(false, true)?.contains("No E85 stations") == false && msg(false, false)?.contains("No E85 stations") == false)
    }

    // MARK: Transport via stub

    @Test func serviceMapsStatusesAndPartialZero() async throws {
        let limited = stubbedService { _, _ in (429, Data()) }
        await #expect(throws: NLRServiceError.rateLimited) {
            _ = try await limited.search(latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        }
        let failing = stubbedService { _, _ in (502, Data()) }
        await #expect(throws: NLRServiceError.requestFailed(statusCode: 502)) {
            _ = try await failing.search(latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        }
        let partial = stubbedService { _, body in (200, Self.payload(for: body, stations: [], complete: false, total: nil)) }
        await #expect(throws: NLRServiceError.partialCoverage) {
            _ = try await partial.fetchNearbyE85Stations(latitude: 33.4484, longitude: -112.074, radius: 25, limit: 20)
        }
        let unconfigured = NLRStationService(configuration: { nil })
        await #expect(throws: NLRServiceError.catalogueNotConfigured) {
            _ = try await unconfigured.search(latitude: 33.4484, longitude: -112.074, radiusMiles: 25, limit: 20)
        }
        await #expect(throws: NLRServiceError.unsupportedRadius) {
            _ = try await partial.search(latitude: 33.4484, longitude: -112.074, radiusMiles: 250, limit: 20)
        }
    }

    // MARK: Trip Planner corridor

    private static let corridor: [CLLocationCoordinate2D] = (0...30).map {
        CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.05, longitude: -112.0)
    }
    private static let context = RouteFuelContext(tankSizeGallons: 18.5, mpg: 12, currentFuelPercent: 100,
                                                  targetArrivalReservePercent: 20, fuelBackupMode: .gasBackupAllowed)

    @Test func tripPlannerCorridorUsesCoveringBucketsAndDedupsInRouteOrder() async throws {
        let counter = StationCatalogueRequestCounter()
        // Every center sees the same three on-route stations (overlap), listed in reverse route order.
        let onRoute = [Self.station(30, 34.40, -112.0), Self.station(20, 33.75, -112.0), Self.station(10, 33.10, -112.0)]
        let service = stubbedService { _, body in
            counter.record(Self.requestFields(body)["radius_miles"] ?? -1)
            return (200, Self.payload(for: body, stations: onRoute, complete: true))
        }
        let analysis = try await RouteE85Planner(service: service).analyze(
            routeCoordinates: Self.corridor, routeDistanceMeters: 166_000, context: Self.context)
        #expect(counter.count >= 1 && counter.count <= 12, "at most 12 corridor searches, got \(counter.count)")
        #expect(counter.radii.allSatisfy { [25, 50].contains($0) }, "20–45 mi corridor radius served from a covering bucket")
        #expect(analysis.stations.map(\.station.nlrID) == [10, 20, 30], "deduplicated across centers, ordered along the route")
    }

    private func plannerError(_ service: NLRStationService) async -> RouteE85PlannerError? {
        do {
            _ = try await RouteE85Planner(service: service).analyze(routeCoordinates: Self.corridor, routeDistanceMeters: 166_000, context: Self.context)
            return nil
        } catch { return error as? RouteE85PlannerError }
    }

    @Test func tripPlannerPartialCoverageIsNeverNoStations() async throws {
        let partial = stubbedService { _, body in (200, Self.payload(for: body, stations: [], complete: false, total: nil)) }
        guard case .network = await plannerError(partial) else { Issue.record("partial coverage must not be noStationsFound"); return }
        let empty = stubbedService { _, body in (200, Self.payload(for: body, stations: [], complete: true)) }
        guard case .noStationsFound = await plannerError(empty) else { Issue.record("complete + empty is noStationsFound"); return }
    }

    @Test func tripPlannerCompleteEmptyPlusAFailedCenterIsUnknownNotNoStations() async throws {
        // First corridor request answers complete-empty; every later one fails. Coverage is unknown.
        for failure in [429, 502, 504] {
            let counter = StationCatalogueRequestCounter()
            let mixed = stubbedService { _, body in
                counter.next() == 1 ? (200, Self.payload(for: body, stations: [], complete: true)) : (failure, Data())
            }
            guard case .network = await plannerError(mixed) else { Issue.record("complete-empty + \(failure) must not be noStationsFound"); continue }
            #expect(counter.count > 1, "the corridor actually had more than one center")
        }
        // Complete-empty plus an unreadable answer from another center.
        let counter = StationCatalogueRequestCounter()
        let offline = stubbedService { _, body in
            counter.next() == 1 ? (200, Self.payload(for: body, stations: [], complete: true)) : (200, Data("not json".utf8))
        }
        guard case .network = await plannerError(offline) else { Issue.record("complete-empty + invalid answer must not be noStationsFound"); return }
    }

    @Test func stationsOnlyLetsAuthoritativeAnswersReplaceResults() {
        #expect(StationsView.replacesPreviousResults(coverageComplete: true, isEmpty: true), "complete-empty replaces (real no stations)")
        #expect(StationsView.replacesPreviousResults(coverageComplete: true, isEmpty: false))
        #expect(StationsView.replacesPreviousResults(coverageComplete: false, isEmpty: false), "partial with stations: useful, replaces")
        #expect(StationsView.replacesPreviousResults(coverageComplete: false, isEmpty: true) == false,
                "partial-empty keeps the current list and caches; nothing published downstream")
        #expect(StationsView.replacesPreviousResults(coverageComplete: true, isEmpty: true, hasWarning: true) == false,
                "a stale complete-empty fallback is not an authoritative no-stations")
        #expect(StationsView.replacesPreviousResults(coverageComplete: true, isEmpty: false, hasWarning: true), "useful stale stations kept")
        let staleWithStations = StationsView.liveSearchMessage(coverageComplete: true, isEmpty: false, radius: "25 mi", place: "here", hasWarning: true)
        #expect(staleWithStations?.contains("temporarily unavailable") == true && staleWithStations?.contains("No E85") == false)
        #expect(StationsView.liveSearchMessage(coverageComplete: true, isEmpty: true, radius: "25 mi", place: "here", hasWarning: true)?
            .contains("No E85") == false)
    }

    @Test func tripPlannerKeepsAnOnRouteStationHiddenBehindTwentyCenterNearerOnes() async throws {
        // ~52 mi straight route: centers at mile 0, ~mile 26 and the route end. The on-route station sits ~12.5 mi up
        // the route, inside the first two centers' 24.5 mi radius. Around each of those centers, 20 corridor stations
        // ~5 mi off-route are NEARER that center, so a nearest-20 prefix per center would hide the on-route one.
        let route: [CLLocationCoordinate2D] = (0...30).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.025, longitude: -112.0) }
        var stations = [Self.station(999, 33.181, -112.0, name: "On-route E85")]
        for i in 0..<20 {
            stations.append(Self.station(100 + i, 33.0 + Double(i) * 0.002, -111.9136, name: "South crowd \(i)"))
            stations.append(Self.station(200 + i, 33.376 + Double(i) * 0.002, -111.9136, name: "North crowd \(i)"))
        }
        let all = stations
        let service = stubbedService { _, body in (200, Self.payload(for: body, stations: all, complete: true)) }
        let analysis = try await RouteE85Planner(service: service).analyze(routeCoordinates: route, routeDistanceMeters: 83_400,
                                                                            context: Self.context)
        #expect(analysis.stations.contains { $0.station.nlrID == 999 }, "on-route station survives dense center-nearer candidates")
        #expect(analysis.stations.count == 41, "every corridor station from every center, deduplicated")
    }

    @Test func tripPlannerStaleWarningIsNeverNoStations() async throws {
        let stale = stubbedService { _, body in
            (200, Self.payload(for: body, stations: [], complete: true, cache: "stale", warning: ["code": "CATALOGUE_RATE_LIMITED", "retry_after_seconds": 60]))
        }
        guard case .network = await plannerError(stale) else { Issue.record("warning-backed empty must not be noStationsFound"); return }
    }
}

private extension Data {
    /// The payload helper defaults a nil total to the station count; this sends a JSON null total instead.
    func replacingTotalWithNull() -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: self)) as? [String: Any] else { return self }
        object["total"] = NSNull()
        return (try? JSONSerialization.data(withJSONObject: object)) ?? self
    }
}

/// Thread-safe request recorder for the stub handler (which runs on URLSession's queue).
nonisolated final class StationCatalogueRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func record(_ radius: Int) { lock.lock(); values.append(radius); lock.unlock() }
    /// Atomically records a request and returns its 1-based arrival index.
    func next() -> Int { lock.lock(); defer { lock.unlock() }; values.append(0); return values.count }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var radii: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}
