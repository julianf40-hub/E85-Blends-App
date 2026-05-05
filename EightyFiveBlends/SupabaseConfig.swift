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
