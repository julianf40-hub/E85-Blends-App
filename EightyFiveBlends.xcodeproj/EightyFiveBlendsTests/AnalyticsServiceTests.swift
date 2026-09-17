//
//  AnalyticsServiceTests.swift
//  EightyFiveBlendsTests
//
//  Exercises AnalyticsService's real REST path through a private URLProtocol harness — the
//  same technique CommunityEthanolReportServiceTests.swift already uses for
//  CommunityPriceService. No request in this suite reaches the network or a live Supabase
//  project.
//
//  `AnalyticsService.track(_:properties:now:)` — the only production call site any product code
//  uses — is deliberately synchronous, non-`async`, and non-`throws`: it has no way to surface a
//  failure to its caller even in principle, which is itself the structural guarantee that a
//  dropped analytics event can never affect product behavior. These tests instead exercise
//  `AnalyticsService.send(...)`, the underlying `async throws` call `track` wraps, since that is
//  the part with anything meaningful to assert on.
//

import Foundation
import Testing
@testable import EightyFiveBlends

final class AnalyticsMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var _requestHandler: (@Sendable (URLRequest) throws -> (Int, Data))?

    static var requestHandler: (@Sendable (URLRequest) throws -> (Int, Data))? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _requestHandler
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _requestHandler = newValue
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let materializedRequest = Self.requestWithMaterializedBody(request)
            let (statusCode, data) = try handler(materializedRequest)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    nonisolated private static func requestWithMaterializedBody(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        var materialized = request
        materialized.httpBody = data
        return materialized
    }
}

private func makeMockedAnalyticsService() throws -> AnalyticsService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AnalyticsMockURLProtocol.self]
    return try AnalyticsService(session: URLSession(configuration: configuration))
}

@Suite(.serialized)
struct AnalyticsServiceTests {
    @Test("send posts to the e85_analytics_events table")
    func send_usesCorrectTablePath() async throws {
        AnalyticsMockURLProtocol.requestHandler = { request in
            #expect(request.url?.path.contains("e85_analytics_events") == true)
            return (200, Data())
        }

        let service = try makeMockedAnalyticsService()
        try await service.send(
            eventName: .priceReportPromptShown,
            properties: AnalyticsEventProperties(entryPoint: .proximityPrompt),
            occurredAt: .now
        )
    }

    @Test("send sets the anon apikey/Authorization headers and a JSON POST")
    func send_setsExpectedHeaders() async throws {
        AnalyticsMockURLProtocol.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let apiKey = request.value(forHTTPHeaderField: "apikey")
            #expect(apiKey?.isEmpty == false)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey ?? "")")
            return (200, Data())
        }

        let service = try makeMockedAnalyticsService()
        try await service.send(
            eventName: .priceReportOpened,
            properties: AnalyticsEventProperties(),
            occurredAt: .now
        )
    }

    @Test("send encodes event_name, occurred_at, app_version, and contributor_id")
    func send_encodesRequiredTopLevelFields() async throws {
        let occurredAt = Date(timeIntervalSince1970: 1_800_000_000)

        AnalyticsMockURLProtocol.requestHandler = { request in
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["event_name"] as? String == "price_report_submitted")
            #expect(json["app_version"] as? String != nil)
            #expect((json["app_version"] as? String)?.isEmpty == false)
            #expect((json["contributor_id"] as? String)?.isEmpty == false)
            #expect(json["contributor_id"] as? String == CommunityPriceService.anonymousReporterID)
            #expect(json["occurred_at"] as? String != nil)
            return (200, Data())
        }

        let service = try makeMockedAnalyticsService()
        try await service.send(
            eventName: .priceReportSubmitted,
            properties: AnalyticsEventProperties(entryPoint: .proximityPrompt),
            occurredAt: occurredAt
        )
    }

    @Test("contributor_id's source value, anonymousReporterID, is always a syntactically valid UUID string")
    func anonymousReporterID_isAlwaysAValidUUIDString() {
        // CommunityPriceService.anonymousReporterID either returns a previously-persisted value
        // or generates one via UUID().uuidString and persists that — both paths are guaranteed
        // valid UUID text by construction, never a parsed/user-supplied string. This test
        // exists to catch a future edit to that accessor that could break the invariant this
        // wire payload's contributor_id field (asserted above) silently relies on.
        #expect(UUID(uuidString: CommunityPriceService.anonymousReporterID) != nil)
    }

    @Test("send encodes only the allowed properties keys — entry_point and failure_category, nothing else")
    func send_encodesOnlyAllowedPropertiesKeys() async throws {
        AnalyticsMockURLProtocol.requestHandler = { request in
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let properties = try #require(json["properties"] as? [String: Any])
            #expect(properties["entry_point"] as? String == "other")
            #expect(properties["failure_category"] as? String == "not_configured")
            let allowedKeys: Set<String> = ["station_source", "entry_point", "price_state", "failure_category"]
            #expect(Set(properties.keys).isSubset(of: allowedKeys))
            return (200, Data())
        }

        let service = try makeMockedAnalyticsService()
        try await service.send(
            eventName: .priceReportFailed,
            properties: AnalyticsEventProperties(
                entryPoint: .other,
                failureCategory: "not_configured"
            ),
            occurredAt: .now
        )
    }

    @Test("An all-nil properties value still encodes a JSON object, never null or an array")
    func send_allNilPropertiesEncodesEmptyObject() async throws {
        AnalyticsMockURLProtocol.requestHandler = { request in
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let properties = try #require(json["properties"] as? [String: Any])
            #expect(properties.isEmpty)
            return (200, Data())
        }

        let service = try makeMockedAnalyticsService()
        try await service.send(
            eventName: .priceReportOpened,
            properties: AnalyticsEventProperties(),
            occurredAt: .now
        )
    }

    @Test("The wire payload never includes a station identifier, station name, or coordinates")
    func send_neverLeaksStationIdentityOrLocation() async throws {
        AnalyticsMockURLProtocol.requestHandler = { request in
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let disallowedTopLevelKeys = ["station_id", "station_name", "latitude", "longitude", "address"]
            for key in disallowedTopLevelKeys {
                #expect(json[key] == nil)
            }
            if let properties = json["properties"] as? [String: Any] {
                for key in disallowedTopLevelKeys {
                    #expect(properties[key] == nil)
                }
            }
            return (200, Data())
        }

        let service = try makeMockedAnalyticsService()
        try await service.send(
            eventName: .priceReportPromptShown,
            properties: AnalyticsEventProperties(entryPoint: .proximityPrompt),
            occurredAt: .now
        )
    }

    @Test("send throws on a non-2xx response — the failure a caller could act on, if it chose to")
    func send_nonSuccessResponseThrows() async throws {
        AnalyticsMockURLProtocol.requestHandler = { _ in
            (500, Data())
        }

        let service = try makeMockedAnalyticsService()
        await #expect(throws: AnalyticsServiceError.self) {
            try await service.send(
                eventName: .priceReportFailed,
                properties: AnalyticsEventProperties(entryPoint: .proximityPrompt, failureCategory: "network_error"),
                occurredAt: .now
            )
        }
    }

    @Test("track(_:properties:) never throws and never blocks its caller, even when the request fails")
    func track_neverThrowsEvenOnFailure() async {
        AnalyticsMockURLProtocol.requestHandler = { _ in
            (500, Data())
        }

        // No `try`, no `await` on the network call itself — `track` is a plain, synchronous,
        // non-throwing call. This line compiling and returning at all (rather than requiring
        // any error handling) IS the test: a caller has no way to make its own behavior depend
        // on whether this analytics call ultimately succeeds.
        await MainActor.run {
            AnalyticsService.track(.priceReportPromptShown, properties: AnalyticsEventProperties(entryPoint: .proximityPrompt))
        }
    }
}
