//
//  PriceAlertsStationTarget.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B). WHO a Price Alert screen is about, and WHETHER the way
//  into it is offered at all. Pure Foundation: no SwiftUI, no SwiftData, no networking, so the rules a
//  station card depends on are unit-tested instead of implied by view code.
//
//  THE STATION IDENTITY RULE (Phase 3A, unchanged). An alert belongs to the backend's
//  `community_stations.id` — `FuelStation.communityStationID` — or to nothing. This file never builds
//  that identity: it only decides which backend-supplied UUID a card already holds is the freshest, by
//  the same rule StationsView.adoptCommunityStationIDs() applies when it stores one
//  (CommunityStationIdentity.resolved). A station with no UUID gets no target, and therefore no entry
//  point — never one keyed by its name, coordinates, canonical key or a GasBuddy id.
//

import Foundation

// MARK: - Identity

nonisolated enum PriceAlertsStationIdentity {
    /// The community UUID a station should be offered Price Alerts under, from the three places a card
    /// can hold one: the value saved on the station and the UUIDs on its community price and ethanol
    /// summaries (both copied from backend responses). A summary's UUID is the backend's current answer
    /// for this station's current key, so it wins over the saved one — exactly as when it is adopted —
    /// and `nil` never erases a known value.
    static func communityStationID(
        persisted: UUID?,
        priceSummaryID: UUID?,
        ethanolSummaryID: UUID?
    ) -> UUID? {
        CommunityStationIdentity.resolved(existing: persisted, incoming: priceSummaryID ?? ethanolSummaryID)
    }
}

// MARK: - Target

/// The station a Price Alert sheet is about. Constructible only WITH a community station UUID, so a
/// screen that holds one can never be about an ineligible station.
nonisolated struct PriceAlertStationTarget: Identifiable, Equatable, Sendable {
    let communityStationID: UUID
    let name: String
    /// Street address and "City, ST" on one line, for the sheet header. May be empty.
    let locationLine: String

    var id: UUID { communityStationID }

    /// - Returns: `nil` when `communityStationID` is `nil` — the station is not eligible and no Price
    ///   Alert screen is offered for it.
    init?(communityStationID: UUID?, name: String, address: String = "", city: String = "", state: String = "") {
        guard let communityStationID else { return nil }
        self.communityStationID = communityStationID
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "Unnamed Station" : trimmedName
        locationLine = Self.locationLine(address: address, city: city, state: state)
    }

    /// A target for an alert the server listed (the Price Alerts overview). The server always knows the
    /// station's UUID, so this cannot fail.
    init(listing: PriceAlertListing) {
        communityStationID = listing.alert.stationID
        let trimmedName = listing.station.name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmedName.isEmpty ? "Unnamed Station" : trimmedName
        locationLine = Self.locationLine(
            address: listing.station.address ?? "",
            city: listing.station.city ?? "",
            state: listing.station.state ?? ""
        )
    }

    static func locationLine(address: String, city: String, state: String) -> String {
        let cityState = [city, state]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: ", ")
        return [address.trimmingCharacters(in: .whitespacesAndNewlines), cityState]
            .filter { $0.isEmpty == false }
            .joined(separator: " • ")
    }
}

// MARK: - Entry point

/// How (and whether) a station card offers the Price Alerts entry.
nonisolated enum PriceAlertsEntryPresentation: Equatable, Sendable {
    /// Not offered: the station has no community UUID, so there is nothing an alert could be keyed by.
    case hidden
    /// Offered. Opens the Price Alert sheet.
    case available
    /// Offered with a Pro cue. Opening it shows the Pro upgrade card instead of the form.
    case availableProLocked

    /// - Important: `.unresolved` is NOT Free. Until RevenueCat has answered, a false `isPro` could be a
    ///   paying subscriber, so the entry carries no lock cue and the sheet says it is still checking —
    ///   the same rule Stations and Refer & Earn follow for an unresolved entitlement.
    static func resolve(communityStationID: UUID?, entitlement: PriceAlertsEntitlement) -> PriceAlertsEntryPresentation {
        guard communityStationID != nil else { return .hidden }
        switch entitlement {
        case .active, .unresolved: return .available
        case .inactive: return .availableProLocked
        }
    }

    var isVisible: Bool {
        self != .hidden
    }

    var showsProCue: Bool {
        self == .availableProLocked
    }

    func accessibilityLabel(stationName: String) -> String {
        let name = stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Price Alert" : "Price Alert for \(name)"
    }

    var accessibilityHint: String? {
        switch self {
        case .hidden: return nil
        case .available: return "Opens Price Alert settings for this station."
        case .availableProLocked: return "Price Alerts are part of 85Blends Pro."
        }
    }
}
