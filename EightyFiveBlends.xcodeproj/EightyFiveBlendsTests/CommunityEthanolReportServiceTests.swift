//
//  CommunityEthanolReportServiceTests.swift
//  EightyFiveBlendsTests
//
//  Exercises CommunityPriceService's real ethanol REST path through a private URLProtocol
//  harness. No request in this suite reaches the network or a live Supabase project.
//

import Foundation
import Testing
@testable import EightyFiveBlends

final class EthanolMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func makeEthanolMockedService() throws -> CommunityPriceService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [EthanolMockURLProtocol.self]
    return try CommunityPriceService(session: URLSession(configuration: configuration))
}

nonisolated private func ethanolStationArrayJSON(id: UUID, normalizedKey: String) -> Data {
    """
    [{"id":"\(id.uuidString)","normalized_key":"\(normalizedKey)","name":"Test Station","address":"1 Test St","city":"Testville","state":"CO","zip":"80000","latitude":39.0,"longitude":-104.0,"created_at":"2026-09-16T07:00:00Z","updated_at":"2026-09-16T07:00:00Z"}]
    """.data(using: .utf8)!
}

nonisolated private func ethanolReportJSON(
    id: UUID,
    stationID: UUID,
    percentage: Double,
    reporterID: String = "test-reporter"
) -> Data {
    """
    {"id":"\(id.uuidString)","station_id":"\(stationID.uuidString)","ethanol_percentage":\(percentage),"reported_at":"2026-09-16T07:00:00Z","anonymous_reporter_id":"\(reporterID)","note":"Pump sticker","created_at":"2026-09-16T07:00:01Z"}
    """.data(using: .utf8)!
}

nonisolated private func isEthanolStationRequest(_ request: URLRequest) -> Bool {
    request.url?.path.contains("community_stations") == true
}

nonisolated private func isEthanolReportRequest(_ request: URLRequest) -> Bool {
    request.url?.path.contains("e85_ethanol_reports") == true
}

@Suite(.serialized)
@MainActor
struct CommunityEthanolReportServiceTests {
    @Test("fetchLatestEthanolReport requests the latest report for the resolved station")
    func fetchLatestReport_usesResolvedStationAndLatestOrder() async throws {
        let stationID = UUID()
        let reportID = UUID()
        let normalizedKey = "shell|1 test st|testville|co|80000"

        EthanolMockURLProtocol.requestHandler = { request in
            if isEthanolStationRequest(request) {
                return (200, ethanolStationArrayJSON(id: stationID, normalizedKey: normalizedKey))
            }
            if isEthanolReportRequest(request) {
                let queryItems = URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []
                let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
                #expect(request.httpMethod == "GET")
                #expect(query["station_id"] == "eq.\(stationID.uuidString)")
                #expect(query["order"] == "reported_at.desc,created_at.desc")
                #expect(query["limit"] == "1")
                #expect(query["select"]?.contains("ethanol_percentage") == true)
                let object = String(
                    data: ethanolReportJSON(id: reportID, stationID: stationID, percentage: 78.5),
                    encoding: .utf8
                )!
                return (200, "[\(object)]".data(using: .utf8)!)
            }
            Issue.record("Unexpected request to \(request.url?.absoluteString ?? "nil")")
            return (500, Data())
        }

        let service = try makeEthanolMockedService()
        let summary = try await service.fetchLatestEthanolReport(
            forNormalizedStationKey: "  \(normalizedKey)  "
        )

        #expect(summary?.normalizedStationKey == normalizedKey)
        #expect(summary?.latestReport?.id == reportID)
        #expect(summary?.latestPercentage == 78.5)
        #expect(summary?.reportCount == 1)
    }

    @Test("fetchLatestEthanolReport returns nil for a blank station key without a request")
    func fetchLatestReport_blankKeyDoesNotRequest() async throws {
        EthanolMockURLProtocol.requestHandler = { request in
            Issue.record("Blank input must not make a request to \(request.url?.absoluteString ?? "nil")")
            return (500, Data())
        }

        let service = try makeEthanolMockedService()
        let summary = try await service.fetchLatestEthanolReport(
            forNormalizedStationKey: "  \n  "
        )

        #expect(summary == nil)
    }

    @Test("submitEthanolReport sends the separate table payload and normalizes precision")
    func submitReport_sendsExpectedPayload() async throws {
        let stationID = UUID()
        let reportID = UUID()

        EthanolMockURLProtocol.requestHandler = { request in
            guard isEthanolReportRequest(request), request.httpMethod == "POST" else {
                Issue.record("Unexpected request to \(request.url?.absoluteString ?? "nil")")
                return (500, Data())
            }
            #expect(request.value(forHTTPHeaderField: "Prefer") == "return=representation")
            let body = try #require(request.httpBody)
            let json = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            #expect(json["station_id"] as? String == stationID.uuidString)
            #expect((json["ethanol_percentage"] as? NSNumber)?.doubleValue == 78.5)
            #expect(json["note"] as? String == "Pump sticker")
            #expect(json["app_version"] as? String == "2.4.0")
            #expect((json["anonymous_reporter_id"] as? String)?.isEmpty == false)
            return (
                201,
                ethanolReportJSON(id: reportID, stationID: stationID, percentage: 78.5)
            )
        }

        let service = try makeEthanolMockedService()
        let report = try await service.submitEthanolReport(
            normalizedStationKey: "station-key",
            stationID: stationID,
            ethanolPercentage: 78.54,
            notes: "  Pump sticker  ",
            appVersion: " 2.4.0 "
        )

        #expect(report.id == reportID)
        #expect(report.stationID == stationID)
        #expect(report.ethanolPercentage == 78.5)
    }

    @Test("submitEthanolReport reuses station resolution when no station id is supplied")
    func submitReport_resolvesStationID() async throws {
        let stationID = UUID()
        let reportID = UUID()
        let normalizedKey = "resolved-station-key"

        EthanolMockURLProtocol.requestHandler = { request in
            if isEthanolStationRequest(request) {
                return (200, ethanolStationArrayJSON(id: stationID, normalizedKey: normalizedKey))
            }
            if isEthanolReportRequest(request), request.httpMethod == "POST" {
                let body = try #require(request.httpBody)
                let json = try #require(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                #expect(json["station_id"] as? String == stationID.uuidString)
                return (
                    201,
                    ethanolReportJSON(id: reportID, stationID: stationID, percentage: 70)
                )
            }
            Issue.record("Unexpected request to \(request.url?.absoluteString ?? "nil")")
            return (500, Data())
        }

        let service = try makeEthanolMockedService()
        let report = try await service.submitEthanolReport(
            normalizedStationKey: normalizedKey,
            ethanolPercentage: 70
        )

        #expect(report.stationID == stationID)
    }

    @Test("submitEthanolReport returns a local representation when PostgREST returns an empty body")
    func submitReport_emptyResponseUsesLocalRepresentation() async throws {
        let stationID = UUID()
        let reportedAt = Date(timeIntervalSince1970: 1_789_560_000)

        EthanolMockURLProtocol.requestHandler = { request in
            guard isEthanolReportRequest(request), request.httpMethod == "POST" else {
                Issue.record("Unexpected request")
                return (500, Data())
            }
            return (201, Data())
        }

        let service = try makeEthanolMockedService()
        let report = try await service.submitEthanolReport(
            normalizedStationKey: "station-key",
            stationID: stationID,
            ethanolPercentage: 83.14,
            reportedAt: reportedAt,
            notes: "  Pump sticker  "
        )

        #expect(report.id == nil)
        #expect(report.stationID == stationID)
        #expect(report.ethanolPercentage == 83.1)
        #expect(report.reportedAt == reportedAt)
        #expect(report.notes == "Pump sticker")
        #expect(report.createdAt == nil)
    }

    @Test("submitEthanolReport surfaces a non-success HTTP response")
    func submitReport_failedResponseThrows() async throws {
        let stationID = UUID()
        EthanolMockURLProtocol.requestHandler = { request in
            guard isEthanolReportRequest(request) else {
                Issue.record("Unexpected request")
                return (500, Data())
            }
            return (403, #"{"message":"permission denied"}"#.data(using: .utf8)!)
        }

        let service = try makeEthanolMockedService()
        await #expect(throws: CommunityPriceServiceError.self) {
            _ = try await service.submitEthanolReport(
                normalizedStationKey: "station-key",
                stationID: stationID,
                ethanolPercentage: 70
            )
        }
    }
}
