//
//  FuelStation.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation
import SwiftData

@Model
final class FuelStation {
    // Inline defaults on every non-optional attribute let the CloudKit-backed SwiftData
    // container validate. latitude/longitude stay optional (a station may have no coordinate).
    // Values match the init defaults, so stored data and shape are unchanged.
    var name: String = ""
    var address: String = ""
    var city: String = ""
    var state: String = ""
    var zipCode: String = ""
    var latitude: Double?
    var longitude: Double?
    var lastKnownE85Price: Double = 0
    var lastUpdated: Date = Date.now
    var notes: String = ""
    var isFavorite: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    // The community backend's stable station identifier (`community_stations.id`) — the only
    // identity Price Alerts accepts. Optional with no default value on purpose: `nil` means "this
    // device has not learned the backend row for this station yet" and is the state of every
    // pre-existing store, so adding it is an additive, lightweight-migratable change. It is only
    // ever copied from a backend response (never derived or fabricated) and is cleared if the
    // station's identity-bearing fields are edited — see CommunityStationIdentity and
    // FuelStation+CommunityIdentity.swift. Deliberately NOT part of how a saved station is
    // matched or displayed: favorites, the unified list and the map still identify stations
    // exactly as before. CloudKit note: this is a new `CD_communityStationID` field, which must
    // exist in the CloudKit PRODUCTION schema before a release that populates it ships.
    var communityStationID: UUID?

    init(
        name: String = "",
        address: String = "",
        city: String = "",
        state: String = "",
        zipCode: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil,
        lastKnownE85Price: Double = 0,
        lastUpdated: Date = .now,
        notes: String = "",
        isFavorite: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        communityStationID: UUID? = nil
    ) {
        self.name = name
        self.address = address
        self.city = city
        self.state = state
        self.zipCode = zipCode
        self.latitude = latitude
        self.longitude = longitude
        self.lastKnownE85Price = lastKnownE85Price
        self.lastUpdated = lastUpdated
        self.notes = notes
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.communityStationID = communityStationID
    }
}
