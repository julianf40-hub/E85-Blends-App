//
//  NRELStationService.swift
//  EightyFiveBlends
//
//  The app's and widget's one E85 station-catalogue client. 85Blends 2.4.1 — searches go through
//  the 85Blends Supabase proxy (`station-catalogue-v1`, POST v2 coarse-cell contract), never
//  directly to NLR: no upstream credential exists in the app or widget. The file name is kept for
//  target compatibility (compiled into both the app and NearbyE85Widget targets).

import Foundation

nonisolated struct NLRFuelStationResponse: Decodable {
    /// NLR's own station id, preserved end to end by the proxy.
    let id: Int?
    let stationName: String?
    let streetAddress: String?
    let city: String?
    let state: String?
    let zip: String?
    let latitude: Double?
    let longitude: Double?
    let distance: Double?
    let stationPhone: String?
    let accessDaysTime: String?
    let dateLastConfirmed: String?
    let fuelTypeCode: String?

    enum CodingKeys: String, CodingKey {
        case id
        case stationName = "station_name"
        case streetAddress = "street_address"
        case city
        case state
        case zip
        case latitude
        case longitude
        case distance
        case stationPhone = "station_phone"
        case accessDaysTime = "access_days_time"
        case dateLastConfirmed = "date_last_confirmed"
        case fuelTypeCode = "fuel_type_code"
    }
}

nonisolated struct LiveFuelStation: Identifiable, Equatable {
    let id = UUID()
    /// NLR's station id when known. Community identity remains CommunityStationKey's canonical key.
    let nlrID: Int?
    let name: String
    let address: String
    let city: String
    let state: String
    let zip: String
    let latitude: Double
    let longitude: Double
    let distanceMiles: Double
    let phone: String
    let accessHours: String
    let dateLastConfirmed: String
    let fuelTypeCode: String

    init(from station: NLRFuelStationResponse) {
        nlrID = station.id
        name = station.stationName?.nilIfBlank ?? "Unknown Station"
        address = station.streetAddress?.nilIfBlank ?? ""
        city = station.city?.nilIfBlank ?? ""
        state = station.state?.nilIfBlank ?? ""
        zip = station.zip?.nilIfBlank ?? ""
        latitude = station.latitude ?? 0
        longitude = station.longitude ?? 0
        distanceMiles = station.distance ?? 0
        phone = station.stationPhone?.nilIfBlank ?? ""
        accessHours = station.accessDaysTime?.nilIfBlank ?? ""
        dateLastConfirmed = station.dateLastConfirmed?.nilIfBlank ?? ""
        fuelTypeCode = station.fuelTypeCode?.nilIfBlank ?? ""
    }

    /// Direct field init for constructing synthetic stations — used by RouteE85PlannerTests
    /// to exercise the greedy stop planner without a live station search.
    init(
        nlrID: Int? = nil,
        name: String,
        address: String = "",
        city: String = "",
        state: String = "",
        zip: String = "",
        latitude: Double,
        longitude: Double,
        distanceMiles: Double = 0,
        phone: String = "",
        accessHours: String = "",
        dateLastConfirmed: String = "",
        fuelTypeCode: String = "E85"
    ) {
        self.nlrID = nlrID
        self.name = name
        self.address = address
        self.city = city
        self.state = state
        self.zip = zip
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMiles = distanceMiles
        self.phone = phone
        self.accessHours = accessHours
        self.dateLastConfirmed = dateLastConfirmed
        self.fuelTypeCode = fuelTypeCode
    }

    /// Same station with an exact on-device distance from the searcher's own position.
    func withDistance(_ miles: Double) -> LiveFuelStation {
        LiveFuelStation(nlrID: nlrID, name: name, address: address, city: city, state: state, zip: zip,
                        latitude: latitude, longitude: longitude, distanceMiles: miles, phone: phone,
                        accessHours: accessHours, dateLastConfirmed: dateLastConfirmed, fuelTypeCode: fuelTypeCode)
    }
}

nonisolated enum NLRServiceError: LocalizedError, Equatable {
    /// The public proxy endpoint/publishable identification is missing from this bundle.
    case catalogueNotConfigured
    case invalidURL
    case requestFailed(statusCode: Int)
    case invalidResponse
    /// No caller radius above the largest server bucket is ever silently shrunk.
    case unsupportedRadius
    /// The service could not confirm complete coverage AND no station fell inside the radius:
    /// this is "unknown", never an authoritative "no stations".
    case partialCoverage
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .catalogueNotConfigured:
            return "Live station search is not configured in this build."
        case .invalidURL:
            return "Could not build a valid station search request."
        case .requestFailed(let statusCode):
            return "Station search failed with status \(statusCode)."
        case .invalidResponse:
            return "Station search returned an invalid response."
        case .unsupportedRadius:
            return "That search radius is not supported."
        case .partialCoverage:
            return "Station search couldn't confirm complete coverage for this area."
        case .rateLimited:
            return "Station search is busy. Try again shortly."
        }
    }
}

// MARK: - Coarse cells (must match supabase/functions/station-catalogue-v1/cells.ts exactly)

/// Fixed 0.05-degree cells in integer microdegrees: `e6 = floor(deg * 1e6 + 0.5)`, the same IEEE
/// double expression and rounding the TypeScript proxy uses, so both sides always agree on a cell.
/// Only the cell index leaves the device; exact filtering happens locally.
nonisolated enum StationCatalogueCells {
    static let cellE6 = 50_000
    static let latCells = 3_600
    static let lonCells = 7_200
    static let radiusBuckets = [10, 25, 50, 100, 200]

    struct Cell: Equatable, Hashable {
        let latCell: Int
        let lonCell: Int
    }

    static func toE6(_ degrees: Double) -> Int { Int((degrees * 1e6 + 0.5).rounded(.down)) }

    /// Into [-180e6, 180e6): +180 and -180 are the same meridian.
    static func normalizeLongitudeE6(_ e6: Int) -> Int {
        let span = 360_000_000
        return (((e6 + 180_000_000) % span) + span) % span - 180_000_000
    }

    static func cell(latitude: Double, longitude: Double) -> Cell? {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), abs(longitude) <= 1e9 else { return nil }
        let latE6 = toE6(latitude)
        let latCell = min(latCells - 1, max(0, Int((Double(latE6 + 90_000_000) / Double(cellE6)).rounded(.down))))
        let lonCell = (normalizeLongitudeE6(toE6(longitude)) + 180_000_000) / cellE6
        return Cell(latCell: latCell, lonCell: lonCell)
    }

    /// Smallest server bucket that still covers `radiusMiles` (results are filtered back to the exact
    /// radius on device), or nil when the radius exceeds every bucket — never silently shrunk.
    static func bucket(forRadiusMiles radiusMiles: Double) -> Int? {
        guard radiusMiles.isFinite, radiusMiles > 0 else { return nil }
        return radiusBuckets.first { Double($0) >= radiusMiles }
    }

    static func distanceMiles(latitude1: Double, longitude1: Double, latitude2: Double, longitude2: Double) -> Double {
        let rad = Double.pi / 180
        let dLat = (latitude2 - latitude1) * rad, dLon = (longitude2 - longitude1) * rad
        let a = pow(sin(dLat / 2), 2) + cos(latitude1 * rad) * cos(latitude2 * rad) * pow(sin(dLon / 2), 2)
        return 2 * 3_958.7613 * asin(min(1, a.squareRoot()))
    }
}

// MARK: - Public proxy configuration

/// The proxy endpoint and the project's PUBLISHABLE key (public client identification, not a
/// secret, not user auth) read from the running bundle's Info.plist — the app's or the widget's own.
/// Never a service-role or upstream key.
nonisolated struct StationCatalogueConfig: Equatable {
    let endpoint: URL
    let publishableKey: String

    static func load(from bundle: Bundle = .main) -> StationCatalogueConfig? {
        make(url: bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
             publishableKey: bundle.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String)
    }

    static func make(url rawURL: String?, publishableKey rawKey: String?) -> StationCatalogueConfig? {
        guard let rawURL = rawURL?.nilIfBlank, let url = URL(string: rawURL), url.scheme == "https", url.host != nil,
              let key = rawKey?.nilIfBlank, key.hasPrefix("sb_publishable_") else { return nil }
        // Same normalization as ReferralAPIService.edgeFunctionURL: a configured ".../rest/v1" is the project base.
        let components = url.pathComponents.filter { $0 != "/" }
        let base = components.suffix(2) == ["rest", "v1"] ? url.deletingLastPathComponent().deletingLastPathComponent() : url
        return StationCatalogueConfig(endpoint: base.appending(path: "functions").appending(path: "v1").appending(path: "station-catalogue-v1"),
                                      publishableKey: key)
    }
}

/// The proxy's typed reason a STALE answer was served instead of a fresh one (after an upstream 429/failure, a
/// busy refresh or a deadline). The stations and their original source time are still real; the refresh wasn't.
nonisolated struct StationCatalogueWarning: Equatable, Sendable {
    nonisolated enum Code: String, Equatable, Sendable {
        case rateLimited = "CATALOGUE_RATE_LIMITED"
        case busy = "CATALOGUE_BUSY"
        case upstreamFailed = "CATALOGUE_UPSTREAM_FAILED"
        case upstreamTooLarge = "CATALOGUE_UPSTREAM_TOO_LARGE"
        case invalidResponse = "CATALOGUE_INVALID_RESPONSE"
        case timeout = "CATALOGUE_TIMEOUT"
        case unavailable = "CATALOGUE_UNAVAILABLE"
    }
    let code: Code
    /// Positive and bounded when present. `CATALOGUE_RATE_LIMITED` may carry up to 3600 s (a full shared hourly budget
    /// can need that long; the provider cooldown itself is capped at 900 s server-side); every other code up to 900 s.
    let retryAfterSeconds: Int?
}

/// One search's outcome. Four clocks stay separate and none is ever relabeled: `sourceFetchedAt`
/// (when the proxy actually fetched from NLR — older for a cached/stale answer), `servedAt` (when
/// the proxy answered), the caller's own location-fix time, and each community report's
/// `reportedAt` (resolved separately, untouched here).
nonisolated struct StationCatalogueSearchResult: Equatable {
    /// Exact on-device in-radius stations, nearest first, at most the caller's limit.
    let stations: [LiveFuelStation]
    /// True only when the service itself reported complete coverage.
    let coverageComplete: Bool
    /// How many candidates the service returned before local filtering.
    let candidateCount: Int
    let sourceFetchedAt: Date
    let servedAt: Date
    let cacheState: String
    /// Present only on a stale fallback: the stations are usable, but this was NOT a successful refresh.
    var warning: StationCatalogueWarning? = nil
}

private nonisolated struct StationCatalogueV2Warning: Decodable {
    let code: String
    let retryAfterSeconds: Int?
    enum CodingKeys: String, CodingKey { case code, retryAfterSeconds = "retry_after_seconds" }
}

private nonisolated struct StationCatalogueV2Response: Decodable {
    let v: Int
    let latCell: Int
    let lonCell: Int
    let radiusMiles: Int
    let complete: Bool
    let coverage: String
    let total: Int?
    let returnedCount: Int
    let dropped: Int
    let cache: String
    let warning: StationCatalogueV2Warning?
    let sourceFetchedAt: String
    let servedAt: String
    let fuelStations: [NLRFuelStationResponse]

    enum CodingKeys: String, CodingKey {
        case v, complete, coverage, total, dropped, cache, warning
        case latCell = "lat_cell", lonCell = "lon_cell", radiusMiles = "radius_miles"
        case returnedCount = "returned_count", sourceFetchedAt = "source_fetched_at", servedAt = "served_at"
        case fuelStations = "fuel_stations"
    }
}

struct NLRStationService {
    /// Transport bound: above the proxy's own 8 s whole deadline, inside the widget's 10 s search stage.
    nonisolated static let transportTimeout: TimeInterval = 9

    private let session: URLSession
    private let configuration: () -> StationCatalogueConfig?

    init(session: URLSession = NLRStationService.defaultSession,
         configuration: @escaping () -> StationCatalogueConfig? = { StationCatalogueConfig.load() }) {
        self.session = session
        self.configuration = configuration
    }

    static var defaultSession: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = transportTimeout
        configuration.timeoutIntervalForResource = transportTimeout
        return URLSession(configuration: configuration)
    }

    /// Back-compatible list API. An incomplete answer with no in-radius station throws
    /// `.partialCoverage` instead of returning a misleading empty list.
    func fetchNearbyE85Stations(latitude: Double, longitude: Double, radius: Double, limit: Int) async throws -> [LiveFuelStation] {
        let result = try await search(latitude: latitude, longitude: longitude, radiusMiles: radius, limit: limit)
        if result.stations.isEmpty && !result.coverageComplete { throw NLRServiceError.partialCoverage }
        return result.stations
    }

    /// Coarse-cell proxy search: sends only the 0.05° cell and a covering radius bucket, receives the
    /// FULL bounded candidate set, then filters to the exact radius, sorts by exact distance and only
    /// then applies `limit`.
    func search(latitude: Double, longitude: Double, radiusMiles: Double, limit: Int) async throws -> StationCatalogueSearchResult {
        guard let config = configuration() else { throw NLRServiceError.catalogueNotConfigured }
        guard let cell = StationCatalogueCells.cell(latitude: latitude, longitude: longitude) else { throw NLRServiceError.invalidURL }
        guard let bucket = StationCatalogueCells.bucket(forRadiusMiles: radiusMiles) else { throw NLRServiceError.unsupportedRadius }
        let request = Self.makeRequest(config: config, cell: cell, bucket: bucket)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NLRServiceError.invalidResponse }
        if http.statusCode == 429 { throw NLRServiceError.rateLimited }
        guard (200...299).contains(http.statusCode) else { throw NLRServiceError.requestFailed(statusCode: http.statusCode) }
        return try Self.decode(data, cell: cell, bucket: bucket, latitude: latitude, longitude: longitude,
                               radiusMiles: radiusMiles, limit: limit)
    }

    /// The proxy's own upstream page size: a "complete" answer can never carry more candidates than this.
    nonisolated static let maxCandidates = 200

    nonisolated static func hasValidCoordinate(_ station: NLRFuelStationResponse) -> Bool {
        guard let lat = station.latitude, let lon = station.longitude, lat.isFinite, lon.isFinite else { return false }
        return (-90...90).contains(lat) && (-180...180).contains(lon) && !(lat == 0 && lon == 0)
    }

    nonisolated static func makeRequest(config: StationCatalogueConfig, cell: StationCatalogueCells.Cell, bucket: Int) -> URLRequest {
        var request = URLRequest(url: config.endpoint, timeoutInterval: transportTimeout)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"v\":2,\"lat_cell\":\(cell.latCell),\"lon_cell\":\(cell.lonCell),\"radius_miles\":\(bucket)}".utf8)
        return request
    }

    /// Pure: proxy payload → exact local result. Rejects an answer for a different cell/bucket.
    nonisolated static func decode(_ data: Data, cell: StationCatalogueCells.Cell, bucket: Int, latitude: Double, longitude: Double,
                       radiusMiles: Double, limit: Int) throws -> StationCatalogueSearchResult {
        let decoded: StationCatalogueV2Response
        do { decoded = try JSONDecoder().decode(StationCatalogueV2Response.self, from: data) } catch { throw NLRServiceError.invalidResponse }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard decoded.v == 2, decoded.latCell == cell.latCell, decoded.lonCell == cell.lonCell, decoded.radiusMiles == bucket,
              let sourceFetchedAt = iso.date(from: decoded.sourceFetchedAt), let servedAt = iso.date(from: decoded.servedAt)
        else { throw NLRServiceError.invalidResponse }
        guard decoded.coverage == "complete" || decoded.coverage == "partial" else { throw NLRServiceError.invalidResponse }
        // Metadata must be truthful for EVERY answer, partial included: nonnegative counts, returned_count equal to
        // the payload actually sent, and a known total never smaller than what was returned.
        guard decoded.returnedCount >= 0, decoded.dropped >= 0, (decoded.total ?? 0) >= 0,
              decoded.returnedCount == decoded.fuelStations.count,
              decoded.total.map({ $0 >= decoded.returnedCount }) ?? true
        else { throw NLRServiceError.invalidResponse }
        // Completeness is never trusted on the flag alone: a "complete" answer must be internally consistent,
        // otherwise it is rejected outright rather than becoming a fabricated complete (possibly empty) result.
        let claimsComplete = decoded.complete || decoded.coverage == "complete"
        if claimsComplete {
            guard decoded.complete, decoded.coverage == "complete", decoded.dropped == 0,
                  decoded.total == decoded.returnedCount, decoded.returnedCount == decoded.fuelStations.count,
                  decoded.returnedCount <= maxCandidates,
                  decoded.fuelStations.allSatisfy({ $0.id != nil && Self.hasValidCoordinate($0) }),
                  Set(decoded.fuelStations.compactMap(\.id)).count == decoded.fuelStations.count
            else { throw NLRServiceError.invalidResponse }
        }
        let complete = claimsComplete
        // A partial answer keeps only valid canonical candidates (NLR id + valid coordinate) and stays incomplete.
        let inRadius = decoded.fuelStations.compactMap { raw -> LiveFuelStation? in
            guard raw.id != nil, Self.hasValidCoordinate(raw), let lat = raw.latitude, let lon = raw.longitude else { return nil }
            let miles = StationCatalogueCells.distanceMiles(latitude1: latitude, longitude1: longitude, latitude2: lat, longitude2: lon)
            return miles <= radiusMiles ? LiveFuelStation(from: raw).withDistance(miles) : nil
        }
        let sorted = inRadius.sorted { $0.distanceMiles == $1.distanceMiles ? ($0.nlrID ?? 0) < ($1.nlrID ?? 0) : $0.distanceMiles < $1.distanceMiles }
        return StationCatalogueSearchResult(stations: Array(sorted.prefix(max(0, limit))), coverageComplete: complete,
                                            candidateCount: decoded.fuelStations.count, sourceFetchedAt: sourceFetchedAt,
                                            servedAt: servedAt, cacheState: decoded.cache,
                                            warning: try Self.validatedWarning(decoded.warning, cache: decoded.cache))
    }

    /// Retry ceiling per warning code: the rate-limited budget wait can reach an hour; other stale reasons can't.
    nonisolated static func maxRetrySeconds(for code: StationCatalogueWarning.Code) -> Int {
        code == .rateLimited ? 3600 : 900
    }

    /// Strict: a warning must carry a known code, may only accompany a stale answer, and a retry delay (when
    /// present) must be a positive, bounded number of seconds. Anything else rejects the whole response.
    nonisolated private static func validatedWarning(_ raw: StationCatalogueV2Warning?, cache: String) throws -> StationCatalogueWarning? {
        guard let raw else { return nil }
        guard cache == "stale", let code = StationCatalogueWarning.Code(rawValue: raw.code) else { throw NLRServiceError.invalidResponse }
        if let retry = raw.retryAfterSeconds, !(1...maxRetrySeconds(for: code)).contains(retry) { throw NLRServiceError.invalidResponse }
        return StationCatalogueWarning(code: code, retryAfterSeconds: raw.retryAfterSeconds)
    }
}

typealias NRELServiceError = NLRServiceError

struct NRELStationService {
    private let service: NLRStationService

    init(session: URLSession = NLRStationService.defaultSession) {
        service = NLRStationService(session: session)
    }

    func fetchNearbyE85Stations(
        latitude: Double,
        longitude: Double,
        radius: Double = 25,
        limit: Int = 20
    ) async throws -> [LiveFuelStation] {
        try await service.fetchNearbyE85Stations(
            latitude: latitude,
            longitude: longitude,
            radius: radius,
            limit: limit
        )
    }
}

nonisolated private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
