//
//  PendingPriceContribution.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — the short-lived "did you visit this station?" price-contribution
//  opportunity created after a successful Directions handoff (see MapsRoutingHelper's
//  instrumentation in AppPreferences.swift). Deliberately holds only the scalar station fields
//  StationPriceUpdateContext already needs to drive the existing community-reporting pipeline —
//  never a LiveFuelStation/FuelStation object, and never LiveFuelStation.id, which is
//  regenerated on every NREL decode and cannot reliably identify the same physical station in a
//  later app session (see StationsView.normalizedStationKey(for:)'s own comments on this exact
//  issue).
//
//  This is ephemeral contribution state, not visit-history tracking: exactly one instance ever
//  exists at a time (see PendingPriceContributionStore), it carries no user location, no trip
//  history, and no personally identifying data — only the station the user was just directed to
//  and when.
//
//  Price-prompt data-quality fix — a real-device report found this prompt firing for a station
//  with no evidence it actually sells E85 (a generic "Get Directions" tap is not, by itself,
//  proof of that). Creation moved from the generic MapsRoutingHelper.openDirections(to:) success
//  path to the explicit, E85-gated
//  MapsRoutingHelper.recordPendingE85PriceContributionIfEligible(for:evidence:) — see that
//  function's own header for exactly which call sites may pass which PendingPriceContributionE85Evidence
//  case. e85Evidence below is what PendingPriceContributionStore.current checks before ever
//  surfacing a contribution — see that property's own doc comment.
//

import Foundation

/// Affirmative evidence that the station a PendingPriceContribution was recorded for came from a
/// source this app has actually verified sells E85 — never inferred from a brand name, and never
/// present merely because the user tapped some "Get Directions" control. The only production
/// call sites that ever attach one of these cases are the two documented on
/// MapsRoutingHelper.recordPendingE85PriceContributionIfEligible(for:evidence:)'s own header.
enum PendingPriceContributionE85Evidence: String, Codable, Equatable, Sendable {
    /// The destination came from a `LiveFuelStation` returned by
    /// `NLRStationService.fetchNearbyE85Stations` — NREL's alt-fuel-station API queried with
    /// `fuel_type=E85` (see NRELStationService.swift) — the Stations tab's live/nearby search
    /// results.
    case liveNRELSearch
    /// The destination came from a `NearbyE85Station` in the Nearby E85 widget's own cached
    /// snapshot, which `StationsView.publishNearbyWidgetSnapshot()` builds exclusively from that
    /// same `fetchNearbyE85Stations` result — never from a saved/manual `FuelStation`.
    case nearbyE85Widget
}

struct PendingPriceContribution: Codable, Equatable, Sendable {
    /// CommunityStationKey.canonicalKey(...) for this station — the same identity every other
    /// Community Pricing read/write path in this app already keys on (see
    /// CommunityPriceEligibility.swift). Computed once, at recording time, from the exact
    /// station data MapsRoutingHelper already had in hand for the directions handoff.
    let stationKey: String
    let stationName: String

    let streetAddress: String?
    let city: String?
    let state: String?
    let zip: String?

    let latitude: Double?
    let longitude: Double?

    let directionsOpenedAt: Date

    /// `MapsAppOption.rawValue` at the moment directions were opened — context only; never
    /// required for eligibility or for the community-reporting pipeline itself.
    let mapsProvider: String?

    /// nil for a contribution recorded before this field existed (any pre-fix persisted blob —
    /// the key is simply absent from its JSON) or, in principle, for one that reached this
    /// initializer without going through
    /// MapsRoutingHelper.recordPendingE85PriceContributionIfEligible. PendingPriceContributionStore
    /// .current treats nil exactly like a corrupt/unrecognized payload and never surfaces it,
    /// which is what lets an old, pre-fix blob decode cleanly and still be discarded, with no
    /// separate migration step. JSON decoding is handled explicitly below via `init(from:)`,
    /// never via this property's own default — see the explicit `init(...)` right below for why
    /// this has no declaration-time default of its own.
    let e85Evidence: PendingPriceContributionE85Evidence?

    /// Explicit initializer (a Swift `let` property with a declaration-time default is excluded
    /// from the compiler-synthesized memberwise initializer entirely — not merely given a
    /// defaultable parameter, the way a `var` with a default would be — so `e85Evidence` cannot
    /// have `= nil` on the property itself and still be passable here; the default instead lives
    /// on this initializer's own parameter). Every pre-existing call site that omits `e85Evidence`
    /// (including other test files' own fixtures) keeps compiling via that parameter default; the
    /// three E85-verified call sites in MapsRoutingHelper pass it explicitly.
    init(
        stationKey: String,
        stationName: String,
        streetAddress: String?,
        city: String?,
        state: String?,
        zip: String?,
        latitude: Double?,
        longitude: Double?,
        directionsOpenedAt: Date,
        mapsProvider: String?,
        e85Evidence: PendingPriceContributionE85Evidence? = nil
    ) {
        self.stationKey = stationKey
        self.stationName = stationName
        self.streetAddress = streetAddress
        self.city = city
        self.state = state
        self.zip = zip
        self.latitude = latitude
        self.longitude = longitude
        self.directionsOpenedAt = directionsOpenedAt
        self.mapsProvider = mapsProvider
        self.e85Evidence = e85Evidence
    }

    /// Whether this contribution's address fields are a flattened copy rather than the station's
    /// structured address. True for one recorded from the Nearby E85 widget, whose snapshot carries
    /// a single joined address string, so the destination it rebuilds has city/state/zip blank (see
    /// MapsRoutingHelper.recordPendingE85PriceContributionIfEligible). Such a contribution can still
    /// identify and report a station — `stationKey` is the station's own canonical key — but its
    /// fields must never replace the structured address of a saved station it merely matches; see
    /// StationsView.upsertLocalStation(for:price:note:). Derived from provenance, never stored, so
    /// the persisted wire format is unchanged.
    var hasFlattenedAddress: Bool {
        e85Evidence == .nearbyE85Widget
    }
}

// MARK: - Explicit Codable conformance
//
// Written by hand, in an extension, rather than relying on Swift's synthesized Decodable — whose
// "an Optional property with no key present decodes to nil" behavior is real but implicit. This
// makes that behavior an explicit, intentional `decodeIfPresent` call instead, so a reviewer (or
// a future editor of this file) doesn't have to know that synthesis detail to see how backward
// compatibility actually works. `init(from:)` here is a DIFFERENT initializer from the explicit
// memberwise-style `init(stationKey:...)` declared above (distinct parameter lists) — the two
// coexist without conflict; neither one suppresses the other. Every OTHER field's wire format is
// unchanged — same keys, same optional-omits-when-nil encoding — this only changes how
// e85Evidence specifically is decoded/documented.
extension PendingPriceContribution {
    private enum CodingKeys: String, CodingKey {
        case stationKey, stationName, streetAddress, city, state, zip, latitude, longitude
        case directionsOpenedAt, mapsProvider, e85Evidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stationKey = try container.decode(String.self, forKey: .stationKey)
        stationName = try container.decode(String.self, forKey: .stationName)
        streetAddress = try container.decodeIfPresent(String.self, forKey: .streetAddress)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        zip = try container.decodeIfPresent(String.self, forKey: .zip)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        directionsOpenedAt = try container.decode(Date.self, forKey: .directionsOpenedAt)
        mapsProvider = try container.decodeIfPresent(String.self, forKey: .mapsProvider)
        // THE explicit backward-compatibility point: a pre-fix blob's JSON has no "e85Evidence"
        // key at all — decodeIfPresent returns nil for a missing key (never throws), exactly the
        // "old JSON -> nil" behavior this fix requires. New JSON carrying "liveNRELSearch"/
        // "nearbyE85Widget" decodes to that exact case; an unrecognized/corrupt string throws
        // (caught by PendingPriceContributionStore.current's own `try?`, which already fails
        // closed to nil for any decode error).
        e85Evidence = try container.decodeIfPresent(PendingPriceContributionE85Evidence.self, forKey: .e85Evidence)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stationKey, forKey: .stationKey)
        try container.encode(stationName, forKey: .stationName)
        try container.encodeIfPresent(streetAddress, forKey: .streetAddress)
        try container.encodeIfPresent(city, forKey: .city)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(zip, forKey: .zip)
        try container.encodeIfPresent(latitude, forKey: .latitude)
        try container.encodeIfPresent(longitude, forKey: .longitude)
        try container.encode(directionsOpenedAt, forKey: .directionsOpenedAt)
        try container.encodeIfPresent(mapsProvider, forKey: .mapsProvider)
        try container.encodeIfPresent(e85Evidence, forKey: .e85Evidence)
    }
}
