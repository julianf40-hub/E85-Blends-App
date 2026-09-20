//
//  SupabaseConfigTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.0 — publishable-key migration for the referral Edge Function client. Tests for
//  SupabaseConfig's `publishableKey`/`referralClientAPIKey` addition — the pure, plain-value
//  decision behind which key ReferralAPIService's `apikey` header sends, isolated from
//  Bundle.main/Info.plist so it's directly testable with constructed values. Does not test
//  SupabaseConfig.load() itself reading the real Info.plist — that's exercised indirectly by
//  ReferralAPIServiceTests.swift/CommunityPriceService's own tests, which already depend on it
//  resolving correctly (see this file's sibling CommunityStationUpsertSecurityTests.swift's own
//  header note on that assumption).
//

import Testing
import Foundation
@testable import EightyFiveBlends

struct SupabaseConfigTests {
    private static let testURL = URL(string: "https://example.supabase.co/rest/v1/")!

    // MARK: 1. Explicit publishableKey is stored

    @Test("An explicitly-supplied publishableKey is stored as-is")
    func publishableKey_isStoredWhenSupplied() {
        let config = SupabaseConfig(url: Self.testURL, anonKey: "legacy-anon-jwt", publishableKey: "sb_publishable_test")
        #expect(config.publishableKey == "sb_publishable_test")
    }

    // MARK: 2. referralClientAPIKey prefers the publishable key when present

    @Test("referralClientAPIKey returns the publishable key when one is configured")
    func referralClientAPIKey_prefersPublishableKey() {
        let config = SupabaseConfig(url: Self.testURL, anonKey: "legacy-anon-jwt", publishableKey: "sb_publishable_test")
        #expect(config.referralClientAPIKey == "sb_publishable_test")
        // Never the legacy key once a publishable key exists — a single deterministic choice.
        #expect(config.referralClientAPIKey != "legacy-anon-jwt")
    }

    // MARK: 3. referralClientAPIKey falls back to anonKey when publishableKey is nil

    @Test("referralClientAPIKey falls back to the legacy anon key when no publishable key is configured")
    func referralClientAPIKey_fallsBackToAnonKey() {
        let config = SupabaseConfig(url: Self.testURL, anonKey: "legacy-anon-jwt", publishableKey: nil)
        #expect(config.referralClientAPIKey == "legacy-anon-jwt")
    }

    // MARK: 4. The existing 2-argument construction still compiles and works

    @Test("SupabaseConfig(url:anonKey:) — the pre-existing 2-argument call shape — still compiles, defaults publishableKey to nil, and falls back correctly")
    func twoArgumentConstruction_stillCompilesAndDefaultsToNil() {
        let config = SupabaseConfig(url: Self.testURL, anonKey: "legacy-anon-jwt")
        #expect(config.publishableKey == nil)
        #expect(config.referralClientAPIKey == "legacy-anon-jwt")
    }
}
