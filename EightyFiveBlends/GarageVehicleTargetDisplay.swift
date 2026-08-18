//
//  GarageVehicleTargetDisplay.swift
//  EightyFiveBlends
//
//  Garage-only display resolution for a vehicle's Preferred Ethanol Target — answers "what has
//  the user explicitly configured for THIS vehicle?", a different question from Calculator's
//  "what effective target should the app use right now?"
//  (FuelPreferenceResolution.PreferredTargetResolution).
//
//  The two are intentionally different: a current-semantics vehicle with no configured
//  preference must display "Not set" here even though Calculator/At The Pump/Fuel Log/Trip
//  Planner correctly fall through to an app-level-preference/E30 default for that exact same
//  vehicle. Garage showing "Not set" does NOT mean Calculator should start blank — that
//  distinction is by design, not a bug.
//
//  Do NOT use this for Calculator/At The Pump/Fuel Log/Trip Planner resolution, and do not fold
//  PreferredTargetResolution's app-level-preference/E30 fallback into this type — it only ever
//  reports what is actually stored on the vehicle, or nil. Kept independent of SwiftUI, mirroring
//  VehicleActivation/VehicleOdometerPolicy/FuelPreferenceResolution's separation of pure rules
//  from the views that call them, so this exact rule is directly unit-testable.
//

import Foundation

enum GarageVehicleTargetDisplay {
    /// The ethanol target percent actually configured on `vehicle`, for Garage display only:
    /// - Legacy-semantics vehicle (`calculatorPreferenceSemanticsVersion < .current`): its
    ///   stored `defaultTargetEthanolPercent` — still that vehicle's real, effective legacy
    ///   preference, and always considered configured (never nil) for a legacy vehicle.
    /// - Current-semantics vehicle with a valid (finite, 0...100 — an explicit E0 counts and is
    ///   never treated as unset) stored `preferredEthanolTargetPercent`: that exact value.
    /// - Current-semantics vehicle with a `nil`, non-finite, or out-of-range
    ///   `preferredEthanolTargetPercent`: `nil` — Garage must render "Not set", never a
    ///   Calculator fallback value (app-level preference or E30) and never malformed stored
    ///   data. This UI never rewrites the persisted value on encountering an invalid one.
    static func targetPercent(for vehicle: VehicleProfile) -> Double? {
        if vehicle.calculatorPreferenceSemanticsVersion < VehiclePreferenceSemantics.current {
            return vehicle.defaultTargetEthanolPercent
        }

        guard let preferred = vehicle.preferredEthanolTargetPercent, isValidEthanolPercent(preferred) else {
            return nil
        }

        return preferred
    }
}
