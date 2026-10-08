//
//  CommunityPricePaymentServiceTests.swift
//  EightyFiveBlendsTests
//
//  Phase 3C — the real CommunityPriceService request shapes for payment types, through a private URLProtocol
//  harness (no request reaches the network or a live Supabase project):
//
//    * a report names its payment type only when the person chose one — `nil` and `.unknown` are OMITTED, so the
//      request is exactly what an older app sends and the server stores `unknown`;
//    * the price fetch selects `payment_type` and reads the newest few reports (newest first);
//    * a backend that has not been migrated yet (400 on the new column) degrades the FETCH to the legacy select —
//      community prices must not vanish because of deployment order — but never degrades a WRITE: a report is
//      not silently re-sent without the choice the person made.
//
//  The service is built with an explicit configuration (CommunityPriceService.init(config:session:)), so nothing
//  here depends on the host app's Info.plist.
//

import Foundation
import Testing
@testable import EightyFiveBlends

nonisolated final class PaymentMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    // Guarded by `lock`; nonisolated(unsafe) says so to the Swift 6 checker.
    nonisolated(unsafe) private static var _requestHandler: (@Sendable (URLRequest) throws -> (Int, Data))?

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
            let materialized = Self.requestWithMaterializedBody(request)
            let (statusCode, data) = try handler(materialized)
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
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
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

/// Counts requests from inside the @Sendable handler.
private nonisolated final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    func record(_ request: URLRequest) { lock.lock(); _requests.append(request); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func requests(path fragment: String, method: String) -> [URLRequest] {
        requests.filter { $0.url?.path.contains(fragment) == true && $0.httpMethod == method }
    }
}

nonisolated private let stationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

private func makeService() -> CommunityPriceService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PaymentMockURLProtocol.self]
    return CommunityPriceService(
        config: SupabaseConfig(url: URL(string: "https://example.invalid")!, anonKey: "test-anon-key"),
        session: URLSession(configuration: configuration)
    )
}

nonisolated private func stationJSON() -> Data {
    Data("""
    [{"id":"\(stationID.uuidString)","normalized_key":"shell|1 test st|testville|co|80000","name":"Test Station","address":"1 Test St","city":"Testville","state":"CO","zip":"80000","latitude":39.0,"longitude":-104.0,"created_at":"2026-09-16T07:00:00Z","updated_at":"2026-09-16T07:00:00Z"}]
    """.utf8)
}

nonisolated private func reportRow(price: Double, reportedAt: String, paymentType: String?) -> String {
    let field = paymentType.map { #","payment_type":"\#($0)""# } ?? ""
    return #"{"id":"\#(UUID().uuidString)","station_id":"\#(stationID.uuidString)","price":\#(price),"reported_at":"\#(reportedAt)","anonymous_reporter_id":"r","created_at":"\#(reportedAt)"\#(field)}"#
}

private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

nonisolated private func queryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    return components.queryItems?.first { $0.name == name }?.value
}

@Suite(.serialized)
@MainActor
struct CommunityPricePaymentServiceTests {
    // MARK: Submitting

    @Test("A report names its payment type — cash, credit or same_for_both — in the backend's spelling")
    func submit_sendsThePaymentType() async throws {
        for (type, wire) in [(CommunityPaymentType.cash, "cash"), (.credit, "credit"), (.sameForBoth, "same_for_both")] {
            let log = RequestLog()
            PaymentMockURLProtocol.requestHandler = { request in
                log.record(request)
                return (201, Data("[\(reportRow(price: 3.19, reportedAt: "2026-10-06T08:00:00Z", paymentType: wire))]".utf8))
            }

            let report = try await makeService().submitPriceReport(
                normalizedStationKey: "key", stationID: stationID, price: 3.19, paymentType: type
            )

            let post = try #require(log.requests(path: "e85_price_reports", method: "POST").first)
            let body = try bodyJSON(post)
            #expect(body["payment_type"] as? String == wire)
            #expect(body["price"] as? Double == 3.19)
            #expect(body["station_id"] as? String == stationID.uuidString)
            #expect(report.paymentType == type)
        }
    }

    @Test("With no payment type — or `unknown` — the field is OMITTED: the request is exactly what an older app sends")
    func submit_omitsAnAbsentPaymentType() async throws {
        for type in [nil, CommunityPaymentType.unknown] as [CommunityPaymentType?] {
            let log = RequestLog()
            PaymentMockURLProtocol.requestHandler = { request in
                log.record(request)
                return (201, Data("[\(reportRow(price: 3.19, reportedAt: "2026-10-06T08:00:00Z", paymentType: nil))]".utf8))
            }

            let report = try await makeService().submitPriceReport(
                normalizedStationKey: "key", stationID: stationID, price: 3.19, paymentType: type
            )

            let post = try #require(log.requests(path: "e85_price_reports", method: "POST").first)
            let body = try bodyJSON(post)
            #expect(body["payment_type"] == nil)
            #expect(Set(body.keys) == ["station_id", "price", "reported_at", "anonymous_reporter_id"])
            #expect(String(decoding: try #require(post.httpBody), as: UTF8.self).contains("payment_type") == false)
            #expect(report.paymentType == .unknown)
        }
    }

    @Test("An empty response body (return=minimal) still reports the type that was sent")
    func submit_emptyResponseEchoesTheSentType() async throws {
        PaymentMockURLProtocol.requestHandler = { _ in (201, Data()) }

        let credit = try await makeService().submitPriceReport(
            normalizedStationKey: "key", stationID: stationID, price: 3.19, paymentType: .credit
        )
        #expect(credit.paymentType == .credit)

        let legacy = try await makeService().submitPriceReport(
            normalizedStationKey: "key", stationID: stationID, price: 3.19
        )
        #expect(legacy.paymentType == .unknown)
    }

    @Test("A rejected report is NOT retried without its payment type — the person's choice is never silently dropped")
    func submit_failureIsNotRetriedWithoutTheField() async {
        let log = RequestLog()
        PaymentMockURLProtocol.requestHandler = { request in
            log.record(request)
            return (400, Data(#"{"code":"PGRST204","message":"Could not find the 'payment_type' column"}"#.utf8))
        }

        await #expect(throws: CommunityPriceServiceError.self) {
            _ = try await makeService().submitPriceReport(
                normalizedStationKey: "key", stationID: stationID, price: 3.19, paymentType: .cash
            )
        }
        #expect(log.requests(path: "e85_price_reports", method: "POST").count == 1)
    }

    // MARK: Fetching

    @Test("The fetch selects payment_type and reads the newest few reports, newest first")
    func fetch_requestShape() async throws {
        let log = RequestLog()
        PaymentMockURLProtocol.requestHandler = { request in
            log.record(request)
            if request.url?.path.contains("community_stations") == true { return (200, stationJSON()) }
            return (200, Data("[\(reportRow(price: 2.99, reportedAt: "2026-10-06T09:00:00Z", paymentType: "cash")),\(reportRow(price: 3.19, reportedAt: "2026-10-05T09:00:00Z", paymentType: "credit"))]".utf8))
        }

        let summary = try #require(try await makeService().fetchLatestPrice(forNormalizedStationKey: "shell|1 test st|testville|co|80000"))

        let get = try #require(log.requests(path: "e85_price_reports", method: "GET").first)
        let select = try #require(queryValue("select", in: get))
        #expect(select.contains("payment_type"))
        #expect(select.contains("price") && select.contains("reported_at"))
        #expect(queryValue("order", in: get) == "reported_at.desc,created_at.desc")
        #expect(queryValue("limit", in: get) == String(CommunityPriceService.recentReportWindow))
        // Wide enough to find the newest Cash AND the newest Credit AND an unclassified report from one request.
        #expect(CommunityPriceService.recentReportWindow >= 10)
        #expect(queryValue("station_id", in: get) == "eq.\(stationID.uuidString)")

        // `latest` keeps its meaning (the newest report of any type); the per-method prices come from the window.
        #expect(summary.latestPrice == 2.99)
        #expect(summary.recentReports.count == 2)
        #expect(summary.breakdown.lines.map { $0.kind } == [.cash, .credit])
        #expect(summary.communityStationID == stationID)
    }

    @Test("Rows from a backend without the column read as unclassified: the legacy presentation, unchanged")
    func fetch_rowsWithoutPaymentType() async throws {
        PaymentMockURLProtocol.requestHandler = { request in
            if request.url?.path.contains("community_stations") == true { return (200, stationJSON()) }
            return (200, Data("[\(reportRow(price: 3.19, reportedAt: "2026-10-06T09:00:00Z", paymentType: nil))]".utf8))
        }

        let summary = try #require(try await makeService().fetchLatestPrice(forNormalizedStationKey: "key"))

        #expect(summary.recentReports.allSatisfy { $0.paymentType == .unknown })
        #expect(summary.breakdown.hasTypedLines == false)
        #expect(CommunityPriceLinePresenter.typedLines(from: summary).isEmpty)
        #expect(summary.latestPrice == 3.19)
    }

    @Test("A backend that has not been migrated (400 on the new column) is read again WITHOUT it — prices do not vanish")
    func fetch_fallsBackOnAnUnmigratedBackend() async throws {
        let log = RequestLog()
        PaymentMockURLProtocol.requestHandler = { request in
            log.record(request)
            if request.url?.path.contains("community_stations") == true { return (200, stationJSON()) }
            if queryValue("select", in: request)?.contains("payment_type") == true {
                return (400, Data(#"{"code":"42703","message":"column e85_price_reports.payment_type does not exist"}"#.utf8))
            }
            return (200, Data("[\(reportRow(price: 3.19, reportedAt: "2026-10-06T09:00:00Z", paymentType: nil))]".utf8))
        }

        let summary = try #require(try await makeService().fetchLatestPrice(forNormalizedStationKey: "key"))

        let gets = log.requests(path: "e85_price_reports", method: "GET")
        #expect(gets.count == 2)
        #expect(queryValue("select", in: gets[0])?.contains("payment_type") == true)
        #expect(queryValue("select", in: gets[1])?.contains("payment_type") == false)
        #expect(summary.latestPrice == 3.19)
        #expect(summary.breakdown.hasTypedLines == false)
    }

    @Test("Only a 400 triggers that fallback: a server error is reported as before, not retried")
    func fetch_otherFailuresAreNotRetried() async {
        for status in [401, 403, 404, 429, 500, 503] {
            let log = RequestLog()
            PaymentMockURLProtocol.requestHandler = { request in
                log.record(request)
                if request.url?.path.contains("community_stations") == true { return (200, stationJSON()) }
                return (status, Data("{}".utf8))
            }

            await #expect(throws: CommunityPriceServiceError.self) {
                _ = try await makeService().fetchLatestPrice(forNormalizedStationKey: "key")
            }
            #expect(log.requests(path: "e85_price_reports", method: "GET").count == 1, "status \(status)")
        }
    }

    @Test("A station with no reports has no summary")
    func fetch_noReports() async throws {
        PaymentMockURLProtocol.requestHandler = { request in
            if request.url?.path.contains("community_stations") == true { return (200, stationJSON()) }
            return (200, Data("[]".utf8))
        }
        let summary = try await makeService().fetchLatestPrice(forNormalizedStationKey: "key")
        #expect(summary == nil)
    }
}
