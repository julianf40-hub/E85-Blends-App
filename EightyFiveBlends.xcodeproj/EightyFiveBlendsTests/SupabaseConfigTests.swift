//
//  SupabaseConfigTests.swift
//  EightyFiveBlendsTests
//
//  SupabaseConfig: loading (with an injected Info.plist lookup, so missing, blank and invalid
//  values are directly testable), the publishable-key-only client model with no legacy anon-key
//  fallback, and the headers the public REST clients send. The last test also loads the real
//  shipped Info.plist.
//

import Testing
import Foundation
@testable import EightyFiveBlends

struct SupabaseConfigTests {
    private static let url = "https://example.supabase.co/rest/v1/"
    private static let publishable = "sb_publishable_test"
    private static let legacyAnon = "eyJlegacy-anon-jwt-fixture"

    /// An Info.plist lookup over `values`; a key absent from the dictionary is "missing".
    private static func plist(_ values: [String: Any]) -> (String) -> Any? { { values[$0] } }

    private static func load(_ values: [String: Any]) throws -> SupabaseConfig {
        try SupabaseConfig.load(plist(values))
    }

    // MARK: 1. Loads with a valid publishable key and no legacy anon key

    @Test("Loads with a valid URL and publishable key when SUPABASE_ANON_KEY is missing")
    func load_succeedsWithoutLegacyAnonKey() throws {
        let config = try Self.load(["SUPABASE_URL": Self.url, "SUPABASE_PUBLISHABLE_KEY": Self.publishable])
        #expect(config.url.absoluteString == Self.url)
        #expect(config.publishableKey == Self.publishable)
    }

    @Test("Loads when SUPABASE_ANON_KEY is empty, blank, or not a string")
    func load_succeedsWithEmptyLegacyAnonKey() throws {
        for anon: Any in ["", "   \n", 42] {
            let config = try Self.load(["SUPABASE_URL": Self.url, "SUPABASE_PUBLISHABLE_KEY": Self.publishable,
                                        "SUPABASE_ANON_KEY": anon])
            #expect(config.publishableKey == Self.publishable)
        }
    }

    @Test("A present legacy anon key is ignored: never stored, never sent")
    func load_ignoresLegacyAnonKey() throws {
        let config = try Self.load(["SUPABASE_URL": Self.url, "SUPABASE_PUBLISHABLE_KEY": Self.publishable,
                                    "SUPABASE_ANON_KEY": Self.legacyAnon])
        #expect(config.publicRESTHeaders().values.contains { $0.contains(Self.legacyAnon) } == false)
        #expect(config.referralClientAPIKey == Self.publishable)
    }

    @Test("Surrounding whitespace is trimmed from the URL and the publishable key")
    func load_trimsWhitespace() throws {
        let config = try Self.load(["SUPABASE_URL": " \(Self.url)\n", "SUPABASE_PUBLISHABLE_KEY": "  \(Self.publishable) "])
        #expect(config.url.absoluteString == Self.url)
        #expect(config.publishableKey == Self.publishable)
    }

    // MARK: 2. Missing or invalid required configuration fails, with no anon-key fallback

    @Test("A missing, blank or invalid publishable key fails to load, even with a legacy anon key present")
    func load_failsWithoutValidPublishableKey() {
        let invalid: [Any?] = [nil, "", "   ", "sb_publishable_", Self.legacyAnon, "sb_secret_fixture", "random-value", 7]
        for value in invalid {
            var values: [String: Any] = ["SUPABASE_URL": Self.url, "SUPABASE_ANON_KEY": Self.legacyAnon]
            if let value { values["SUPABASE_PUBLISHABLE_KEY"] = value }
            #expect(throws: SupabaseConfigError.missingPublishableKey) { try Self.load(values) }
        }
    }

    @Test("A missing, blank or non-https SUPABASE_URL fails to load")
    func load_failsWithoutValidURL() {
        let invalid: [Any?] = [nil, "", "  ", "http://example.supabase.co/rest/v1/", "example.supabase.co", "https://", 3]
        for value in invalid {
            var values: [String: Any] = ["SUPABASE_PUBLISHABLE_KEY": Self.publishable]
            if let value { values["SUPABASE_URL"] = value }
            #expect(throws: SupabaseConfigError.missingConfiguration) { try Self.load(values) }
        }
    }

    @Test("An empty configuration fails to load")
    func load_failsWhenEverythingIsMissing() {
        #expect(throws: SupabaseConfigError.missingConfiguration) { try Self.load([:]) }
    }

    // MARK: 3. Client keys and headers

    @Test("referralClientAPIKey is the publishable key")
    func referralClientAPIKey_isPublishableKey() throws {
        let config = try Self.load(["SUPABASE_URL": Self.url, "SUPABASE_PUBLISHABLE_KEY": Self.publishable])
        #expect(config.referralClientAPIKey == Self.publishable)
    }

    @Test("REST headers send the publishable key as apikey only, never as a Bearer token")
    func publicRESTHeaders_publishableKey_hasNoBearer() throws {
        let config = try Self.load(["SUPABASE_URL": Self.url, "SUPABASE_PUBLISHABLE_KEY": Self.publishable])
        #expect(config.publicRESTHeaders() == ["apikey": Self.publishable])
    }

    @Test("A signed-in user's access token is preserved as the Bearer token alongside the publishable apikey")
    func publicRESTHeaders_preservesUserAccessToken() throws {
        let config = try Self.load(["SUPABASE_URL": Self.url, "SUPABASE_PUBLISHABLE_KEY": Self.publishable])
        #expect(config.publicRESTHeaders(userAccessToken: "user-session-jwt")
                == ["apikey": Self.publishable, "Authorization": "Bearer user-session-jwt"])
        #expect(config.publicRESTHeaders(userAccessToken: "") == ["apikey": Self.publishable])
    }

    // MARK: 4. The shipped Info.plist

    @Test("The shipped Info.plist loads and resolves REST headers to the publishable key with no Bearer token")
    func shippedConfiguration_usesPublishableKeyOnly() throws {
        let config = try SupabaseConfig.load()
        #expect(config.publishableKey.hasPrefix("sb_publishable_"))
        let headers = config.publicRESTHeaders()
        #expect(headers == ["apikey": config.publishableKey])
        #expect(headers.values.contains { $0.hasPrefix("eyJ") } == false)
    }
}
