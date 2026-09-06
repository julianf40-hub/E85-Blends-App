//
//  NearbyE85LocationRefreshCoordinator.swift
//  EightyFiveBlends
//
//  Keeps the Nearby E85 widget roughly current as the user travels, without requiring the app
//  to be open. Every Core Location fix that reaches StationLocationManager — whether an
//  ordinary foreground one-shot request or a significant-location-change delivery while
//  backgrounded/relaunched — funnels through `handle(location:)`.
//
//  Deliberately network-free and price-resolution-free: it never calls NRELStationService and
//  never re-resolves saved/community pricing (that remains StationsView's job as the sole
//  authoritative publisher). It only re-measures distances for the stations already published
//  to the shared App Group cache and republishes if the user has moved meaningfully — the same
//  selection rules `NearbyE85Snapshot.make` already enforces (dedupe/sort/cap/radius). This
//  keeps it safe and fast enough to run in the brief background execution window Core Location
//  grants after an SLC-triggered relaunch, with no risk of starting a lengthy network task that
//  gets killed mid-flight.
//
//  If the user has driven far enough that none of the previously-published stations remain
//  within the original search radius, this intentionally does nothing further — inventing a
//  new candidate station without a real network search would require duplicating StationsView's
//  fetch+price-resolution pipeline. The next time the app is opened, the existing
//  scenePhase-active prewarm → live fetch → publish path (StationsView) performs a full,
//  authoritative re-search from the new location.

import CoreLocation
import Foundation

@MainActor
enum NearbyE85LocationRefreshCoordinator {
    /// `cache` defaults to the real App-Group-backed cache; tests inject
    /// `NearbyE85Cache(fileURL:)` pointed at a temporary file instead, exactly like
    /// NearbyE85Tests already does for `NearbyE85Publisher`/`NearbyE85Cache` themselves — this
    /// function never touches the shared container directly.
    static func handle(location: CLLocation, cache: NearbyE85Cache = NearbyE85Cache(), now: Date = .now) {
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        #if DEBUG
        print("[NearbyE85Location] fix received: accuracy=\(location.horizontalAccuracy)m fixAge=\(now.timeIntervalSince(location.timestamp))s")
        #endif

        guard let cached = cache.read(now: now), cached.state == .ready else {
            #if DEBUG
            print("[NearbyE85Location] ignored: no ready cached snapshot to reposition")
            #endif
            return
        }

        let decision = NearbyE85LocationAcceptance.decision(
            newLatitude: latitude, newLongitude: longitude, newHorizontalAccuracyMeters: location.horizontalAccuracy,
            newTimestamp: location.timestamp, previousLatitude: cached.userLatitude, previousLongitude: cached.userLongitude,
            previousAcceptedAt: cached.locationAt, now: now)
        #if DEBUG
        print("[NearbyE85Location] decision=\(decision) previousNearest=\(cached.stations.first?.name ?? "none")")
        #endif
        guard decision == .accept else { return }

        guard let repositioned = reposition(cached: cached, newLatitude: latitude, newLongitude: longitude, locationAt: location.timestamp) else {
            #if DEBUG
            print("[NearbyE85Location] ignored: moved out of range of every cached station; awaiting next app-open refresh")
            #endif
            return
        }

        #if DEBUG
        print("[NearbyE85Location] nearest station: \(cached.stations.first?.name ?? "none") -> \(repositioned.stations.first?.name ?? "none")")
        #endif
        NearbyE85Publisher.publish(repositioned, cache: cache, now: now)
        #if DEBUG
        print("[NearbyE85Location] published repositioned snapshot (WidgetCenter reload requested if it actually changed)")
        #endif
    }

    /// Pure/testable core. Re-measures distance for each already-published station from the
    /// new coordinate, drops any that fall outside the original search radius, and hands the
    /// rest to `NearbyE85Snapshot.make` for the exact same dedupe/sort/cap rules the live
    /// network path already uses. Preserves each station's `price` untouched — a location
    /// reposition must never alter `priceReportedAt`. Returns nil if every previously-published
    /// station is now out of range.
    nonisolated static func reposition(cached: NearbyE85Snapshot, newLatitude: Double, newLongitude: Double,
                                        locationAt: Date) -> NearbyE85Snapshot? {
        let userLocation = CLLocation(latitude: newLatitude, longitude: newLongitude)
        let recomputed = cached.stations.map { station in
            NearbyE85Station(
                id: station.id, name: station.name, address: station.address,
                latitude: station.latitude, longitude: station.longitude,
                distanceMiles: userLocation.distance(from: CLLocation(latitude: station.latitude, longitude: station.longitude)) / 1_609.344,
                price: station.price)
        }
        guard recomputed.contains(where: { $0.distanceMiles <= cached.radiusMiles }) else { return nil }
        return .make(stations: recomputed, radiusMiles: cached.radiusMiles, updatedAt: cached.updatedAt,
                     locationAt: locationAt, userLatitude: newLatitude, userLongitude: newLongitude)
    }
}
