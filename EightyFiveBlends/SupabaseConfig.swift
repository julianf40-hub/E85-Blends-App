//
//  SupabaseConfig.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation

enum SupabaseConfigError: LocalizedError, Equatable {
    /// SUPABASE_URL is missing, blank, or not an https URL with a host.
    case missingConfiguration
    /// SUPABASE_PUBLISHABLE_KEY is missing, blank, or not a publishable key (`sb_publishable_…`).
    /// A legacy anon JWT, a secret key or anything else is rejected, never used in its place.
    case missingPublishableKey

    var errorDescription: String? {
        switch self {
        case .missingConfiguration, .missingPublishableKey:
            return "Community price sync is not configured yet."
        }
    }
}

// MARK: - Key Safety Notes
//
// SUPABASE_PUBLISHABLE_KEY (`sb_publishable_…`) is the project's public client key. It is
// intentionally embedded in the client binary and safe for App Store distribution. It is NOT a
// JWT: it is sent only as the `apikey` header, and the Supabase gateway runs the request as the
// `anon` role. It cannot bypass Row Level Security.
//
// The legacy SUPABASE_ANON_KEY (an anon JWT) is no longer read by the app. Supabase is retiring
// the legacy anon/service_role keys, so nothing here falls back to it: a configuration without a
// valid publishable key fails to load instead of sending a key that may already be revoked.
//
// Safety of client-side writes (community_stations, e85_price_reports, e85_ethanol_reports,
// e85_analytics_events) depends entirely on RLS being enabled and correctly scoped on those tables:
//   • RLS ENABLED on each table.
//   • INSERT policies for the anon role scoped to prevent mass-write abuse (server-side validation).
//   • No DELETE or UPDATE policies granted to the anon role.
//
// SUPABASE_URL is the project's public REST endpoint — not a secret.

struct SupabaseConfig {
    let url: URL
    /// The Supabase publishable client key (`sb_publishable_…`), read from SUPABASE_PUBLISHABLE_KEY.
    /// `load()` guarantees the prefix. This is the only client key the app sends.
    let publishableKey: String

    init(url: URL, publishableKey: String) {
        self.url = url
        self.publishableKey = publishableKey
    }

    /// The API key ReferralAPIService's `apikey` header sends: the publishable key.
    var referralClientAPIKey: String {
        publishableKey
    }

    /// Headers for the public PostgREST clients (CommunityPriceService, AnalyticsService).
    ///
    /// - `apikey`: the publishable key. Never sent as a Bearer token (it is not a JWT); the gateway
    ///   runs the request as the `anon` role, which the RLS policies on these tables are granted to
    ///   (they read no JWT claims).
    /// - `userAccessToken`: a signed-in user's session JWT, when a caller has one, is preserved as
    ///   `Authorization: Bearer <token>` so the request keeps that user's identity. These clients
    ///   have no user sessions today, so they pass nil.
    func publicRESTHeaders(userAccessToken: String? = nil) -> [String: String] {
        var headers = ["apikey": publishableKey]
        if let token = userAccessToken, token.isEmpty == false {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    /// Reads SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY from Info.plist (or, in tests, from
    /// `value`). Both are required; SUPABASE_ANON_KEY is not read, so it may be absent or blank.
    static func load(
        _ value: (String) -> Any? = { Bundle.main.object(forInfoDictionaryKey: $0) }
    ) throws -> SupabaseConfig {
        func trimmed(_ key: String) -> String? {
            let text = (value(key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }

        guard
            let rawURL = trimmed("SUPABASE_URL"),
            let url = URL(string: rawURL),
            url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false
        else {
            throw SupabaseConfigError.missingConfiguration
        }

        guard let publishableKey = trimmed("SUPABASE_PUBLISHABLE_KEY"),
              publishableKey.hasPrefix("sb_publishable_"),
              publishableKey.count > "sb_publishable_".count
        else {
            throw SupabaseConfigError.missingPublishableKey
        }

        return SupabaseConfig(url: url, publishableKey: publishableKey)
    }
}
