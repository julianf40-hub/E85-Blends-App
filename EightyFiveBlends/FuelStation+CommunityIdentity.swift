//
//  FuelStation+CommunityIdentity.swift
//  EightyFiveBlends
//
//  The thin SwiftData-facing half of CommunityStationIdentity: how a saved station learns, keeps
//  and discards the backend's stable community-station UUID (`FuelStation.communityStationID`).
//  All decisions live in the pure CommunityStationIdentity enum; this file only applies them to a
//  FuelStation, so the rules stay unit-testable without a ModelContainer (the stored property
//  itself must live in FuelStation's own declaration — an extension cannot add stored state).
//
//  None of this changes how a saved station is matched, merged, sorted or displayed: that is still
//  the name/address/coordinate matching StationsView already does. The UUID is purely an
//  additional, optional attribute for Price Alerts to read.
//

import Foundation

extension FuelStation {
    /// `CommunityStationKey.canonicalKey` for this station's CURRENT identity-bearing fields — the
    /// same single identity function StationsView uses to look this station up in the community
    /// backend. Compare a value taken before an edit with this one after it to learn whether the
    /// edit may have turned the station into a different physical place.
    var communityIdentityKey: String? {
        CommunityStationKey.canonicalKey(
            name: name,
            streetAddress: address,
            city: city,
            state: state,
            zip: zipCode,
            latitude: latitude,
            longitude: longitude
        )
    }

    /// Stores `incoming` as this station's community UUID per `CommunityStationIdentity.resolved`
    /// (a `nil` never erases an existing value). Returns `true` only when the stored value
    /// actually changed, so callers can skip a pointless save/CloudKit export when it did not.
    @discardableResult
    func adoptCommunityStationID(_ incoming: UUID?) -> Bool {
        let resolved = CommunityStationIdentity.resolved(existing: communityStationID, incoming: incoming)
        guard resolved != communityStationID else { return false }
        communityStationID = resolved
        return true
    }

    /// Community station → saved station: the backend row returned by `upsertCommunityStation` /
    /// a community lookup carries the UUID in `id`.
    @discardableResult
    func adoptCommunityStationID(from station: CommunityStation) -> Bool {
        adoptCommunityStationID(station.id)
    }

    /// Community price summary → saved station: the summary StationsView already holds for this
    /// station's canonical key carries the UUID on its latest report.
    @discardableResult
    func adoptCommunityStationID(from summary: CommunityPriceSummary?) -> Bool {
        adoptCommunityStationID(summary?.communityStationID)
    }

    /// Drops the stored UUID if this station's identity-bearing fields no longer resolve to the
    /// canonical key they had at `previousKey` (taken from `communityIdentityKey` BEFORE the
    /// edit). Returns `true` only when a stored UUID was actually discarded. A station that never
    /// had a UUID is left untouched.
    @discardableResult
    func discardCommunityStationIDIfIdentityChanged(since previousKey: String?) -> Bool {
        guard communityStationID != nil,
              CommunityStationIdentity.retainsID(previousKey: previousKey, currentKey: communityIdentityKey) == false
        else { return false }
        communityStationID = nil
        return true
    }
}
