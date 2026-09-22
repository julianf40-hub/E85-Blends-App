//
//  NearbyE85LocationRefreshCoordinator.swift
//  EightyFiveBlends
//
//  Keeps the Nearby E85 widget roughly current as the user travels, without requiring the app
//  to be open. Every Core Location fix that reaches StationLocationManager — whether an
//  ordinary foreground one-shot request or a significant-location-change delivery while
//  backgrounded/relaunched — funnels through `handle(location:)`. The manual-refresh "app
//  became active with a pending request" path (see EightyFiveBlendsApp) also funnels through
//  here, via `handle(location:isManualRefresh:true)`.
//
//  Deliberately network-free and price-resolution-free: it never calls NLRStationService and
//  never re-resolves saved/community pricing (that remains StationsView's job as the sole
//  authoritative publisher). It only re-measures distances for the stations already published
//  to the shared App Group cache and republishes when NearbyE85LocationAcceptance.publishDecision
//  says the result is presentation-different enough to be worth it — the same selection rules
//  `NearbyE85Snapshot.make` already enforces (dedupe/sort/cap/radius). This keeps it safe and
//  fast enough to run in the brief background execution window Core Location grants after an
//  SLC-triggered relaunch, with no risk of starting a lengthy network task that gets killed
//  mid-flight.
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
    ///
    /// - Parameter isManualRefresh: True only for the "app became active with a pending manual
    ///   refresh request" path — bypasses the minimum publish interval (an explicit user tap
    ///   shouldn't be silently swallowed by anti-jitter rate limiting) but still requires a
    ///   materially different result to actually publish; see
    ///   NearbyE85LocationAcceptance.publishDecision's own doc comment.
    static func handle(location: CLLocation, cache: NearbyE85Cache = NearbyE85Cache(), now: Date = .now,
                        isManualRefresh: Bool = false) {
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        #if DEBUG
        print("[NearbyE85Location] fix received: accuracy=\(location.horizontalAccuracy)m fixAge=\(now.timeIntervalSince(location.timestamp))s manual=\(isManualRefresh)")
        #endif

        guard let cached = cache.read(now: now), cached.state == .ready else {
            #if DEBUG
            print("[NearbyE85Location] ignored: no ready cached snapshot to reposition")
            #endif
            return
        }

        let quality = NearbyE85LocationAcceptance.fixQuality(
            newLatitude: latitude, newLongitude: longitude, newHorizontalAccuracyMeters: location.horizontalAccuracy,
            newTimestamp: location.timestamp, previousLatitude: cached.userLatitude, previousLongitude: cached.userLongitude,
            previousAcceptedAt: cached.locationAt, now: now)
        #if DEBUG
        print("[NearbyE85Location] fix quality=\(quality)")
        #endif
        guard quality == .acceptable else { return }

        guard let repositioned = reposition(cached: cached, newLatitude: latitude, newLongitude: longitude, locationAt: location.timestamp) else {
            #if DEBUG
            print("[NearbyE85Location] ignored: moved out of range of every cached station; awaiting next app-open refresh")
            #endif
            return
        }

        let movedMiles = cached.userCoordinate.map {
            NearbyE85LocationAcceptance.distanceMiles(fromLatitude: $0.latitude, longitude: $0.longitude,
                                                       toLatitude: latitude, longitude: longitude)
        }
        let decision = NearbyE85LocationAcceptance.publishDecision(
            movedMiles: movedMiles,
            timeSinceLastAccepted: cached.locationAt.map { now.timeIntervalSince($0) },
            timeSinceLastPublish: now.timeIntervalSince(cached.updatedAt),
            previousNearestStationID: cached.stations.first?.id, newNearestStationID: repositioned.stations.first?.id,
            previousNearestDistanceMiles: cached.stations.first?.distanceMiles,
            newNearestDistanceMiles: repositioned.stations.first?.distanceMiles,
            previousStationIDs: Set(cached.stations.map(\.id)), newStationIDs: Set(repositioned.stations.map(\.id)),
            isManualRefresh: isManualRefresh)
        #if DEBUG
        print("[NearbyE85Location] publishDecision=\(decision) previousNearest=\(cached.stations.first?.name ?? "none") candidateNearest=\(repositioned.stations.first?.name ?? "none")")
        #endif
        guard decision == .publish else { return }

        NearbyE85Publisher.publish(repositioned, cache: cache, now: now)
        #if DEBUG
        print("[NearbyE85Location] published repositioned snapshot (WidgetCenter reload requested if it actually changed)")
        #endif
    }

    /// Pure/testable core. Re-measures distance for each already-published station from the
    /// new coordinate, drops any that fall outside the original search radius, and hands the
    /// rest to `NearbyE85Snapshot.make` for the exact same dedupe/sort/cap rules the live
    /// network path already uses. Preserves each station's `price` and `ethanol` untouched — a
    /// location reposition must never alter `priceReportedAt` or a community ethanol reading's
    /// own freshness clock, only the distance. Returns nil if every previously-published
    /// station is now out of range. Called unconditionally (before any publish decision) so that
    /// decision can compare against what the *candidate* presentation would actually look like,
    /// not just how far the user physically moved.
    nonisolated static func reposition(cached: NearbyE85Snapshot, newLatitude: Double, newLongitude: Double,
                                        locationAt: Date) -> NearbyE85Snapshot? {
        let userLocation = CLLocation(latitude: newLatitude, longitude: newLongitude)
        let recomputed = cached.stations.map { station in
            NearbyE85Station(
                id: station.id, name: station.name, address: station.address,
                latitude: station.latitude, longitude: station.longitude,
                distanceMiles: userLocation.distance(from: CLLocation(latitude: station.latitude, longitude: station.longitude)) / 1_609.344,
                price: station.price, ethanol: station.ethanol)
        }
        guard recomputed.contains(where: { $0.distanceMiles <= cached.radiusMiles }) else { return nil }
        return .make(stations: recomputed, radiusMiles: cached.radiusMiles, updatedAt: cached.updatedAt,
                     locationAt: locationAt, userLatitude: newLatitude, userLongitude: newLongitude)
    }
}
