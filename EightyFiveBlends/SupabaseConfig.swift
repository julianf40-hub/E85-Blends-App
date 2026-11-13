//
//  SupabaseConfig.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation

enum SupabaseConfigError: LocalizedError {
    case missingConfiguration

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Community price sync is not configured yet."
        }
    }
}

// MARK: - Key Safety Notes
//
// SUPABASE_ANON_KEY is the project's *anon* (public) JWT — role:"anon".
// It is intentionally embedded in the client binary and safe for App Store distribution.
//
// The anon key is NOT the service_role key; it cannot bypass Row Level Security.
// Safety of client-side writes (community_stations, e85_price_reports) depends entirely
// on Supabase RLS policies being enabled and correctly scoped on those tables.
//
// Required before public App Store release:
//   • Confirm RLS is ENABLED on community_stations and e85_price_reports.
//   • Confirm INSERT policies for anon role are scoped to prevent mass-write abuse
//     (e.g., per-reporter rate limiting, server-side validation of price range).
//   • Confirm no DELETE or UPDATE policies are granted to the anon role.
//
// SUPABASE_URL is the project's public REST endpoint — not a secret.

struct SupabaseConfig {
    let url: URL
    /// The legacy anon JWT. Now only a fallback for CommunityPriceService/AnalyticsService (see
    /// `publicRESTHeaders`) when no publishable key is configured, and for `referralClientAPIKey`.
    /// A modern publishable key (below) is NOT a JWT and is never sent as a Bearer token.
    let anonKey: String
    /// The modern Supabase publishable client key (`sb_publishable_...`), read from
    /// SUPABASE_PUBLISHABLE_KEY — `nil` if that key is missing/blank in Info.plist (tests, internal
    /// configurations, and older config fixtures may not set it). Exists so the referral Edge
    /// Function client (see `referralClientAPIKey` below) can use the modern key Supabase's current
    /// client-key model prefers for mobile/public callers, while leaving `anonKey` and every
    /// existing REST client completely untouched.
    let publishableKey: String?

    /// Explicit (not the auto-synthesized memberwise) initializer, specifically so any existing or
    /// future 2-argument `SupabaseConfig(url:anonKey:)` call site keeps compiling unchanged —
    /// `publishableKey` defaults to `nil`.
    init(url: URL, anonKey: String, publishableKey: String? = nil) {
        self.url = url
        self.anonKey = anonKey
        self.publishableKey = publishableKey
    }

    /// The API key ReferralAPIService's `apikey` header should send: the modern publishable key
    /// when one is configured, falling back to the legacy anon key only so a configuration that
    /// hasn't set SUPABASE_PUBLISHABLE_KEY yet (tests, an older fixture) doesn't immediately break.
    /// Production Info.plist ships SUPABASE_PUBLISHABLE_KEY, so this deterministically resolves to
    /// the modern key on-device. Used ONLY by ReferralAPIService — CommunityPriceService and
    /// AnalyticsService continue reading `anonKey` directly and are unaffected by this property.
    var referralClientAPIKey: String {
        publishableKey ?? anonKey
    }

    /// Headers for the public PostgREST clients (CommunityPriceService, AnalyticsService).
    ///
    /// - With a modern publishable key (`sb_publishable_…`): `apikey` only. The publishable key is
    ///   NOT a JWT, so it is never sent as a Bearer token; the Supabase gateway runs the request as
    ///   the `anon` role, the same role the legacy anon JWT carried (the RLS policies on these
    ///   tables are granted to `anon, authenticated` and read no JWT claims).
    /// - `userAccessToken`: a signed-in user's session JWT, when a caller has one, is preserved as
    ///   `Authorization: Bearer <token>` so the request keeps that user's identity. These clients
    ///   have no user sessions today, so they pass nil.
    /// - Without a publishable key: the legacy anon JWT in both headers, exactly as before, so a
    ///   configuration that lacks SUPABASE_PUBLISHABLE_KEY keeps working.
    func publicRESTHeaders(userAccessToken: String? = nil) -> [String: String] {
        var headers: [String: String]
        if let key = publishableKey, key.hasPrefix("sb_publishable_") {
            headers = ["apikey": key]
        } else {
            headers = ["apikey": anonKey, "Authorization": "Bearer \(anonKey)"]
        }
        if let token = userAccessToken, token.isEmpty == false {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    static func load() throws -> SupabaseConfig {
        guard
            let rawURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            let url = URL(string: rawURL),
            let anonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw SupabaseConfigError.missingConfiguration
        }

        // Not part of the guard above — SUPABASE_PUBLISHABLE_KEY is deliberately NOT required yet,
        // since CommunityPriceService/AnalyticsService still depend on the legacy config loading
        // successfully without it. Missing/blank both trim to nil, never an empty string.
        let trimmedPublishableKey = (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let publishableKey = (trimmedPublishableKey?.isEmpty == false) ? trimmedPublishableKey : nil

        return SupabaseConfig(url: url, anonKey: anonKey, publishableKey: publishableKey)
    }
}
