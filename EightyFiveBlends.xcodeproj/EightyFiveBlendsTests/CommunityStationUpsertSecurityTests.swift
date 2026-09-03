//
//  CommunityStationUpsertSecurityTests.swift
//  EightyFiveBlendsTests
//
//  Regression coverage for fix/2.3.2-community-station-upsert-security. A production Supabase
//  audit found that CommunityPriceService.upsertCommunityStation's original
//  `Prefer: resolution=merge-duplicates` header made PostgREST generate
//  `INSERT ... ON CONFLICT (normalized_key) DO UPDATE ...`, which requires UPDATE privilege on
//  community_stations regardless of whether a conflict actually occurs. The interim production
//  fix (granting anon/authenticated column-scoped UPDATE + a permissive UPDATE policy) restored
//  the app, but let any anonymous API client directly edit any existing station's display/
//  location fields — unnecessary authority no legitimate 85Blends flow uses. This fix switches
//  the client to `Prefer: resolution=ignore-duplicates` (`INSERT ... ON CONFLICT DO NOTHING`,
//  which needs only INSERT) so the anon UPDATE grant/policy can be safely revoked in production.
//
//  These tests exercise CommunityPriceService's real network code (not a reimplementation) via
//  an injected MockURLProtocol, so no real network call is ever made and no request reaches
//  Supabase. Per CLAUDE.md, this repository has no wired test target yet — these are written to
//  compile and pass once one exists, matching every other file in this directory.
//
//  A note specific to this file: CommunityPriceService.init() calls SupabaseConfig.load(), which
//  reads SUPABASE_URL/SUPABASE_ANON_KEY from Bundle.main's Info dictionary. That resolves
//  correctly when the eventual test target hosts inside the app target — Xcode's default for a
//  new "Unit Testing Bundle" — which every other test file in this directory that exercises
//  production types already assumes (see e.g. CommunityPriceEligibilityTests.swift's own header).
//  These tests make the same assumption; they do not stub SupabaseConfig itself.
//
//  Concurrency note: MockURLProtocol.startLoading() overrides a `nonisolated` Foundation method
//  and is invoked by the URL Loading System off the main actor, while each test (running under
//  this codebase's project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) sets up its handler
//  from @MainActor context. So that no request-handler closure ever needs to mutate a captured
//  `var` across that isolation boundary (a real data-race-safety compile risk with no compiler
//  available here to check), every test that needs to record call counts/flags across multiple
//  intercepted requests does so through TestCallTracker below -- an `@unchecked Sendable` class
//  with its own internal lock -- captured as an immutable `let`, never a mutated local `var`.
//

import Testing
import Foundation
@testable import EightyFiveBlends

// MARK: - Mock URLProtocol harness

/// Records call counts/flags across multiple MockURLProtocol invocations, safely, without any
/// request-handler closure needing to mutate a captured local `var`. See the file-level
/// concurrency note above for why that distinction matters here.
private final class TestCallTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var flags: Set<String> = []

    @discardableResult
    func increment(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let next = (counts[key] ?? 0) + 1
        counts[key] = next
        return next
    }

    func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[key] ?? 0
    }

    func setFlag(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        flags.insert(key)
    }

    func hasFlag(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return flags.contains(key)
    }
}

/// Intercepts every request made through a URLSession configured with this protocol class, so
/// CommunityPriceService's real `performRequestData`/`performRequest` code runs against a
/// canned response instead of the network. `requestHandler` is manually lock-protected (not a
/// plain stored `static var`) since it is written from @MainActor test code and read from
/// `startLoading()`'s nonisolated context; the suite below is additionally marked `.serialized`
/// so tests never race each other for the single shared handler slot.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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
            let (statusCode, data) = try handler(request)
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
}

private func makeMockedService() throws -> CommunityPriceService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return try CommunityPriceService(session: URLSession(configuration: configuration))
}

/// A minimal, real-shape Supabase REST response body for one community_stations row — matches
/// the actual production column names (normalized_key, address, created_at, updated_at), not an
/// idealized/simplified stand-in.
private func stationJSON(id: UUID, normalizedKey: String, name: String = "Test Station") -> Data {
    """
    {"id":"\(id.uuidString)","normalized_key":"\(normalizedKey)","name":"\(name)","address":"1 Test St","city":"Testville","state":"CO","zip":"80000","latitude":39.0,"longitude":-104.0,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
    """.data(using: .utf8)!
}

private func reportJSON(id: UUID, stationID: UUID, price: Double, reporterID: String) -> Data {
    """
    {"id":"\(id.uuidString)","station_id":"\(stationID.uuidString)","price":\(price),"reported_at":"2026-01-01T00:00:00Z","anonymous_reporter_id":"\(reporterID)","created_at":"2026-01-01T00:00:00Z"}
    """.data(using: .utf8)!
}

private let emptyArrayJSON = "[]".data(using: .utf8)!

/// Distinguishes the two REST endpoints this service calls, and (for community_stations) GET
/// vs. POST, without depending on exact query-string formatting.
private func isCommunityStationsRequest(_ request: URLRequest) -> Bool {
    request.url?.path.contains("community_stations") == true
}

private func isPriceReportsRequest(_ request: URLRequest) -> Bool {
    request.url?.path.contains("e85_price_reports") == true
}

@Suite(.serialized)
@MainActor
struct CommunityStationUpsertSecurityTests {
    // MARK: - 1. New station: INSERT succeeds, returned ID is used

    @Test("upsertCommunityStation: brand-new normalized_key inserts and returns the new station's id")
    func newStation_insertSucceeds_idIsUsed() async throws {
        let stationID = UUID()
        let key = "shell|1 test st|testville|co|80000"

        MockURLProtocol.requestHandler = { request in
            guard isCommunityStationsRequest(request) else {
                Issue.record("Unexpected request to \(request.url?.absoluteString ?? "nil")")
                return (500, Data())
            }
            switch request.httpMethod {
            case "GET":
                return (200, emptyArrayJSON) // existence check finds nothing yet
            case "POST":
                #expect(request.value(forHTTPHeaderField: "Prefer")?.contains("resolution=ignore-duplicates") == true)
                #expect(request.value(forHTTPHeaderField: "Prefer")?.contains("merge-duplicates") != true)
                return (201, stationJSON(id: stationID, normalizedKey: key))
            default:
                Issue.record("Unexpected method \(request.httpMethod ?? "nil") for community_stations")
                return (500, Data())
            }
        }

        let service = try makeMockedService()
        let station = try await service.upsertCommunityStation(
            normalizedStationKey: key, name: "Shell", streetAddress: "1 Test St",
            city: "Testville", state: "CO", zip: "80000", latitude: 39.0, longitude: -104.0
        )

        #expect(station.id == stationID)
        #expect(station.normalizedStationKey == key)
    }

    // MARK: - 2a. Duplicate station, common case: already known before the call, no POST at all

    @Test("upsertCommunityStation: pre-existing normalized_key is returned by the existence check, never POSTed")
    func duplicateStation_alreadyKnown_returnsWithoutPosting() async throws {
        let stationID = UUID()
        let key = "76|443 divisadero st|san francisco|ca|94117"
        let tracker = TestCallTracker()

        MockURLProtocol.requestHandler = { request in
            guard isCommunityStationsRequest(request) else {
                Issue.record("Unexpected request to \(request.url?.absoluteString ?? "nil")")
                return (500, Data())
            }
            if request.httpMethod == "POST" { tracker.setFlag("post") }
            // Existence check (and, if ever reached, any POST) both find the row already there.
            return (200, stationJSON(id: stationID, normalizedKey: key))
        }

        let service = try makeMockedService()
        let station = try await service.upsertCommunityStation(
            normalizedStationKey: key, name: "76", streetAddress: nil,
            city: nil, state: nil, zip: nil, latitude: nil, longitude: nil
        )

        #expect(station.id == stationID)
        #expect(tracker.hasFlag("post") == false, "an already-known station must never reach the upsert POST at all")
    }

    // MARK: - 2b. Duplicate station, genuine race: initial check misses, POST conflicts, resolved by re-fetch

    @Test("upsertCommunityStation: a genuine insert race resolves via DO NOTHING + re-fetch, never edits the winner's row")
    func duplicateStation_race_resolvesViaRefetch_withoutEditing() async throws {
        let stationID = UUID()
        let key = "audit-race-key"
        let tracker = TestCallTracker()

        MockURLProtocol.requestHandler = { request in
            guard isCommunityStationsRequest(request) else {
                Issue.record("Unexpected request to \(request.url?.absoluteString ?? "nil")")
                return (500, Data())
            }
            switch request.httpMethod {
            case "GET" where tracker.hasFlag("post") == false:
                // First existence check: this client hasn't seen the row yet.
                return (200, emptyArrayJSON)
            case "POST":
                tracker.setFlag("post")
                // Another client won the race: DO NOTHING skips our row -> PostgREST returns
                // 201 with an empty array, never an error and never our fields applied.
                #expect(request.value(forHTTPHeaderField: "Prefer")?.contains("ignore-duplicates") == true)
                return (201, emptyArrayJSON)
            case "GET":
                // Fallback re-fetch after the empty POST response: the winner's row is now visible.
                return (200, stationJSON(id: stationID, normalizedKey: key, name: "Winner's Name"))
            default:
                Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
                return (500, Data())
            }
        }

        let service = try makeMockedService()
        let station = try await service.upsertCommunityStation(
            normalizedStationKey: key, name: "My Submitted Name", streetAddress: nil,
            city: nil, state: nil, zip: nil, latitude: nil, longitude: nil
        )

        #expect(tracker.hasFlag("post"), "the POST must actually have been attempted for this to be a real race test")
        #expect(station.id == stationID)
        // The winner's row content is what comes back, never overwritten with this call's
        // submitted (losing) name -- proving no UPDATE ever occurred.
        #expect(station.name == "Winner's Name")
    }

    // MARK: - 3. Price report uses the resolved station id

    @Test("submitPriceReport: resolves a new station then submits the report against its id")
    func priceReport_usesResolvedStationID() async throws {
        let stationID = UUID()
        let reportID = UUID()
        let key = "audit-price-report-key"
        let tracker = TestCallTracker()

        MockURLProtocol.requestHandler = { request in
            if isCommunityStationsRequest(request) {
                switch request.httpMethod {
                case "GET": return (200, emptyArrayJSON)
                case "POST": return (201, stationJSON(id: stationID, normalizedKey: key))
                default:
                    Issue.record("Unexpected method for community_stations")
                    return (500, Data())
                }
            }
            if isPriceReportsRequest(request), request.httpMethod == "POST" {
                if let body = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let capturedStationID = json["station_id"] as? String {
                    tracker.setFlag("capturedStationID=\(capturedStationID)")
                }
                return (201, reportJSON(id: reportID, stationID: stationID, price: 3.29, reporterID: "test-reporter"))
            }
            Issue.record("Unexpected request to \(request.url?.absoluteString ?? "nil")")
            return (500, Data())
        }

        let service = try makeMockedService()
        let report = try await service.submitPriceReport(
            normalizedStationKey: key, price: 3.29, notes: nil
        )

        #expect(report.stationID == stationID)
        #expect(
            tracker.hasFlag("capturedStationID=\(stationID.uuidString)"),
            "the price-report request body must carry the resolved station id"
        )
    }

    // MARK: - 4. Failure cases

    @Test("upsertCommunityStation: a network failure with no existing row to fall back to is rethrown, not swallowed")
    func insertNetworkFailure_withNoFallbackRow_rethrows() async throws {
        let key = "audit-network-failure-key"
        let tracker = TestCallTracker()

        MockURLProtocol.requestHandler = { request in
            guard isCommunityStationsRequest(request) else {
                Issue.record("Unexpected request")
                return (500, Data())
            }
            let call = tracker.increment("get_or_post")
            switch request.httpMethod {
            case "GET" where call == 1:
                return (200, emptyArrayJSON) // initial existence check: nothing yet
            case "POST":
                throw URLError(.notConnectedToInternet)
            case "GET":
                return (200, emptyArrayJSON) // fallback re-fetch: still nothing (a real failure, not a race)
            default:
                Issue.record("Unexpected method")
                return (500, Data())
            }
        }

        let service = try makeMockedService()
        await #expect(throws: URLError.self) {
            _ = try await service.upsertCommunityStation(
                normalizedStationKey: key, name: "X", streetAddress: nil,
                city: nil, state: nil, zip: nil, latitude: nil, longitude: nil
            )
        }
    }

    @Test("upsertCommunityStation: duplicate (empty response) followed by a fallback SELECT failure surfaces that failure")
    func duplicateThenSelectFailure_surfacesError() async throws {
        let key = "audit-select-failure-key"
        let tracker = TestCallTracker()

        MockURLProtocol.requestHandler = { request in
            guard isCommunityStationsRequest(request) else {
                Issue.record("Unexpected request")
                return (500, Data())
            }
            let call = tracker.increment("get_or_post")
            switch (request.httpMethod, call) {
            case ("GET", 1): return (200, emptyArrayJSON)  // initial check: miss
            case ("POST", _): return (201, emptyArrayJSON) // conflict, DO NOTHING
            case ("GET", _): throw URLError(.timedOut)     // fallback SELECT itself fails
            default:
                Issue.record("Unexpected method")
                return (500, Data())
            }
        }

        let service = try makeMockedService()
        await #expect(throws: URLError.self) {
            _ = try await service.upsertCommunityStation(
                normalizedStationKey: key, name: "X", streetAddress: nil,
                city: nil, state: nil, zip: nil, latitude: nil, longitude: nil
            )
        }
    }

    @Test("upsertCommunityStation: a malformed (undecodable, non-empty) POST response falls back to a fetch by key")
    func malformedResponse_fallsBackToFetch() async throws {
        let stationID = UUID()
        let key = "audit-malformed-response-key"
        let tracker = TestCallTracker()

        MockURLProtocol.requestHandler = { request in
            guard isCommunityStationsRequest(request) else {
                Issue.record("Unexpected request")
                return (500, Data())
            }
            let call = tracker.increment("get_or_post")
            switch (request.httpMethod, call) {
            case ("GET", 1): return (200, emptyArrayJSON)
            case ("POST", _): return (201, "not json at all".data(using: .utf8)!)
            case ("GET", _): return (200, stationJSON(id: stationID, normalizedKey: key))
            default:
                Issue.record("Unexpected method")
                return (500, Data())
            }
        }

        let service = try makeMockedService()
        let station = try await service.upsertCommunityStation(
            normalizedStationKey: key, name: "X", streetAddress: nil,
            city: nil, state: nil, zip: nil, latitude: nil, longitude: nil
        )
        #expect(station.id == stationID)
    }

    @Test("upsertCommunityStation: a conflict whose row is missing on re-fetch throws stationLookupFailed, not a crash")
    func missingRowAfterConflict_throwsStationLookupFailed() async throws {
        let key = "audit-missing-after-conflict-key"
        let tracker = TestCallTracker()

        MockURLProtocol.requestHandler = { request in
            guard isCommunityStationsRequest(request) else {
                Issue.record("Unexpected request")
                return (500, Data())
            }
            let call = tracker.increment("get_or_post")
            switch (request.httpMethod, call) {
            case ("GET", 1): return (200, emptyArrayJSON)
            case ("POST", _): return (201, emptyArrayJSON) // conflicted, DO NOTHING
            case ("GET", _): return (200, emptyArrayJSON)  // fallback SELECT: genuinely not found either
            default:
                Issue.record("Unexpected method")
                return (500, Data())
            }
        }

        let service = try makeMockedService()
        await #expect(throws: CommunityPriceServiceError.self) {
            _ = try await service.upsertCommunityStation(
                normalizedStationKey: key, name: "X", streetAddress: nil,
                city: nil, state: nil, zip: nil, latitude: nil, longitude: nil
            )
        }
    }

    // MARK: - 5. No hidden retry loop

    @Test("upsertCommunityStation: exactly one fallback fetch is attempted, never a retry loop, when the POST fails")
    func onlyOneFallbackFetch_noRetryLoop() async throws {
        let key = "audit-no-retry-loop-key"
        let tracker = TestCallTracker()

        MockURLProtocol.requestHandler = { request in
            guard isCommunityStationsRequest(request) else {
                Issue.record("Unexpected request")
                return (500, Data())
            }
            switch request.httpMethod {
            case "GET":
                tracker.increment("get")
                return (200, emptyArrayJSON)
            case "POST":
                tracker.increment("post")
                throw URLError(.networkConnectionLost)
            default:
                Issue.record("Unexpected method")
                return (500, Data())
            }
        }

        let service = try makeMockedService()
        await #expect(throws: URLError.self) {
            _ = try await service.upsertCommunityStation(
                normalizedStationKey: key, name: "X", streetAddress: nil,
                city: nil, state: nil, zip: nil, latitude: nil, longitude: nil
            )
        }

        // 1 initial existence GET + 1 POST attempt + 1 fallback GET after the POST throws --
        // never more. A retry loop would inflate either count beyond this.
        #expect(tracker.count("post") == 1)
        #expect(tracker.count("get") == 2)
    }
}
