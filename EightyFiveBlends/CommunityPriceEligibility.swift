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
//  a station that can already show a community price should generally also be able to report
//  one. This file is that shared "does this station carry enough identifying information" logic
//  — but the DISPLAY rule (CommunityStationKey.normalizedKey, "any single field present") and
//  the REPORTING rule (CommunityPriceEligibility.canReport, "genuine location data required")
//  are deliberately NOT identical: a mismatch on read is a minor UI inaccuracy, a mismatch on
//  write pollutes a shared community record with an ambiguous or misattributed station. See
//  CommunityPriceEligibility.canReport's own doc comment for why a bare name (e.g. "Chevron",
//  "Unknown Station") is enough for the former but not the latter.
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
    /// own data.
    ///
    /// This is intentionally STRICTER than `CommunityStationKey.normalizedKey`'s "any single
    /// field present" rule: a station's NAME ALONE is never sufficient here, even though a
    /// name-only station can still build a normalized key and is still perfectly fine to use for
    /// DISPLAY (looking up whether a sparse local station happens to match an existing community
    /// price — a wrong/missed match there is just a minor UI inaccuracy). Reporting is a WRITE
    /// that can create or attach to a shared `community_stations` row every user of the app may
    /// see, so it requires genuine location-bearing information — not just a name, however
    /// specific that name looks.
    ///
    /// A single location field alone is ALSO not sufficient — city, state, or zip in isolation
    /// (e.g. city == "Phoenix", state == "AZ", or a bare zip code) narrows a search area, not a
    /// single physical pump, and neither does a street address with no locality context at all
    /// (many different cities/states share street names like "Main St"). The rule instead
    /// requires either:
    /// - a real (both-present) coordinate pair, which pins one physical point directly, or
    /// - a street address PLUS enough locality context to disambiguate it: a zip code, or a
    ///   city+state pair together (city or state alone doesn't count).
    ///
    /// Two real, already-shipped station-creation paths make this distinction necessary, not
    /// theoretical:
    /// - `LiveFuelStation.init(from:)` (NRELStationService.swift) falls back to the literal
    ///   string `"Unknown Station"` whenever NREL supplies no name for a result; NREL records can
    ///   also lack a usable street address/city/state/zip, and a missing coordinate is
    ///   represented as `0`/`0`, which `StationPriceUpdateContext.live(_:)` already normalizes to
    ///   `nil` before eligibility is ever checked.
    /// - `FuelLogStore.updateStationIfNeeded` (FuelLogStore.swift) creates a brand-new
    ///   `FuelStation` from nothing but a fuel-log entry's typed station name and price whenever
    ///   that name doesn't already match a saved station — address/city/state/zipCode all take
    ///   `FuelStation`'s `""` default, latitude/longitude stay `nil`. That station is reachable
    ///   from Update Price exactly like any other saved station.
    /// A genuine Nearby-search result and a properly-addressed manual station both carry their
    /// street address, city, state, zip, and coordinates together as one unit (see
    /// `saveLiveStation`/`upsertLocalStation` in StationsView.swift, which copy the full source
    /// record rather than a subset), so this stricter rule does not regress legitimate reporting
    /// — only the genuinely ambiguous partial-identity cases above lose eligibility.
    static func canReport(
        name: String,
        streetAddress: String,
        city: String,
        state: String,
        zip: String,
        latitude: Double?,
        longitude: Double?
    ) -> Bool {
        let hasValidCoordinate = latitude != nil && longitude != nil

        let hasStreetAddress = CommunityStationKey.normalizedText(streetAddress).isEmpty == false
        let hasZip = CommunityStationKey.normalizedText(zip).isEmpty == false
        let hasCityAndState = CommunityStationKey.normalizedText(city).isEmpty == false
            && CommunityStationKey.normalizedText(state).isEmpty == false
        let hasSufficientLocality = hasStreetAddress && (hasZip || hasCityAndState)

        return hasValidCoordinate || hasSufficientLocality
    }
}
