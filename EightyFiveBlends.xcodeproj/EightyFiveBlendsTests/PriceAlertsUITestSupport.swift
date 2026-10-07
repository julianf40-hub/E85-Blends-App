//
//  PriceAlertsUITestSupport.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B) — helpers shared by the model and lifecycle tests, built on the Phase 3A
//  fakes (PriceAlertsTestSupport.swift). Nothing here touches the network, the real Keychain,
//  UserNotifications or RevenueCat.
//

import Foundation
import Testing
@testable import EightyFiveBlends

extension BackendFixtures {
    /// Decodes a `list_alerts` row the way the API client does (millisecond ISO-8601 timestamps).
    static func decodeListing(_ row: [String: Any]) throws -> PriceAlertListing {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SupabaseTimestamp.decodingStrategy
        return try decoder.decode(PriceAlertListing.self, from: data(row))
    }
}

extension PriceAlertsStack {
    /// The app after a relaunch: a SECOND service over the SAME fakes, so it shares the Keychain
    /// credential, the registration record and the server with the first, but has loaded nothing.
    func relaunchedService() -> PriceAlertsService {
        let clock = self.clock
        let sleeper = self.sleeper
        return PriceAlertsService.make(
            transport: transport,
            credentialStore: credentials,
            revenueCatIdentity: identity,
            push: push,
            metadata: metadata,
            registrationRecords: records,
            entitlement: entitlement,
            appVersion: { "2.4.1 (100)" },
            now: { clock.now },
            sleep: { await sleeper.sleep($0) }
        )
    }

    /// A target for `PriceAlertsStack.stationID(seed)`.
    static func target(_ seed: UInt8 = 1, name: String = "Corner Pump") -> PriceAlertStationTarget {
        PriceAlertStationTarget(
            communityStationID: stationID(seed),
            name: name,
            address: "1 Main St",
            city: "Omaha",
            state: "NE"
        )!
    }

    /// A station model over `service` (default: this stack's own).
    func stationModel(seed: UInt8 = 1, service: PriceAlertsService? = nil) -> PriceAlertsStationModel {
        PriceAlertsStationModel(target: Self.target(seed), service: service ?? self.service)
    }

    /// Puts an alert on the simulated server by going through the real service, then returns a model
    /// over a relaunched service — one that has not loaded anything yet.
    func relaunchedStationModel(
        seed: UInt8 = 1,
        existing rule: PriceAlertRule?,
        preferences: PriceAlertPreferences = .defaults
    ) async throws -> PriceAlertsStationModel {
        if let rule {
            _ = try await service.createAlert(communityStationID: Self.stationID(seed), rule: rule, preferences: preferences)
        }
        return stationModel(seed: seed, service: relaunchedService())
    }
}

// MARK: - Text shown to a person

/// Fragments that must never appear in text shown to a person. Compared case-insensitively.
let forbiddenUserTextFragments = [
    "http", "json", "supabase", "price-alerts-api", "function", "secret", "token", "installation",
    "uuid", "apns", "keychain", "pro_required", "invalid_", "unauthorized", "status code", "error code",
    "403", "401", "404", "408", "429", "500", "502", "503",
]

/// Fails unless `text` is non-empty, free of technical detail, and never says an alert is "paused"
/// (there is no pause: turning an alert off deletes it).
func assertSafeToShow(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let lowered = text.lowercased()
    for fragment in forbiddenUserTextFragments {
        #expect(lowered.contains(fragment) == false, "“\(text)” must not contain “\(fragment)”", sourceLocation: sourceLocation)
    }
    #expect(lowered.contains("pause") == false, "“\(text)” must not say “paused”", sourceLocation: sourceLocation)
    #expect(text.isEmpty == false, sourceLocation: sourceLocation)
}
