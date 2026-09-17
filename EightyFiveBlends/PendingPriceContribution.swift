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

import Foundation

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
}
