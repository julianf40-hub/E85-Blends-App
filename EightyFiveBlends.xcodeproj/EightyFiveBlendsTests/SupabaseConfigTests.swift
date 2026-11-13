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

    // MARK: 5. Public REST headers (CommunityPriceService, AnalyticsService)

    @Test("With a publishable key, REST headers send it as apikey only, never as a Bearer token")
    func publicRESTHeaders_publishableKey_hasNoBearer() {
        let config = SupabaseConfig(url: Self.testURL, anonKey: "legacy-anon-jwt", publishableKey: "sb_publishable_test")
        #expect(config.publicRESTHeaders() == ["apikey": "sb_publishable_test"])
    }

    @Test("A signed-in user's access token is preserved as the Bearer token alongside the publishable apikey")
    func publicRESTHeaders_preservesUserAccessToken() {
        let config = SupabaseConfig(url: Self.testURL, anonKey: "legacy-anon-jwt", publishableKey: "sb_publishable_test")
        #expect(config.publicRESTHeaders(userAccessToken: "user-session-jwt")
                == ["apikey": "sb_publishable_test", "Authorization": "Bearer user-session-jwt"])
        #expect(config.publicRESTHeaders(userAccessToken: "") == ["apikey": "sb_publishable_test"])
    }

    @Test("Without a publishable key, REST headers keep the legacy anon JWT in both headers")
    func publicRESTHeaders_legacyFallback() {
        let config = SupabaseConfig(url: Self.testURL, anonKey: "legacy-anon-jwt")
        #expect(config.publicRESTHeaders()
                == ["apikey": "legacy-anon-jwt", "Authorization": "Bearer legacy-anon-jwt"])
    }

    @Test("A non-publishable value in the publishable slot (secret key, JWT) is never sent; legacy fallback applies")
    func publicRESTHeaders_rejectsNonPublishableValues() {
        for wrong in ["sb_secret_fixture", "eyJfixture"] {
            let config = SupabaseConfig(url: Self.testURL, anonKey: "legacy-anon-jwt", publishableKey: wrong)
            #expect(config.publicRESTHeaders()["apikey"] == "legacy-anon-jwt")
            #expect(config.publicRESTHeaders().values.contains { $0.contains(wrong) } == false)
        }
    }

    @Test("The shipped Info.plist resolves REST headers to the publishable key with no Bearer token")
    func publicRESTHeaders_shippedConfiguration() throws {
        let headers = try SupabaseConfig.load().publicRESTHeaders()
        #expect(headers["apikey"]?.hasPrefix("sb_publishable_") == true)
        #expect(headers["Authorization"] == nil)
    }
}
