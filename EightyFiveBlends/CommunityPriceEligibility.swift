//
//  CommunityPriceEligibility.swift
//  EightyFiveBlends
//
//  Pure decision logic behind Community E85 Price Reporting eligibility and station-key
//  resolution. Kept independent of SwiftUI/SwiftData/StationsView — mirroring
//  AppExperienceNavigation/WhatsNewPresentation/PumpStationContextResolver's separation of pure
//  rules from the views that call them — so the actual rule StationsView depends on is directly
//  unit-testable. See EightyFiveBlendsTests/CommunityPriceEligibilityTests.swift.
//
//  Community price reporting was previously gated on how a station was DISCOVERED (a station
//  found via Nearby Search could "Save & Report"; the identical physical station reached
//  through Saved Stations could only "Save Locally") rather than on whether the station carries
//  enough information to be safely identified/resolved server-side. That was an unintentional
//  implementation gap — see the removed TODO this file replaces in StationsView.swift — not a
//  deliberate product rule: the exact same name/address/city/state/zip data already drives the
//  community price DISPLAY that saved stations show ("Community E85 · Reported X days ago"), so
//  a station that can already show a community price must also be able to report one. This file
//  is that single, shared "does this station carry enough identifying information" rule —
//  reused by both the display path and the reporting path so they can never disagree again.
//

import Foundation

/// Builds the normalized station key `CommunityPriceService` uses to resolve/upsert a
/// `community_stations` row (`normalized_key` in Supabase) and that StationsView already uses
/// to look up a station's existing community price for display. Extracted here, unchanged, so
/// it has exactly one implementation shared by both call sites and is independently testable.
enum CommunityStationKey {
    /// Case/diacritic-folded, whitespace-trimmed form of a single field, used to build a stable
    /// key regardless of capitalization or accent differences between two reports of the same
    /// physical station.
    static func normalizedText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// The station's identity key, or `nil` if every field is blank (nothing to key on at all).
    /// Deliberately requires only that *some* identifying field is present — not that every
    /// field is — since a station may legitimately be missing an address or coordinates while
    /// still having a usable name, exactly as StationsView already tolerates for display.
    static func normalizedKey(
        name: String,
        streetAddress: String,
        city: String,
        state: String,
        zip: String
    ) -> String? {
        let components = [name, streetAddress, city, state, zip].map(normalizedText)
        guard components.contains(where: { $0.isEmpty == false }) else {
            return nil
        }
        return components.joined(separator: "|")
    }
}

/// Whether a station has enough identifying information to safely report an E85 price to the
/// community feed.
enum CommunityPriceEligibility {
    /// Navigation history (Nearby Search vs. Saved Stations vs. anywhere else a station surfaces)
    /// is deliberately NOT a parameter here — it was the previous, incorrect gating condition and
    /// must never factor into this rule again. Eligibility is purely a function of the station's
    /// own data: if `CommunityStationKey.normalizedKey` can build a key from it, the exact same
    /// resolution/reporting path already used by Nearby Search can safely be reused for it too.
    static func canReport(
        name: String,
        streetAddress: String,
        city: String,
        state: String,
        zip: String
    ) -> Bool {
        CommunityStationKey.normalizedKey(
            name: name,
            streetAddress: streetAddress,
            city: city,
            state: state,
            zip: zip
        ) != nil
    }
}
