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
    /// Distance at which the pump-mode suggestion turns ON. ~100 feet.
    ///
    /// Was 9 m (~30 ft) — confirmed too tight against real device behavior: physically
    /// visiting saved E85 stations produced neither a background notification nor the
    /// in-app prompt. 9 m required the sum of (a) live GPS error, which is commonly
    /// 10-30+ m under a metal fuel-pump canopy (multipath), and (b) the saved station's own
    /// coordinate error (geocoded addresses are frequently 10-30 m off the actual pump
    /// island) to together stay under roughly one car length — essentially never true in
    /// practice. 30 m absorbs realistic canopy-degraded GPS plus geocoding offset while
    /// still requiring genuine physical presence at a specific station rather than "in the
    /// same parking lot" or "driving past on an adjacent road."
    static let atPumpEntryRadiusMeters: CLLocationDistance = 30.0

    /// Distance at which an active pump-mode suggestion turns OFF. ~245 feet. Larger than
    /// the entry radius (hysteresis, ~2.5x) so GPS jitter while standing at the pump does
    /// not flicker the suggestion on and off. Was 27 m; scaled up with the entry radius
    /// change above to preserve the same hysteresis ratio.
    static let atPumpExitRadiusMeters: CLLocationDistance = 75.0

    /// Worst horizontal accuracy (meters) allowed before auto-triggering. A fix coarser
    /// than this (indoor Wi-Fi/cell fixes are often 50-1000+ m) cannot reliably say the
    /// user is within the entry radius, so we refuse to change state on it.
    ///
    /// Was 20 m — also confirmed too strict: outdoor GPS accuracy near a station canopy
    /// commonly reports 20-50 m, so a real at-the-pump fix was frequently rejected by this
    /// gate before distance was ever evaluated. 50 m still firmly excludes genuinely coarse
    /// Wi-Fi/cell-tower fixes (hundreds of meters or more) while accepting realistic
    /// canopy-degraded outdoor GPS.
    static let maximumPumpModeLocationAccuracyMeters: CLLocationAccuracy = 50.0

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

    /// Short, human-readable reason `isAtPump` would return `false` for these inputs, or
    /// `nil` if it would return `true`. Pure and side-effect-free — used only to power
    /// DEBUG/INTERNAL_BUILD-only diagnostics (see StationsView's pump-detection debug
    /// section), never shown in production Release UI. Deliberately reports only distance
    /// and accuracy figures, never raw coordinates.
    static func rejectionReason(
        distanceMeters: CLLocationDistance,
        horizontalAccuracyMeters: CLLocationAccuracy?,
        wasAtPump: Bool
    ) -> String? {
        guard isAtPump(distanceMeters: distanceMeters, horizontalAccuracyMeters: horizontalAccuracyMeters, wasAtPump: wasAtPump) == false else {
            return nil
        }

        guard let accuracy = horizontalAccuracyMeters, accuracy >= 0 else {
            return "No reliable location fix yet"
        }
        guard accuracy <= maximumPumpModeLocationAccuracyMeters else {
            return "Accuracy \(Int(accuracy))m (need \u{2264}\(Int(maximumPumpModeLocationAccuracyMeters))m)"
        }

        let threshold = wasAtPump ? atPumpExitRadiusMeters : atPumpEntryRadiusMeters
        return "\(Int(distanceMeters))m away (need \u{2264}\(Int(threshold))m)"
    }
}

/// Pure decision logic for CalculatorView's "At the Pump?" auto-prompt suppression —
/// extracted so the visit-based (not permanent, not calendar-based) suppression rule is
/// unit-testable independent of SwiftUI @State. CalculatorView's evaluateAutoPromptPumpMode()
/// calls `shouldPrompt` directly rather than duplicating this condition; its
/// clearPumpModeStation() resets `hasPromptedForCurrentPumpVisit` itself (a plain state
/// reset, not conditional logic, so it isn't wrapped here).
enum PumpVisitPromptPolicy {
    /// Whether the auto-prompt should fire right now, given a station is within range.
    ///
    /// - `hasPromptedForCurrentVisit`: true once the prompt has already fired since the user
    ///   last arrived — reset to false whenever they leave the station's exit radius, so a
    ///   later, separate visit (even within the same app session) is eligible again. This is
    ///   what makes suppression per-visit rather than a permanent once-per-launch flag or a
    ///   calendar-based cooldown.
    /// - `isAuthorized`: the live foreground path requires at least When In Use authorization;
    ///   without it there's no trustworthy fix to have proven proximity in the first place.
    static func shouldPrompt(hasPromptedForCurrentVisit: Bool, isAuthorized: Bool) -> Bool {
        hasPromptedForCurrentVisit == false && isAuthorized
    }
}
