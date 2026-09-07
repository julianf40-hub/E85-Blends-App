//
//  NearbyE85LocationAcceptance.swift
//  EightyFiveBlends
//
//  Pure, deterministic acceptance rules for deciding whether a newly-received Core Location
//  fix is worth reacting to for the Nearby E85 widget — shared by the foreground
//  (StationsView) and background/headless (NearbyE85LocationRefreshCoordinator) paths so both
//  apply the exact same rules. Deliberately independent of CLLocationManager itself so it can
//  be unit tested without any location simulation.
//
//  Split into two independent questions:
//   1. `fixQuality` — is this delivered fix even worth looking at (accurate enough, not stale,
//      not a redelivery of one we've already accepted)? Purely about the fix itself.
//   2. `publishDecision` — given a fix that passed (1), would actually publishing it change
//      anything the widget shows? This is the hybrid policy: raw movement is only ONE signal
//      among several (nearest-station identity, the visible station cluster, and the nearest
//      station's own displayed distance all matter just as much), plus a minimum publish
//      interval so ordinary driving doesn't reload the widget every few seconds.
//

import CoreLocation
import Foundation

nonisolated enum NearbyE85LocationAcceptance {
    // MARK: - Fix quality

    /// SLC fixes are coarse by design (frequently several hundred meters); this only screens
    /// out genuinely broken fixes (negative/non-finite accuracy, or several-mile cell-tower-only
    /// fixes), not ordinary SLC imprecision.
    static let maximumAcceptableHorizontalAccuracyMeters: CLLocationAccuracy = 5_000

    /// A fix already this old *at the moment we receive it* is not worth trusting as "the
    /// user's current position" — reject it outright rather than repositioning against stale
    /// data. Distinct from `staleAcceptedLocationAge` below, which measures the age of our own
    /// last-*accepted* fix, not the age of the one just delivered.
    static let maximumFixAgeAtReceipt: TimeInterval = 10 * 60

    /// Two fixes within this many meters of each other, where the new one isn't chronologically
    /// newer than the last accepted one, are the same underlying fix (or an app-relaunch
    /// redelivery of it) — not a redundant "wait a while" jitter case, a `Decision` doesn't even
    /// apply here since there's nothing to decide.
    static let duplicateFixToleranceMeters: CLLocationAccuracy = 5

    enum FixQualityDecision: Equatable {
        case acceptable
        case rejectPoorAccuracy
        case rejectStaleFix
        case rejectDuplicateFix
    }

    /// - Parameters:
    ///   - previousLatitude/previousLongitude/previousAcceptedAt: The most recently *accepted*
    ///     coordinate/time (e.g. the widget snapshot's own `userLatitude`/`userLongitude`/
    ///     `locationAt`), not simply the last raw fix Core Location happened to deliver.
    static func fixQuality(newLatitude: Double, newLongitude: Double, newHorizontalAccuracyMeters: CLLocationAccuracy,
                            newTimestamp: Date, previousLatitude: Double?, previousLongitude: Double?,
                            previousAcceptedAt: Date?, now: Date = .now) -> FixQualityDecision {
        guard newHorizontalAccuracyMeters.isFinite, newHorizontalAccuracyMeters >= 0,
              newHorizontalAccuracyMeters <= maximumAcceptableHorizontalAccuracyMeters else {
            return .rejectPoorAccuracy
        }
        guard now.timeIntervalSince(newTimestamp) <= maximumFixAgeAtReceipt else {
            return .rejectStaleFix
        }
        if let previousLatitude, let previousLongitude, let previousAcceptedAt, newTimestamp <= previousAcceptedAt {
            let movedMeters = CLLocation(latitude: previousLatitude, longitude: previousLongitude)
                .distance(from: CLLocation(latitude: newLatitude, longitude: newLongitude))
            if movedMeters <= duplicateFixToleranceMeters { return .rejectDuplicateFix }
        }
        return .acceptable
    }

    // MARK: - Publish decision (the hybrid policy)

    /// >= this much movement is always worth publishing on its own, no presentation check needed.
    static let largeMovementMiles: Double = 0.5
    /// Below this floor, movement alone never counts for anything — sensor noise, not travel.
    /// (~250 ft.) Only a nearest-station change, a cluster change, or the time-based override
    /// below can still justify a publish at this scale.
    static let jitterFloorMiles: Double = 250.0 / 5_280.0
    /// Documents the "moderate movement" band from the product spec (~250–1000 ft) — not a
    /// separate branch in the logic below; movement anywhere between `jitterFloorMiles` and
    /// `largeMovementMiles` is treated uniformly and only accepted alongside a material
    /// presentation change (see `isMaterialDistanceChange`).
    static let moderateMovementUpperBoundMiles: Double = 1_000.0 / 5_280.0
    /// Documents the "meaningful movement" band (~0.2–0.3 mi) for the same reason.
    static let meaningfulMovementUpperBoundMiles: Double = 0.3

    /// The nearest station's displayed distance changing by at least this much (absolute)...
    static let materialDistanceChangeAbsoluteMiles: Double = 0.2
    /// ...or by at least this fraction of its previous value (relative) counts as a material,
    /// user-visible change even if the raw movement that caused it was small.
    static let materialDistanceChangeRelativeFraction: Double = 0.18

    /// A last-accepted fix older than this is worth refreshing even without meaningful movement,
    /// so "Updated Xm ago" stays honest instead of freezing once the user stops moving enough to
    /// cross `largeMovementMiles`. (Was 30 min; tightened per product feedback that the widget
    /// felt stale too often while actively driving between two nearby places.)
    static let staleAcceptedLocationAge: TimeInterval = 12 * 60

    /// Do not reload the widget more often than this for ordinary same-station movement —
    /// bypassed when the nearest station changes, the visible cluster changes, or the current
    /// data is already past `staleAcceptedLocationAge` (see `bypassesRateLimit` below), and
    /// always bypassed for an explicit manual refresh tap.
    static let minimumPublishInterval: TimeInterval = 3 * 60

    enum PublishDecision: Equatable {
        case publish
        case suppressInsignificantMovement
        case suppressRateLimited
    }

    /// - Parameters:
    ///   - movedMiles: Distance from the last *accepted* coordinate to the candidate one, or
    ///     `nil` when there is no previous accepted coordinate at all (first-ever fix — always
    ///     published).
    ///   - timeSinceLastAccepted/timeSinceLastPublish: Both measured against `now` by the
    ///     caller; `nil` when there's nothing previous to compare against.
    ///   - previousNearestStationID/newNearestStationID: The `id` of `stations.first` before and
    ///     after the candidate fix (already sorted/capped by `NearbyE85Snapshot.make`).
    ///   - previousNearestDistanceMiles/newNearestDistanceMiles: Only meaningful when the nearest
    ///     station *hasn't* changed — the same station's displayed distance, before and after.
    ///   - previousStationIDs/newStationIDs: The full visible set (not just the nearest), so a
    ///     station dropping out of or entering the list counts even if the nearest one is
    ///     unaffected.
    ///   - isManualRefresh: An explicit user-initiated refresh tap bypasses the minimum publish
    ///     interval (rate limiting is an anti-jitter measure for *automatic* background updates,
    ///     not a reason to ignore a deliberate one-time request) — it does NOT bypass the content
    ///     check above rate limiting: a manual refresh with nothing materially different still
    ///     stays honestly stale, it just isn't throttled if it *does* have something to publish.
    static func publishDecision(movedMiles: Double?, timeSinceLastAccepted: TimeInterval?,
                                 timeSinceLastPublish: TimeInterval?,
                                 previousNearestStationID: String?, newNearestStationID: String?,
                                 previousNearestDistanceMiles: Double?, newNearestDistanceMiles: Double?,
                                 previousStationIDs: Set<String>, newStationIDs: Set<String>,
                                 isManualRefresh: Bool = false) -> PublishDecision {
        guard let movedMiles else { return .publish }

        let nearestStationChanged = previousNearestStationID != newNearestStationID
        let clusterChanged = previousStationIDs != newStationIDs
        let materialDistanceChange = isMaterialDistanceChange(
            nearestStationChanged: nearestStationChanged,
            previousDistanceMiles: previousNearestDistanceMiles, newDistanceMiles: newNearestDistanceMiles)
        let accumulatedTimeExceeded = (timeSinceLastAccepted ?? .infinity) >= staleAcceptedLocationAge

        let contentWarrantsRefresh =
            nearestStationChanged || clusterChanged || accumulatedTimeExceeded ||
            movedMiles >= largeMovementMiles ||
            (movedMiles >= jitterFloorMiles && materialDistanceChange)
        guard contentWarrantsRefresh else { return .suppressInsignificantMovement }

        let bypassesRateLimit = isManualRefresh || nearestStationChanged || clusterChanged || accumulatedTimeExceeded
        if let timeSinceLastPublish, timeSinceLastPublish < minimumPublishInterval, !bypassesRateLimit {
            return .suppressRateLimited
        }
        return .publish
    }

    private static func isMaterialDistanceChange(nearestStationChanged: Bool, previousDistanceMiles: Double?,
                                                   newDistanceMiles: Double?) -> Bool {
        guard !nearestStationChanged, let previousDistanceMiles, let newDistanceMiles else { return false }
        let delta = abs(newDistanceMiles - previousDistanceMiles)
        if delta >= materialDistanceChangeAbsoluteMiles { return true }
        guard previousDistanceMiles > 0 else { return false }
        return delta / previousDistanceMiles >= materialDistanceChangeRelativeFraction
    }

    static func distanceMiles(fromLatitude lat1: Double, longitude lon1: Double,
                               toLatitude lat2: Double, longitude lon2: Double) -> Double {
        CLLocation(latitude: lat1, longitude: lon1).distance(from: CLLocation(latitude: lat2, longitude: lon2)) / 1_609.344
    }
}
