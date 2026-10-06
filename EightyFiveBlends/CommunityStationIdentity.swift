//
//  CommunityStationIdentity.swift
//  EightyFiveBlends
//
//  Pure rules for the backend's stable community-station UUID — `community_stations.id`, the one
//  identifier Price Alerts keys on (price-alerts-api `set_alert` / `delete_alert` take it as
//  `station_id`, and the APNs payload echoes it back as `station_id`). Kept independent of
//  SwiftData/SwiftUI, mirroring CommunityPriceEligibility/AppExperienceNavigation's separation of
//  pure rules from the types that apply them, so the rules are directly unit-testable. See
//  EightyFiveBlendsTests/CommunityStationIdentityTests.swift.
//
//  Two identity notions already exist in this app and this file adds neither of them:
//    - `CommunityStationKey.canonicalKey` (CommunityPriceEligibility.swift) is a client-DERIVED
//      string from name/address/coordinates. It is how this app asks the backend "which row is
//      this station?" and is what `community_stations.normalized_key` stores.
//    - The UUID handled here is the backend's ANSWER to that question. It is only ever copied
//      from a backend response — never derived, hashed, or guessed on the client. That is why the
//      property that stores it is named `communityStationID` rather than another "canonical" ID:
//      there is exactly one canonical-key function, and this is the row it resolves to.
//

import Foundation

/// `nonisolated`: pure value logic with no shared state. The app target defaults to MainActor
/// isolation, and this is called from SwiftData/SwiftUI code and from tests alike.
nonisolated enum CommunityStationIdentity {
    /// The UUID a station should carry after a backend response that may or may not have included
    /// one.
    ///
    /// - A non-`nil` `incoming` always wins, even over a different `existing` value: it is the
    ///   backend's current answer for this station's current canonical key, so it also self-heals
    ///   a stale value (e.g. a community row that was merged or recreated server-side).
    /// - A `nil` `incoming` NEVER erases `existing`. A response without a UUID (no community
    ///   reports yet, a failed fetch, a station that was never looked up) is the absence of
    ///   information, not evidence that the station has no backend row.
    ///
    /// Callers detect "did anything change" with `resolved != existing`, so an unchanged value is
    /// never rewritten (a SwiftData write on a CloudKit-synced model is a sync export).
    static func resolved(existing: UUID?, incoming: UUID?) -> UUID? {
        incoming ?? existing
    }

    /// Whether a stored UUID still describes the station after its identity-bearing fields (name,
    /// address, city, state, zip, coordinates) may have been edited.
    ///
    /// `previousKey`/`currentKey` are `CommunityStationKey.canonicalKey` values taken before and
    /// after the edit. A changed key means the station may now be a different physical place, so
    /// the UUID of the OLD place must not survive: a Price Alert created from a stale UUID would
    /// watch the wrong station. Equal keys (including both `nil`) mean nothing identity-bearing
    /// changed, so the UUID is kept.
    static func retainsID(previousKey: String?, currentKey: String?) -> Bool {
        previousKey == currentKey
    }
}
