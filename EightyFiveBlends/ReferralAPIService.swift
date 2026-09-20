//
//  ReferralAPIService.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — iOS referral client foundation. The ONLY client path to
//  supabase/functions/referral-api — the app never talks to any private.referral_* table/function
//  directly; none of them are reachable from the client at all (see that function's own header).
//  Mirrors CommunityPriceService's established networking pattern (injectable URLSession,
//  SupabaseConfig-sourced client-safe key, throwing init on missing configuration) — not a new
//  networking architecture.
//
//  NEVER logs installationSecret or the RevenueCat App User ID — this file has no debug-logging
//  path at all (unlike CommunityPriceService's DEBUG-only failure logger), specifically so no
//  future edit can accidentally introduce one that includes either value.
//
//  No retry loop: a single request per call. referral-api's actions are already idempotent where
//  intended (bootstrap, and a same-code apply_code re-submission) — see that function's own
//  header — so a client-side retry would only risk duplicating load, never correctness, but is
//  still unnecessary complexity this foundation doesn't need.
//

import Foundation

protocol ReferralAPIServicing: Sendable {
    func bootstrap(
        credential: ReferralInstallationCredential,
        revenueCatAppUserID: String,
        environment: ReferralRevenueEnvironment,
        appVersion: String?
    ) async throws -> ReferralBootstrapResponse

    func status(credential: ReferralInstallationCredential) async throws -> ReferralStatus

    func applyCode(
        _ referralCode: String,
        credential: ReferralInstallationCredential
    ) async throws -> ReferralApplyCodeResponse
}

struct ReferralAPIService: ReferralAPIServicing {
    private static let defaultTimeoutInterval: TimeInterval = 15

    private let config: SupabaseConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = ReferralAPIService.defaultSession) throws {
        do {
            self.config = try SupabaseConfig.load()
        } catch {
            throw ReferralServiceError.notConfigured
        }
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    private static var defaultSession: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = defaultTimeoutInterval
        configuration.timeoutIntervalForResource = defaultTimeoutInterval
        return URLSession(configuration: configuration)
    }

    func bootstrap(
        credential: ReferralInstallationCredential,
        revenueCatAppUserID: String,
        environment: ReferralRevenueEnvironment,
        appVersion: String?
    ) async throws -> ReferralBootstrapResponse {
        try await perform(ReferralBootstrapRequest(
            clientInstallationID: credential.installationID,
            installationSecret: credential.installationSecret,
            revenueCatAppUserID: revenueCatAppUserID,
            revenueCatEnvironment: environment,
            appVersion: appVersion
        ))
    }

    func status(credential: ReferralInstallationCredential) async throws -> ReferralStatus {
        try await perform(ReferralStatusRequest(
            clientInstallationID: credential.installationID,
            installationSecret: credential.installationSecret
        ))
    }

    func applyCode(
        _ referralCode: String,
        credential: ReferralInstallationCredential
    ) async throws -> ReferralApplyCodeResponse {
        // UX-only normalization — the backend remains authoritative on format validity (see
        // referral-api-validation.ts's isValidReferralCodeFormat, still enforced server-side).
        let normalizedCode = referralCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return try await perform(ReferralApplyCodeRequest(
            clientInstallationID: credential.installationID,
            installationSecret: credential.installationSecret,
            referralCode: normalizedCode
        ))
    }

    private func perform<Request: Encodable, Response: Decodable>(_ payload: Request) async throws -> Response {
        var request = URLRequest(url: endpointURL())
        request.httpMethod = "POST"
        // Always-fresh: this is live account/progress state, never a candidate for the URL
        // loading system's own response cache (the backend also sends Cache-Control: no-store —
        // see referral-api/index.ts — this is the client-side half of the same intent).
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Client-safe key only — see SupabaseConfig.swift's own "Key Safety Notes." Never a
        // service-role credential; none exists anywhere in this app.
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        guard let body = try? encoder.encode(payload) else {
            throw ReferralServiceError.decoding
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReferralServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReferralServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorBody = try? decoder.decode(ReferralAPIErrorResponse.self, from: data) {
                throw ReferralServiceError.api(ReferralAPIError(code: errorBody.error, statusCode: httpResponse.statusCode))
            }
            throw ReferralServiceError.invalidResponse
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ReferralServiceError.decoding
        }
    }

    private func endpointURL() -> URL {
        Self.edgeFunctionURL(from: config.url)
    }

    /// SUPABASE_URL historically points at PostgREST's REST endpoint (`.../rest/v1/`) — see
    /// CommunityPriceService.normalizedRESTBaseURL()/AnalyticsService.eventsEndpointURL(), which
    /// both detect that same suffix before APPENDING `rest/v1`. Edge Functions live at the project
    /// root under `/functions/v1` instead, so this does the reverse: strips a trailing `rest/v1`
    /// (with or without a trailing slash — `URL.pathComponents` ignores it) back to the project
    /// root before appending the Edge Function path; a bare project-root URL is left unchanged. A
    /// prior version of `endpointURL()` assumed `config.url` was already the project root, which
    /// silently sent every referral request to `.../rest/v1/functions/v1/referral-api` in
    /// production — see ReferralAPIServiceTests.swift's own regression tests, which independently
    /// hardcode the expected literal rather than recomputing it from this method.
    static func edgeFunctionURL(from configuredURL: URL) -> URL {
        let pathComponents = configuredURL.pathComponents.filter { $0 != "/" }
        let projectBaseURL = pathComponents.suffix(2) == ["rest", "v1"]
            ? configuredURL.deletingLastPathComponent().deletingLastPathComponent()
            : configuredURL
        return projectBaseURL
            .appending(path: "functions")
            .appending(path: "v1")
            .appending(path: "referral-api")
    }
}
