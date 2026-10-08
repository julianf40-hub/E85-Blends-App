//
//  CommunityPriceService.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation

enum CommunityPriceServiceError: LocalizedError {
    case notConfigured
    case invalidBaseURL
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse
    case stationLookupFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Community price sync is not configured yet."
        case .invalidBaseURL:
            return "Community price sync URL is invalid."
        case .requestFailed:
            return "Community price sync request failed."
        case .invalidResponse:
            return "Community price sync returned an unexpected response."
        case .stationLookupFailed:
            return "Community station lookup failed."
        }
    }
}

struct CommunityPriceService {
    private static let maximumNoteLength = 500
    private static let defaultTimeoutInterval: TimeInterval = 18
    /// How many of a station's newest reports one fetch reads, so the app can find the newest CASH price and the
    /// newest CREDIT price (and a legacy unclassified one) from a single request. A method whose latest report is
    /// older than this many newer reports simply has no line (an old price is never promoted to the current one).
    static let recentReportWindow = 20

    private let config: SupabaseConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = CommunityPriceService.defaultSession) throws {
        let loadedConfig: SupabaseConfig
        do {
            loadedConfig = try SupabaseConfig.load()
        } catch {
            throw CommunityPriceServiceError.notConfigured
        }
        self.init(config: loadedConfig, session: session)
    }

    /// The same service over an explicit configuration. Production uses `init(session:)`, which reads the app's
    /// own; this exists so a test can point the real request-building code at a stub session without depending on
    /// the host app's Info.plist (2.4.1 Phase 3C: the payment-type request shape is pinned by tests).
    init(config: SupabaseConfig, session: URLSession) {
        self.config = config
        self.session = session

        let decoder = JSONDecoder()
        // PostgREST returns created_at with fractional seconds, which `.iso8601` is not guaranteed
        // to read on every supported OS; see SupabaseTimestampDecoding.swift. The encoder is unchanged.
        decoder.dateDecodingStrategy = SupabaseTimestamp.decodingStrategy
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    private static var defaultSession: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = defaultTimeoutInterval
        configuration.timeoutIntervalForResource = defaultTimeoutInterval
        return URLSession(configuration: configuration)
    }

    static var anonymousReporterID: String {
        let key = "communityPriceReporterID"
        if let existing = UserDefaults.standard.string(forKey: key), existing.isEmpty == false {
            return existing
        }

        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    func fetchLatestPrice(forNormalizedStationKey normalizedStationKey: String) async throws -> CommunityPriceSummary? {
        let trimmedKey = normalizedStationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.isEmpty == false else { return nil }

        let station = try await fetchCommunityStation(forNormalizedStationKey: trimmedKey)
        guard let stationID = station?.id else { return nil }

        let reports = try await fetchRecentReports(stationID: stationID)

        guard reports.isEmpty == false else { return nil }

        return CommunityPriceSummary(
            normalizedStationKey: trimmedKey,
            latestReport: reports.first,
            reportCount: reports.first == nil ? 0 : 1,
            recentReports: reports
        )
    }

    /// The station's newest reports (any payment type), newest first.
    ///
    /// 2.4.1 (Phase 3C): `payment_type` is selected, and the newest few reports are read (not just one) so the
    /// per-method prices can be told apart. note / app_version are not shown anywhere and are no longer read. The
    /// first row is still "the newest report of any kind", so `latestReport` keeps its original meaning.
    ///
    /// A backend that has not had the payment-type migration applied yet answers this select with a 400 (the column
    /// does not exist). Community prices must not disappear because of deployment order, so that one case reads
    /// again WITHOUT the column: every report then reads as unclassified and the Stations screen shows its legacy
    /// single price. Only a 400 does this; every other failure is reported as before. (Submitting a report does
    /// not fall back — see submitPriceReport.)
    private func fetchRecentReports(stationID: UUID) async throws -> [CommunityPriceReport] {
        do {
            return try await recentReports(stationID: stationID, includingPaymentType: true)
        } catch let error as CommunityPriceServiceError {
            guard case .requestFailed(let statusCode, _) = error, statusCode == 400 else { throw error }
            return try await recentReports(stationID: stationID, includingPaymentType: false)
        }
    }

    private func recentReports(stationID: UUID, includingPaymentType: Bool) async throws -> [CommunityPriceReport] {
        var components = try reportsEndpointComponents()
        let columns = includingPaymentType
            ? "id,station_id,price,reported_at,payment_type,anonymous_reporter_id,created_at"
            : "id,station_id,price,reported_at,anonymous_reporter_id,created_at"
        components.queryItems = [
            URLQueryItem(name: "select", value: columns),
            URLQueryItem(name: "station_id", value: "eq.\(stationID.uuidString)"),
            URLQueryItem(name: "order", value: "reported_at.desc,created_at.desc"),
            URLQueryItem(name: "limit", value: String(Self.recentReportWindow))
        ]
        return try await performRequest(
            components: components,
            method: "GET",
            functionName: "fetchLatestPrice"
        )
    }

    func fetchLatestEthanolReport(
        forNormalizedStationKey normalizedStationKey: String
    ) async throws -> CommunityEthanolSummary? {
        let trimmedKey = normalizedStationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.isEmpty == false else { return nil }

        let station = try await fetchCommunityStation(forNormalizedStationKey: trimmedKey)
        guard let stationID = station?.id else { return nil }

        var components = try ethanolReportsEndpointComponents()
        components.queryItems = [
            URLQueryItem(
                name: "select",
                value: "id,station_id,ethanol_percentage,reported_at,anonymous_reporter_id,app_version,note,created_at"
            ),
            URLQueryItem(name: "station_id", value: "eq.\(stationID.uuidString)"),
            URLQueryItem(name: "order", value: "reported_at.desc,created_at.desc"),
            URLQueryItem(name: "limit", value: "1")
        ]

        let reports: [CommunityEthanolReport] = try await performRequest(
            components: components,
            method: "GET",
            functionName: "fetchLatestEthanolReport"
        )

        guard reports.isEmpty == false else { return nil }

        return CommunityEthanolSummary(
            normalizedStationKey: trimmedKey,
            latestReport: reports.first,
            reportCount: reports.first == nil ? 0 : 1
        )
    }

    /// 2.3.2 community-station upsert security hardening: this used to send
    /// `Prefer: resolution=merge-duplicates`, which PostgREST turns into
    /// `INSERT ... ON CONFLICT (normalized_key) DO UPDATE ...` -- Postgres requires UPDATE
    /// privilege for that statement shape regardless of whether a conflict actually occurs.
    /// Granting anonymous clients UPDATE on an existing community station's display/location
    /// fields just to make this upsert convenient was broader than the app actually needs: no
    /// legitimate 85Blends flow edits an *existing* station's details from this call -- the
    /// existence check three lines below already returns early with the current row whenever
    /// one is found, so the POST below only ever runs for a normalized_key this client believes
    /// is genuinely new.
    ///
    /// `Prefer: resolution=ignore-duplicates` instead generates
    /// `INSERT ... ON CONFLICT (normalized_key) DO NOTHING`, which requires only INSERT
    /// privilege -- never UPDATE -- because a DO NOTHING conflict action never touches the
    /// conflicting row. The only behavior difference from the caller's perspective: if another
    /// request has *just* created the same normalized_key (the genuine concurrent-race case --
    /// two devices reporting the same brand-new station within the same moment), this insert
    /// becomes a no-op and PostgREST returns an empty body/array instead of the row. That exact
    /// case was already handled below (`isResponseBodyEmpty` / the empty-array branch of
    /// `decodeSingleOrArray`), which falls back to re-fetching by normalized_key -- so both
    /// racing clients still converge on the one row the winner created, they just never attempt
    /// to overwrite its fields to do so.
    func upsertCommunityStation(
        normalizedStationKey: String,
        name: String,
        streetAddress: String?,
        city: String?,
        state: String?,
        zip: String?,
        latitude: Double?,
        longitude: Double?
    ) async throws -> CommunityStation {
        if let existingStation = try await fetchCommunityStation(forNormalizedStationKey: normalizedStationKey) {
            return existingStation
        }

        var components = try stationsEndpointComponents()
        components.queryItems = [
            URLQueryItem(name: "on_conflict", value: "normalized_key")
        ]

        let payload = CommunityStationPayload(
            normalizedStationKey: normalizedStationKey,
            name: name,
            streetAddress: streetAddress,
            city: city,
            state: state,
            zip: zip,
            latitude: latitude,
            longitude: longitude,
            updatedAt: .now
        )

        let data: Data
        do {
            data = try await performRequestData(
                components: components,
                method: "POST",
                functionName: "upsertCommunityStation",
                payload: AnyEncodable(payload),
                extraHeaders: [
                    "Prefer": "resolution=ignore-duplicates,return=representation"
                ]
            )
        } catch {
            if let existingStation = try await fetchCommunityStation(forNormalizedStationKey: normalizedStationKey) {
                return existingStation
            }
            throw error
        }

        if isResponseBodyEmpty(data) {
            if let existingStation = try await fetchCommunityStation(forNormalizedStationKey: normalizedStationKey) {
                return existingStation
            }
            throw CommunityPriceServiceError.stationLookupFailed
        }

        if let station = try decodeSingleOrArray(CommunityStation.self, from: data) {
            return station
        }

        if let existingStation = try await fetchCommunityStation(forNormalizedStationKey: normalizedStationKey) {
            return existingStation
        }

        throw CommunityPriceServiceError.stationLookupFailed
    }

    func submitPriceReport(
        normalizedStationKey: String,
        stationID: UUID? = nil,
        price: Double,
        reportedAt: Date = .now,
        notes: String? = nil,
        appVersion: String? = nil,
        paymentType: CommunityPaymentType? = nil
    ) async throws -> CommunityPriceReport {
        let resolvedStationID: UUID
        if let stationID {
            resolvedStationID = stationID
        } else {
            let station = try await upsertCommunityStation(
                normalizedStationKey: normalizedStationKey,
                name: normalizedStationKey,
                streetAddress: nil,
                city: nil,
                state: nil,
                zip: nil,
                latitude: nil,
                longitude: nil
            )
            guard let stationID = station.id else {
                throw CommunityPriceServiceError.stationLookupFailed
            }
            resolvedStationID = stationID
        }

        let limitedNotes = Self.limitedNote(from: notes)
        // 2.4.1 (Phase 3C): sent only when the person said which price this is. `nil` (a caller that does not
        // know) and `.unknown` are both OMITTED, so the request is byte-for-byte what an older app sends and the
        // server stores `unknown`; a payment type is never guessed or defaulted here.
        let sentPaymentType: CommunityPaymentType? = (paymentType?.isSpecified == true) ? paymentType : nil
        let payload = CommunityPriceReportPayload(
            stationID: resolvedStationID,
            price: roundedPrice(price),
            reportedAt: reportedAt,
            reporterID: Self.anonymousReporterID,
            note: limitedNotes,
            appVersion: appVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
            paymentType: sentPaymentType
        )

        let data = try await performRequestData(
            components: try reportsEndpointComponents(),
            method: "POST",
            functionName: "submitPriceReport",
            payload: AnyEncodable(payload),
            extraHeaders: [
                "Prefer": "return=representation"
            ]
        )

        if isResponseBodyEmpty(data) {
            return CommunityPriceReport(
                id: nil,
                stationID: resolvedStationID,
                normalizedStationKey: normalizedStationKey,
                price: roundedPrice(price),
                reportedAt: reportedAt,
                reporterID: Self.anonymousReporterID,
                notes: limitedNotes,
                createdAt: nil,
                paymentType: sentPaymentType ?? .unknown
            )
        }

        if let report = try decodeSingleOrArray(CommunityPriceReport.self, from: data) {
            return report
        }

        throw CommunityPriceServiceError.invalidResponse
    }

    func submitEthanolReport(
        normalizedStationKey: String,
        stationID: UUID? = nil,
        ethanolPercentage: Double,
        reportedAt: Date = .now,
        notes: String? = nil,
        appVersion: String? = nil
    ) async throws -> CommunityEthanolReport {
        let resolvedStationID: UUID
        if let stationID {
            resolvedStationID = stationID
        } else {
            let station = try await upsertCommunityStation(
                normalizedStationKey: normalizedStationKey,
                name: normalizedStationKey,
                streetAddress: nil,
                city: nil,
                state: nil,
                zip: nil,
                latitude: nil,
                longitude: nil
            )
            guard let stationID = station.id else {
                throw CommunityPriceServiceError.stationLookupFailed
            }
            resolvedStationID = stationID
        }

        let normalizedPercentage = CommunityEthanolValidation.normalizedToOneDecimalPlace(
            ethanolPercentage
        )
        let limitedNotes = Self.limitedNote(from: notes)
        let payload = CommunityEthanolReportPayload(
            stationID: resolvedStationID,
            ethanolPercentage: normalizedPercentage,
            reportedAt: reportedAt,
            reporterID: Self.anonymousReporterID,
            note: limitedNotes,
            appVersion: appVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let data = try await performRequestData(
            components: try ethanolReportsEndpointComponents(),
            method: "POST",
            functionName: "submitEthanolReport",
            payload: AnyEncodable(payload),
            extraHeaders: [
                "Prefer": "return=representation"
            ]
        )

        if isResponseBodyEmpty(data) {
            return CommunityEthanolReport(
                id: nil,
                stationID: resolvedStationID,
                ethanolPercentage: normalizedPercentage,
                reportedAt: reportedAt,
                reporterID: Self.anonymousReporterID,
                notes: limitedNotes,
                createdAt: nil
            )
        }

        if let report = try decodeSingleOrArray(CommunityEthanolReport.self, from: data) {
            return report
        }

        throw CommunityPriceServiceError.invalidResponse
    }

    private func stationsEndpointComponents() throws -> URLComponents {
        try endpointComponents(path: "community_stations")
    }

    private func reportsEndpointComponents() throws -> URLComponents {
        try endpointComponents(path: "e85_price_reports")
    }

    private func ethanolReportsEndpointComponents() throws -> URLComponents {
        try endpointComponents(path: "e85_ethanol_reports")
    }

    private func fetchCommunityStation(forNormalizedStationKey normalizedStationKey: String) async throws -> CommunityStation? {
        var components = try stationsEndpointComponents()
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,normalized_key,name,address,city,state,zip,latitude,longitude,created_at,updated_at"),
            URLQueryItem(name: "normalized_key", value: "eq.\(normalizedStationKey)"),
            URLQueryItem(name: "limit", value: "1")
        ]

        let stations: [CommunityStation] = try await performRequest(
            components: components,
            method: "GET",
            functionName: "fetchCommunityStation"
        )

        return stations.first
    }

    private func endpointComponents(path: String) throws -> URLComponents {
        let endpoint = try normalizedRESTBaseURL().appending(path: path)

        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw CommunityPriceServiceError.invalidBaseURL
        }

        return components
    }

    private func normalizedRESTBaseURL() throws -> URL {
        let pathComponents = config.url.pathComponents.filter { $0 != "/" }

        if pathComponents.suffix(2) == ["rest", "v1"] {
            return config.url
        }

        return config.url
            .appending(path: "rest")
            .appending(path: "v1")
    }

    private func performRequest<Response: Decodable>(
        components: URLComponents,
        method: String,
        functionName: String,
        payload: AnyEncodable? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        let data = try await performRequestData(
            components: components,
            method: method,
            functionName: functionName,
            payload: payload,
            extraHeaders: extraHeaders
        )

        return try decoder.decode(Response.self, from: data)
    }

    private func performRequestData(
        components: URLComponents,
        method: String,
        functionName: String,
        payload: AnyEncodable? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        guard let url = components.url else {
            throw CommunityPriceServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        extraHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        var debugPayloadKeys: [String] = []
        var debugPayloadValues: [String: String] = [:]
        if let payload {
            let requestBody = try encoder.encode(payload)
            request.httpBody = requestBody
            #if DEBUG
            let payloadSummary = debugPayloadSummary(from: requestBody)
            debugPayloadKeys = payloadSummary.keys
            debugPayloadValues = payloadSummary.values
            #endif
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CommunityPriceServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            #if DEBUG
            logSupabaseFailure(
                functionName: functionName,
                method: method,
                statusCode: httpResponse.statusCode,
                data: data,
                url: url,
                payloadKeys: debugPayloadKeys,
                payloadValues: debugPayloadValues
            )
            #endif
            throw CommunityPriceServiceError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: "Community price sync request failed."
            )
        }

        return data
    }

    private func roundedPrice(_ price: Double) -> Double {
        (price * 100).rounded() / 100
    }

    private static func limitedNote(from notes: String?) -> String? {
        guard let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmedNotes.isEmpty == false else {
            return nil
        }

        return String(trimmedNotes.prefix(maximumNoteLength))
    }

    private func isResponseBodyEmpty(_ data: Data) -> Bool {
        guard data.isEmpty == false else { return true }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty
    }

    private func decodeSingleOrArray<T: Decodable>(_ type: T.Type, from data: Data) throws -> T? {
        if let single = try? decoder.decode(T.self, from: data) {
            return single
        }

        if let array = try? decoder.decode([T].self, from: data) {
            return array.first
        }

        return nil
    }

    #if DEBUG
    private func logSupabaseFailure(
        functionName: String,
        method: String,
        statusCode: Int,
        data: Data,
        url: URL,
        payloadKeys: [String],
        payloadValues: [String: String]
    ) {
        let responseBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"
        let decodedError = try? decoder.decode(SupabaseErrorResponse.self, from: data)
        let endpoint = fullEndpointPath(from: url)
        let payloadKeysText = payloadKeys.isEmpty ? "[]" : payloadKeys.joined(separator: ", ")
        let payloadValuesText = payloadValues.isEmpty
            ? "[:]"
            : payloadValues
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")

        print(
            """
            Supabase request failed
            - function: \(functionName)
            - method: \(method)
            - endpoint: \(endpoint)
            - status: \(statusCode)
            - body: \(responseBody)
            - payload keys: \(payloadKeysText)
            - payload values: \(payloadValuesText)
            - decoded message: \(decodedError?.message ?? "n/a")
            - decoded error: \(decodedError?.error ?? "n/a")
            - decoded details: \(decodedError?.details ?? "n/a")
            - decoded hint: \(decodedError?.hint ?? "n/a")
            - decoded code: \(decodedError?.code ?? "n/a")
            """
        )
    }

    private func fullEndpointPath(from url: URL) -> String {
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
           query.isEmpty == false {
            return "\(url.path)?\(query)"
        }
        return url.path
    }

    private func debugPayloadSummary(from data: Data) -> (keys: [String], values: [String: String]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return ([], [:])
        }

        if let dictionary = json as? [String: Any] {
            return sanitizedPayload(dictionary)
        }

        if let array = json as? [[String: Any]], let first = array.first {
            return sanitizedPayload(first)
        }

        return ([], [:])
    }

    private func sanitizedPayload(_ dictionary: [String: Any]) -> (keys: [String], values: [String: String]) {
        let keys = dictionary.keys.sorted()
        let values = Dictionary(
            uniqueKeysWithValues: dictionary.map { key, value in
                (key, sanitizedPayloadValue(value, for: key))
            }
        )
        return (keys, values)
    }

    private func sanitizedPayloadValue(_ value: Any, for key: String) -> String {
        if key == "anonymous_reporter_id", let reporterID = value as? String {
            return maskedReporterID(reporterID)
        }

        if let string = value as? String {
            return string
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        if value is NSNull {
            return "null"
        }

        return String(describing: value)
    }

    private func maskedReporterID(_ reporterID: String) -> String {
        guard reporterID.count > 8 else { return "***" }
        let prefix = reporterID.prefix(4)
        let suffix = reporterID.suffix(4)
        return "\(prefix)...\(suffix)"
    }
    #endif
}

private struct CommunityStationPayload: Encodable {
    let normalizedStationKey: String
    let name: String
    let streetAddress: String?
    let city: String?
    let state: String?
    let zip: String?
    let latitude: Double?
    let longitude: Double?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case normalizedStationKey = "normalized_key"
        case name
        case streetAddress = "address"
        case city
        case state
        case zip
        case latitude
        case longitude
        case updatedAt = "updated_at"
    }
}

private struct CommunityPriceReportPayload: Encodable {
    let stationID: UUID?
    let price: Double
    let reportedAt: Date
    let reporterID: String
    let note: String?
    let appVersion: String?
    /// 2.4.1 (Phase 3C): nil is omitted from the JSON (synthesized Encodable), exactly like `note` and
    /// `appVersion`, so a request that names no payment type is identical to what an older app sends.
    let paymentType: CommunityPaymentType?

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case price
        case reportedAt = "reported_at"
        case reporterID = "anonymous_reporter_id"
        case note
        case appVersion = "app_version"
        case paymentType = "payment_type"
    }
}

private struct CommunityEthanolReportPayload: Encodable {
    let stationID: UUID
    let ethanolPercentage: Double
    let reportedAt: Date
    let reporterID: String
    let note: String?
    let appVersion: String?

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case ethanolPercentage = "ethanol_percentage"
        case reportedAt = "reported_at"
        case reporterID = "anonymous_reporter_id"
        case note
        case appVersion = "app_version"
    }
}

private struct SupabaseErrorResponse: Decodable {
    let message: String?
    let error: String?
    let details: String?
    let hint: String?
    let code: String?
}

private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ wrapped: some Encodable) {
        self.encodeClosure = wrapped.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
