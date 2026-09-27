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
    /// MapsRoutingHelper.recordPendingE85PriceContributionIfEligible. Optional with a `nil`
    /// default (rather than a required parameter) so every pre-existing call site — including
    /// other test files' own fixtures — keeps compiling unchanged; PendingPriceContributionStore.
    /// current treats nil exactly like a corrupt/unrecognized payload and never surfaces it,
    /// which is what lets an old, pre-fix blob decode cleanly and still be discarded, with no
    /// separate migration step.
    let e85Evidence: PendingPriceContributionE85Evidence? = nil
}
