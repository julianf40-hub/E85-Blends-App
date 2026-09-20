//
//  ReferralAPIServiceTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.0 — iOS referral client foundation. Tests for ReferralAPIService's actual HTTP
//  behavior — the request it builds (URL, headers) and how it classifies real HTTP-layer outcomes
//  (malformed body, network failure) — using CapturingURLProtocol below rather than a live
//  network call, the standard URLSession testing seam.
//

import Testing
import Foundation
@testable import EightyFiveBlends

/// Test-only `URLProtocol` that intercepts every request instead of touching the network,
/// capturing the last request it saw and returning a stubbed outcome. Registered on an
/// `.ephemeral` `URLSessionConfiguration` passed into `ReferralAPIService`'s injectable
/// `session:` initializer parameter — never the real shared/default session.
final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    enum StubbedResponse {
        case success(statusCode: Int, body: Data)
        case failure(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stubbedResponse: StubbedResponse = .success(statusCode: 200, body: Data())
    nonisolated(unsafe) private static var _lastRequest: URLRequest?
    nonisolated(unsafe) private static var _lastRequestBody: Data?

    static var stubbedResponse: StubbedResponse {
        get { lock.withLock { _stubbedResponse } }
        set { lock.withLock { _stubbedResponse = newValue } }
    }

    static var lastRequest: URLRequest? {
        lock.withLock { _lastRequest }
    }

    static var lastRequestBody: Data? {
        lock.withLock { _lastRequestBody }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self._lastRequest = request
            Self._lastRequestBody = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: bufferSize)
                    if read > 0 { data.append(buffer, count: read) }
                    else { break }
                }
                return data
            }
        }

        switch Self.stubbedResponse {
        case .success(let statusCode, let body):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

struct ReferralAPIServiceTests {
    private static func makeService() throws -> ReferralAPIService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        return try ReferralAPIService(session: URLSession(configuration: configuration))
    }

    private static func validStatusJSON() -> Data {
        """
        {"referral_code":"ABCD2345","qualified_referrals":0,"pending_referrals":0,
         "earned_months_available":0,"fulfilled_months":0,"next_milestone_number":1,
         "next_reward_at":5,"referrals_needed":5,"can_apply_referral_code":true,
         "referred_by_code":null,"referred_status":null}
        """.data(using: .utf8)!
    }

    // MARK: 12. Public Supabase key sent as apikey

    @Test("Every request sends the client-safe Supabase anon key as the apikey header")
    func request_sendsApiKeyHeader() async throws {
        let service = try Self.makeService()
        CapturingURLProtocol.stubbedResponse = .success(statusCode: 200, body: Self.validStatusJSON())

        _ = try await service.status(credential: .generate())

        let sentRequest = try #require(CapturingURLProtocol.lastRequest)
        let apiKeyHeader = try #require(sentRequest.value(forHTTPHeaderField: "apikey"))
        let config = try SupabaseConfig.load()
        #expect(apiKeyHeader == config.anonKey)
    }

    // MARK: 13. Correct referral-api URL

    @Test("Every request targets {SUPABASE_URL}/functions/v1/referral-api")
    func request_targetsCorrectURL() async throws {
        let service = try Self.makeService()
        CapturingURLProtocol.stubbedResponse = .success(statusCode: 200, body: Self.validStatusJSON())

        _ = try await service.status(credential: .generate())

        let sentRequest = try #require(CapturingURLProtocol.lastRequest)
        let config = try SupabaseConfig.load()
        let expected = config.url.appending(path: "functions").appending(path: "v1").appending(path: "referral-api")
        #expect(sentRequest.url == expected)
        #expect(sentRequest.httpMethod == "POST")
    }

    // MARK: 14. No service-role key anywhere

    @Test("No service-role-shaped credential is ever sent — only the client-safe anon key, on the one expected header")
    func request_neverSendsServiceRoleKey() async throws {
        let service = try Self.makeService()
        CapturingURLProtocol.stubbedResponse = .success(statusCode: 200, body: Self.validStatusJSON())

        _ = try await service.status(credential: .generate())

        let sentRequest = try #require(CapturingURLProtocol.lastRequest)
        // The app has no service-role credential anywhere to send (see SupabaseConfig.swift's own
        // "Key Safety Notes") — this asserts the request shape itself never grew a second
        // Authorization-style header a future edit might mistakenly add one to.
        #expect(sentRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sentRequest.allHTTPHeaderFields?.keys.contains { $0.lowercased().contains("service") } != true)
    }

    // MARK: 19-26 (service-layer half). Typed errors surface through the service for every status code.

    @Test("A non-2xx response with a recognized error body throws the matching typed ReferralAPIError")
    func errorResponse_mapsToTypedError() async throws {
        let service = try Self.makeService()
        CapturingURLProtocol.stubbedResponse = .success(
            statusCode: 404,
            body: #"{"error":"referral_code_not_found"}"#.data(using: .utf8)!
        )

        do {
            _ = try await service.status(credential: .generate())
            Issue.record("Expected status() to throw")
        } catch ReferralServiceError.api(.referralCodeNotFound) {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("rate_limited (429) maps to the typed rateLimited case")
    func rateLimited_mapsCorrectly() async throws {
        let service = try Self.makeService()
        CapturingURLProtocol.stubbedResponse = .success(
            statusCode: 429,
            body: #"{"error":"rate_limited"}"#.data(using: .utf8)!
        )

        do {
            _ = try await service.status(credential: .generate())
            Issue.record("Expected status() to throw")
        } catch ReferralServiceError.api(.rateLimited) {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("service_unavailable (503) maps to the typed serviceUnavailable case")
    func serviceUnavailable_mapsCorrectly() async throws {
        let service = try Self.makeService()
        CapturingURLProtocol.stubbedResponse = .success(
            statusCode: 503,
            body: #"{"error":"service_unavailable"}"#.data(using: .utf8)!
        )

        do {
            _ = try await service.status(credential: .generate())
            Issue.record("Expected status() to throw")
        } catch ReferralServiceError.api(.serviceUnavailable) {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("internal_error (500) maps to the typed internalError case")
    func internalError_mapsCorrectly() async throws {
        let service = try Self.makeService()
        CapturingURLProtocol.stubbedResponse = .success(
            statusCode: 500,
            body: #"{"error":"internal_error"}"#.data(using: .utf8)!
        )

        do {
            _ = try await service.status(credential: .generate())
            Issue.record("Expected status() to throw")
        } catch ReferralServiceError.api(.internalError) {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: 27. Malformed response

    @Test("A non-2xx response with an undecodable body throws invalidResponse, never a decoded garbage error")
    func malformedErrorBody_throwsInvalidResponse() async throws {
        let service = try Self.makeService()
        CapturingURLProtocol.stubbedResponse = .success(
            statusCode: 500,
            body: "not valid json at all".data(using: .utf8)!
        )

        do {
            _ = try await service.status(credential: .generate())
            Issue.record("Expected status() to throw")
        } catch ReferralServiceError.invalidResponse {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A 2xx response whose body doesn't match the expected shape throws .decoding")
    func malformedSuccessBody_throwsDecoding() async throws {
        let service = try Self.makeService()
        CapturingURLProtocol.stubbedResponse = .success(
            statusCode: 200,
            body: #"{"unexpected":"shape"}"#.data(using: .utf8)!
        )

        do {
            _ = try await service.status(credential: .generate())
            Issue.record("Expected status() to throw")
        } catch ReferralServiceError.decoding {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: 28. Network failure

    @Test("A transport-level failure (no connection) throws .network, distinct from decoding/API errors")
    func networkFailure_throwsNetworkError() async throws {
        let service = try Self.makeService()
        CapturingURLProtocol.stubbedResponse = .failure(.notConnectedToInternet)

        do {
            _ = try await service.status(credential: .generate())
            Issue.record("Expected status() to throw")
        } catch ReferralServiceError.network {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
