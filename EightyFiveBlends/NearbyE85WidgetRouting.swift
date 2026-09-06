//
//  NearbyE85WidgetRouting.swift
//  EightyFiveBlends
//
//  Pure decision step for a parsed Nearby E85 widget deep link — no UIApplication/UIKit side
//  effects, so the routing decision itself (as opposed to actually handing off to a map app or
//  switching tabs) is directly unit testable. ContentView.openPendingWidgetLink() resolves an
//  Outcome here, then performs it: this keeps ContentView's own code a thin dispatcher rather
//  than duplicating "which station, which map app, what if it's missing" decisions inline.
//

import Foundation

@MainActor
enum NearbyE85WidgetRouting {
    enum Outcome: Equatable {
        /// `.stations`, or a `.directions` request that resolved to nothing actionable (station
        /// no longer in the cache, or the widget wasn't authorized) — the tab switch that
        /// already happened in ContentView before this was resolved is the whole result.
        case switchToStations
        /// Hand off directly to the user's preferred map app — no intermediate screen.
        case openDirections(MapsRoutingDestination)
        /// The station exists but lacks enough location info for a direct handoff (should be
        /// unreachable in practice — snapshot stations are coordinate-validated at publish time
        /// — but a corrupted/stale cache shouldn't crash or silently no-op instead of showing
        /// something useful).
        case showStationDetail(NearbyE85Station, NearbyE85Snapshot)
    }

    static func resolve(_ destination: NearbyE85DeepLink.Destination, snapshot: NearbyE85Snapshot?,
                         isAuthorized: Bool) -> Outcome {
        switch destination {
        case .stations:
            return .switchToStations
        case .directions(let stationID):
            guard isAuthorized, let snapshot, let station = snapshot.stations.first(where: { $0.id == stationID }) else {
                return .switchToStations
            }
            let mapsDestination = MapsRoutingDestination(
                name: station.name, streetAddress: station.address, city: "", state: "", zip: "",
                latitude: station.latitude, longitude: station.longitude)
            guard mapsDestination.coordinate != nil || mapsDestination.addressQuery != nil else {
                return .showStationDetail(station, snapshot)
            }
            return .openDirections(mapsDestination)
        }
    }
}
