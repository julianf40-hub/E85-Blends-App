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
    let anonKey: String

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

        return SupabaseConfig(url: url, anonKey: anonKey)
    }
}
