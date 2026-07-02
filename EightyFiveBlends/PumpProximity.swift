//
//  PumpProximity.swift
//  EightyFiveBlends
//
//  Decides when the app may auto-suggest "At the Pump" mode based on how close the
//  user is to a saved station. These thresholds are intentionally tiny: they gate the
//  pump-mode suggestion only, and are completely separate from the much larger radii
//  used elsewhere to *search* for stations (e.g. the ~half-mile station detection in
//  the fuel log, or the miles-wide NREL station search). Never reuse those broad
//  search radii for pump-mode triggering.
//

import CoreLocation

enum PumpProximity {
    /// Distance at which the pump-mode suggestion turns ON. ~30 feet — the user should
    /// effectively be inside the station/pump area, not driving past or parked nearby.
    static let atPumpEntryRadiusMeters: CLLocationDistance = 9.0

    /// Distance at which an active pump-mode suggestion turns OFF. ~90 feet. Larger than
    /// the entry radius (hysteresis) so GPS jitter while standing at the pump does not
    /// flicker the suggestion on and off.
    static let atPumpExitRadiusMeters: CLLocationDistance = 27.0

    /// Worst horizontal accuracy (meters) allowed before auto-triggering. A fix coarser
    /// than this (indoor Wi-Fi/cell fixes are often 50–1000 m) cannot reliably say the
    /// user is within the tiny entry radius, so we refuse to change state on it.
    static let maximumPumpModeLocationAccuracyMeters: CLLocationAccuracy = 20.0

    /// Hysteresis decision: given the distance to the nearest saved station and the fix
    /// accuracy, should the pump-mode suggestion be active?
    ///
    /// - Entering requires the tight entry radius; leaving requires the larger exit radius.
    /// - A poor/unknown-accuracy fix keeps the previous state rather than guessing —
    ///   EXCEPT when even its worst-case error still puts the user clearly beyond the
    ///   exit radius, in which case the state clears. Without that escape hatch, one
    ///   good fix at the pump followed by only coarse fixes would pin "at the pump"
    ///   forever (e.g. reopening the app at home on an indoor Wi-Fi fix).
    static func isAtPump(
        distanceMeters: CLLocationDistance,
        horizontalAccuracyMeters: CLLocationAccuracy?,
        wasAtPump: Bool
    ) -> Bool {
        guard let accuracy = horizontalAccuracyMeters,
              accuracy >= 0,
              accuracy <= maximumPumpModeLocationAccuracyMeters else {
            if let accuracy = horizontalAccuracyMeters,
               accuracy >= 0,
               distanceMeters - accuracy > atPumpExitRadiusMeters {
                return false
            }
            return wasAtPump
        }

        let threshold = wasAtPump ? atPumpExitRadiusMeters : atPumpEntryRadiusMeters
        return distanceMeters <= threshold
    }
}
