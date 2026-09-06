//
//  NearbyE85LocationAcceptance.swift
//  EightyFiveBlends
//
//  Pure, deterministic acceptance rules for deciding whether a newly-received Core Location
//  fix is worth reacting to for the Nearby E85 widget — shared by the foreground
//  (StationsView) and background/headless (NearbyE85LocationRefreshCoordinator) paths so both
//  apply the exact same anti-jitter thresholds. Deliberately independent of CLLocationManager
//  itself so it can be unit tested without any location simulation.
//

import CoreLocation
import Foundation

nonisolated enum NearbyE85LocationAcceptance {
    /// Below the sensor noise floor for both GPS and significant-location-change fixes — a
    /// movement of a few feet in a parking lot must never trigger a republish. Comfortably
    /// larger than SLC's own ~500 m inherent imprecision.
    static let minimumMovementMiles: Double = 0.5

    /// Even without meaningful movement, a long-stale accepted fix should still refresh so
    /// "Updated Xm ago" stays honest instead of freezing forever once the user stops moving
    /// enough to cross `minimumMovementMiles`.
    static let maximumAcceptedFixAgeForJitterSuppression: TimeInterval = 30 * 60

    /// SLC fixes are coarse by design (frequently several hundred meters); this only screens
    /// out genuinely broken fixes (negative/non-finite accuracy, or several-mile cell-tower-only
    /// fixes), not ordinary SLC imprecision.
    static let maximumAcceptableHorizontalAccuracyMeters: CLLocationAccuracy = 5_000

    enum Decision: Equatable {
        /// No previously-accepted coordinate to compare against — always worth using.
        case accept
        case rejectPoorAccuracy
        case rejectInsignificantMovement
    }

    /// - Parameters:
    ///   - previousLatitude/previousLongitude: The most recently *accepted* coordinate (e.g.
    ///     the widget snapshot's own `userLatitude`/`userLongitude`), not simply the last raw
    ///     fix Core Location happened to deliver.
    ///   - previousAcceptedAt: When that previous coordinate was accepted.
    static func decision(newLatitude: Double, newLongitude: Double, newHorizontalAccuracyMeters: CLLocationAccuracy,
                          newTimestamp: Date, previousLatitude: Double?, previousLongitude: Double?,
                          previousAcceptedAt: Date?, now: Date = .now) -> Decision {
        guard newHorizontalAccuracyMeters.isFinite, newHorizontalAccuracyMeters >= 0,
              newHorizontalAccuracyMeters <= maximumAcceptableHorizontalAccuracyMeters else {
            return .rejectPoorAccuracy
        }
        guard let previousLatitude, let previousLongitude else { return .accept }

        let movedMiles = distanceMiles(fromLatitude: previousLatitude, longitude: previousLongitude,
                                        toLatitude: newLatitude, longitude: newLongitude)
        if movedMiles >= minimumMovementMiles { return .accept }
        if let previousAcceptedAt, now.timeIntervalSince(previousAcceptedAt) >= maximumAcceptedFixAgeForJitterSuppression {
            return .accept
        }
        return .rejectInsignificantMovement
    }

    static func distanceMiles(fromLatitude lat1: Double, longitude lon1: Double,
                               toLatitude lat2: Double, longitude lon2: Double) -> Double {
        CLLocation(latitude: lat1, longitude: lon1).distance(from: CLLocation(latitude: lat2, longitude: lon2)) / 1_609.344
    }
}
