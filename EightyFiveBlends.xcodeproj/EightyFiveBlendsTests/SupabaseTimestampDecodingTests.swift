//
//  SupabaseTimestampDecodingTests.swift
//  EightyFiveBlendsTests
//
//  The Supabase timestamp decoding contract. PostgREST returns server-defaulted columns such as
//  created_at with fractional seconds and client-written columns without. Both must decode to the
//  right instant, a bad value must fail the decode, and CommunityPriceService must use that
//  decoder when it reads, submits and upserts. No test here reaches the network.
//

import Foundation
import Testing
@testable import EightyFiveBlends

// MARK: - Decoder contract

struct SupabaseTimestampDecodingTests {
    private struct Stamp: Decodable { let at: Date }

    private static func decode(_ raw: String) throws -> Date {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SupabaseTimestamp.decodingStrategy
        return try decoder.decode(Stamp.self, from: Data("{\"at\":\"\(raw)\"}".utf8)).at
    }

    // Expected values are epoch seconds. The tolerance is two milliseconds because
    // ISO8601DateFormatter keeps millisecond precision at most.
    private static func isInstant(_ raw: String, _ expected: Double) throws -> Bool {
        abs(try decode(raw).timeIntervalSince1970 - expected) < 0.002
    }

    @Test(
        "A. Whole-second timestamps decode to the exact instant",
        arguments: [
            ("2026-10-02T20:30:46Z", 1_790_973_046.0),
            ("2026-10-02T20:30:46+00:00", 1_790_973_046.0),
        ]
    )
    func wholeSecond(_ pair: (String, Double)) throws {
        #expect(try Self.isInstant(pair.0, pair.1), "\(pair.0)")
    }

    @Test(
        "B. Fractional-second timestamps decode",
        arguments: [
            ("2026-10-02T20:30:46.1Z", 1_790_973_046.1),
            ("2026-10-02T20:30:46.123Z", 1_790_973_046.123),
        ]
    )
    func fractionalSecond(_ pair: (String, Double)) throws {
        #expect(try Self.isInstant(pair.0, pair.1), "\(pair.0)")
    }

    @Test(
        "C. Microsecond timestamps as Postgres emits them decode, including trimmed trailing zeros",
        arguments: [
            ("2026-10-02T20:30:46.123456+00:00", 1_790_973_046.123456),
            ("2026-10-02T20:30:46.123456Z", 1_790_973_046.123456),
            ("2026-10-02T20:30:46.12345+00:00", 1_790_973_046.12345),
        ]
    )
    func microsecond(_ pair: (String, Double)) throws {
        #expect(try Self.isInstant(pair.0, pair.1), "\(pair.0)")
    }

    @Test(
        "D. Numeric timezone offsets are applied",
        arguments: [
            ("2026-10-02T13:30:46.123456-07:00", 1_790_973_046.123456),
            ("2026-10-03T02:00:46+05:30", 1_790_973_046.0),
        ]
    )
    func numericOffset(_ pair: (String, Double)) throws {
        #expect(try Self.isInstant(pair.0, pair.1), "\(pair.0)")
    }

    @Test(
        "E. Invalid timestamps fail the decode instead of becoming a date",
        arguments: ["", "not-a-date", "2026-10-02", "1790973046"]
    )
    func invalid(_ raw: String) {
        #expect(throws: DecodingError.self) { _ = try Self.decode(raw) }
    }
}

// MARK: - CommunityPriceService with a stubbed network

final class SupabaseTimestampMockURLProtocol: URLProtocol {
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

/// A community_stations row as PostgREST returns it: created_at is server-defaulted (microseconds,
/// numeric offset) and updated_at was written by the client, so it has no fraction.
nonisolated private func stationRowJSON(id: UUID) -> String {
    """
    {"id":"\(id.uuidString)","normalized_key":"test-key","name":"Test Station","address":"1 Test St","city":"Testville","state":"CO","zip":"80000","latitude":39.0,"longitude":-104.0,"created_at":"2026-09-18T00:09:54.123456+00:00","updated_at":"2026-09-18T00:09:54+00:00"}
    """
}

/// An e85_price_reports row: reported_at was written by the client, created_at is server-defaulted.
nonisolated private func priceReportRowJSON(id: UUID, stationID: UUID) -> String {
    """
    {"id":"\(id.uuidString)","station_id":"\(stationID.uuidString)","price":3.499,"reported_at":"2026-10-02T20:30:45+00:00","anonymous_reporter_id":"test-reporter","app_version":"2.4.1","note":null,"created_at":"2026-10-02T20:30:46.482913+00:00"}
    """
}

@Suite(.serialized)
@MainActor
struct CommunityPriceServiceTimestampTests {
    private func makeService(
        _ handler: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) throws -> CommunityPriceService {
        SupabaseTimestampMockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SupabaseTimestampMockURLProtocol.self]
        return try CommunityPriceService(session: URLSession(configuration: configuration))
    }

    @Test("F. fetchLatestPrice reads a realistic PostgREST payload with a fractional created_at")
    func fetchLatestPrice() async throws {
        let stationID = UUID()
        let reportID = UUID()
        let service = try makeService { request in
            let path = request.url?.path ?? ""
            if path.contains("community_stations") { return (200, Data("[\(stationRowJSON(id: stationID))]".utf8)) }
            if path.contains("e85_price_reports") {
                return (200, Data("[\(priceReportRowJSON(id: reportID, stationID: stationID))]".utf8))
            }
            return (500, Data())
        }

        let summary = try #require(try await service.fetchLatestPrice(forNormalizedStationKey: "test-key"))
        let report = try #require(summary.latestReport)

        #expect(report.id == reportID)
        #expect(report.price == 3.499)
        #expect(abs(report.reportedAt.timeIntervalSince1970 - 1_790_973_045.0) < 0.002)
        #expect(abs(try #require(report.createdAt).timeIntervalSince1970 - 1_790_973_046.482913) < 0.002)
    }

    @Test("G. submitPriceReport accepts the inserted row when created_at has microseconds")
    func submitPriceReport() async throws {
        let stationID = UUID()
        let reportID = UUID()
        let service = try makeService { request in
            guard request.httpMethod == "POST", request.url?.path.contains("e85_price_reports") == true else {
                return (500, Data())
            }
            return (201, Data("[\(priceReportRowJSON(id: reportID, stationID: stationID))]".utf8))
        }

        // An undecodable representation is reported as invalidResponse even though the row was
        // inserted; an empty body would return a report with no id, so the id proves the decode.
        let report = try await service.submitPriceReport(
            normalizedStationKey: "test-key",
            stationID: stationID,
            price: 3.499
        )

        #expect(report.id == reportID)
        #expect(abs(try #require(report.createdAt).timeIntervalSince1970 - 1_790_973_046.482913) < 0.002)
    }

    @Test("H. upsertCommunityStation accepts the created row when created_at has microseconds")
    func upsertCommunityStation() async throws {
        let stationID = UUID()
        let service = try makeService { request in
            guard request.url?.path.contains("community_stations") == true else { return (500, Data()) }
            // Every GET finds nothing, so an undecodable POST response would end in
            // stationLookupFailed instead of returning the station.
            if request.httpMethod == "GET" { return (200, Data("[]".utf8)) }
            return (201, Data("[\(stationRowJSON(id: stationID))]".utf8))
        }

        let station = try await service.upsertCommunityStation(
            normalizedStationKey: "test-key", name: "Test Station", streetAddress: "1 Test St",
            city: "Testville", state: "CO", zip: "80000", latitude: 39.0, longitude: -104.0
        )

        #expect(station.id == stationID)
        #expect(abs(try #require(station.createdAt).timeIntervalSince1970 - 1_789_690_194.123456) < 0.002)
    }
}
