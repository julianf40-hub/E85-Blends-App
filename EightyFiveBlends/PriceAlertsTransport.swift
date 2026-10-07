//
//  PriceAlertsTransport.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). The URLSession implementation of
//  PriceAlertsAPITransport: it turns an already-encoded JSON body into one HTTPS POST to
//  supabase/functions/price-alerts-api and hands back the status and bytes. Mirrors
//  ReferralAPIService's established pattern (SupabaseConfig-sourced client-safe key, injectable
//  session) — it is not a new networking architecture — with these deliberate tightenings, because
//  this body carries an installation secret:
//
//    - HTTPS ONLY. A configured URL that is not https is treated as "not configured": the key and
//      secret are never sent over cleartext.
//    - NO REDIRECTS. A redirect is refused (the 3xx comes back as the response), so the API key and
//      the body can never be forwarded to a host the configuration did not name. Supabase Edge
//      Functions do not redirect; if one ever does, failing is the safe outcome.
//    - EPHEMERAL SESSION. No URL cache, no cookies, no credential storage, so neither the request
//      body nor the reply is ever written to disk by the loading system.
//    - THE CLIENT-SAFE KEY ONLY. The Supabase publishable key (or, failing that, the legacy anon key
//      the app already ships). There is no service-role key anywhere in this app, and none is
//      accepted here.
//    - NOTHING IS LOGGED, and a failure is reduced to a PriceAlertsNetworkFailure category — the
//      system error's text can contain the URL.
//

import Foundation

/// Where price-alerts-api lives for a Supabase configuration, and which key authenticates to it.
nonisolated enum PriceAlertsEndpoint {
    static let functionName = "price-alerts-api"

    /// `SUPABASE_URL` historically points at PostgREST (`…/rest/v1/`) — see
    /// ReferralAPIService.edgeFunctionURL, which strips the same suffix. Edge Functions live at the
    /// project root under `/functions/v1`, so a trailing `rest/v1` is removed before the function
    /// path is appended; a bare project URL is left as it is.
    static func url(from configuredURL: URL) -> URL {
        let pathComponents = configuredURL.pathComponents.filter { $0 != "/" }
        let projectBaseURL = pathComponents.suffix(2) == ["rest", "v1"]
            ? configuredURL.deletingLastPathComponent().deletingLastPathComponent()
            : configuredURL
        return projectBaseURL
            .appending(path: "functions")
            .appending(path: "v1")
            .appending(path: functionName)
    }

    /// The modern publishable key when the build ships one, else the legacy anon key — the same
    /// choice ReferralAPIService makes. price-alerts-api accepts either in the `apikey` header.
    static func clientAPIKey(from config: SupabaseConfig) -> String {
        config.publishableKey ?? config.anonKey
    }
}

struct URLSessionPriceAlertsTransport: PriceAlertsAPITransport {
    static let requestTimeout: TimeInterval = 15

    private struct Target: Sendable {
        let endpoint: URL
        let apiKey: String
    }

    private let target: Target?
    private let session: URLSession

    /// - Parameter config: `nil` (or a non-https URL) makes every call throw `.notConfigured`.
    init(config: SupabaseConfig?, session: URLSession = URLSessionPriceAlertsTransport.makeSession()) {
        if let config {
            let endpoint = PriceAlertsEndpoint.url(from: config.url)
            let apiKey = PriceAlertsEndpoint.clientAPIKey(from: config).trimmingCharacters(in: .whitespacesAndNewlines)
            if endpoint.scheme?.lowercased() == "https", endpoint.host?.isEmpty == false, apiKey.isEmpty == false {
                target = Target(endpoint: endpoint, apiKey: apiKey)
            } else {
                target = nil
            }
        } else {
            target = nil
        }
        self.session = session
    }

    /// The app's configuration (`Info.plist` → SupabaseConfig). A missing configuration is not an
    /// error here; it surfaces as `.notConfigured` when a call is made.
    init() {
        self.init(config: try? SupabaseConfig.load())
    }

    /// Whether this transport has somewhere to send to.
    var isConfigured: Bool {
        target != nil
    }

    func post(_ body: Data) async throws -> PriceAlertsTransportResponse {
        guard let target else { throw PriceAlertsAPIError.notConfigured }
        let request = Self.makeRequest(endpoint: target.endpoint, apiKey: target.apiKey, body: body)
        do {
            let (data, response) = try await session.data(for: request, delegate: NoRedirectDelegate())
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PriceAlertsAPIError.invalidResponse(statusCode: nil)
            }
            return PriceAlertsTransportResponse(statusCode: httpResponse.statusCode, data: data)
        } catch let error as PriceAlertsAPIError {
            throw error
        } catch {
            throw PriceAlertsAPIError.network(PriceAlertsNetworkFailure(error))
        }
    }

    /// The exact request that goes on the wire. Static and free of the session so the tests can pin
    /// it: the host and path, the method, and — above all — that the only credential in a header is
    /// the client-safe `apikey`.
    static func makeRequest(endpoint: URL, apiKey: String, body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.httpShouldHandleCookies = false
        request.httpBody = body
        return request
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }
}

/// Refuses every redirect, so a response can never cause the request (with its `apikey` header and
/// secret-bearing body) to be re-sent to another location. `nonisolated`: URLSession calls this on
/// its own delegate queue.
private nonisolated final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
