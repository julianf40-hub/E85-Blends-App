//
//  AnalyticsService.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — the smallest analytics abstraction that gets an AnalyticsEventPayload to the
//  existing, already-live `public.e85_analytics_events` Supabase table, reusing the exact same
//  URLSession/SupabaseConfig/REST pattern CommunityPriceService already established (same
//  SUPABASE_URL/SUPABASE_ANON_KEY configuration, same injectable-session-for-tests seam, same
//  apikey/Authorization header construction) rather than inventing a second one. No third-party
//  analytics SDK.
//
//  Every product action that fires an analytics event must remain fully correct if this entire
//  file silently no-ops — see `track(_:properties:)` below, the ONLY entry point production call
//  sites should ever use. It never throws, never surfaces a user-visible error, never retries,
//  and never queues an event for a later attempt; a dropped event is simply a dropped event.
//

import Foundation

enum AnalyticsServiceError: Error {
    case notConfigured
    case invalidBaseURL
    case invalidResponse
    case requestFailed(statusCode: Int)
}

struct AnalyticsService {
    private let config: SupabaseConfig
    private let session: URLSession
    private let encoder: JSONEncoder

    init(session: URLSession = AnalyticsService.defaultSession) throws {
        do {
            self.config = try SupabaseConfig.load()
        } catch {
            throw AnalyticsServiceError.notConfigured
        }

        self.session = session

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    private static var defaultSession: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }

    /// Fire-and-forget convenience every product call site should use — never `async`, never
    /// `throws`, safe to call directly from a button action or a plain function body with no
    /// `Task { }`/`await` boilerplate at the call site. Internally performs the network request
    /// on its own `Task` and swallows every possible failure (misconfiguration, network error,
    /// non-2xx response) — see this type's own header for why that's deliberate. Product
    /// behavior must never branch on whether this call "worked."
    @MainActor
    static func track(
        _ eventName: AnalyticsEventName,
        properties: AnalyticsEventProperties = AnalyticsEventProperties(),
        now: Date = .now
    ) {
        Task {
            do {
                let service = try AnalyticsService()
                try await service.send(eventName: eventName, properties: properties, occurredAt: now)
            } catch {
                #if DEBUG
                print("[85Blends][Analytics] \(eventName.rawValue) not sent:", error)
                #endif
            }
        }
    }

    /// The actual, independently-testable network call — throws on any failure so tests can
    /// assert on it directly. `track(_:properties:now:)` above is the only production call site
    /// and is what actually swallows the error; nothing else should call this directly outside
    /// tests.
    func send(
        eventName: AnalyticsEventName,
        properties: AnalyticsEventProperties,
        occurredAt: Date
    ) async throws {
        let payload = AnalyticsEventPayload(
            eventName: eventName,
            occurredAt: occurredAt,
            appVersion: Self.appVersion,
            contributorID: CommunityPriceService.anonymousReporterID,
            properties: properties
        )

        guard let url = eventsEndpointURL() else {
            throw AnalyticsServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try encoder.encode(payload)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalyticsServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AnalyticsServiceError.requestFailed(statusCode: httpResponse.statusCode)
        }
    }

    private func eventsEndpointURL() -> URL? {
        let pathComponents = config.url.pathComponents.filter { $0 != "/" }
        let base = pathComponents.suffix(2) == ["rest", "v1"]
            ? config.url
            : config.url.appending(path: "rest").appending(path: "v1")
        return base.appending(path: "e85_analytics_events")
    }

    private static var appVersion: String {
        let raw = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "unknown" : raw
    }
}
