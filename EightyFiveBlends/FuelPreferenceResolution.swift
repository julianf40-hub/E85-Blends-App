//
//  FuelPreferenceResolution.swift
//  EightyFiveBlends
//
//  Centralized, pure resolution rules for the calculator fuel-preference inputs introduced by
//  the 85Blends 2.3.0 Garage simplification. Prior to 2.3.0, Preferred/Current/Pump/Gas Ethanol
//  were all per-vehicle "Default X Ethanol %" fields edited in Garage. As of 2.3.0:
//
//  - Preferred Ethanol Target is the one field that stays vehicle-scoped, but is now optional —
//    see VehicleProfile.preferredEthanolTargetPercent / .calculatorPreferenceSemanticsVersion.
//  - Current Ethanol is tank/fill *state* (sourced from Fuel Log history), never a vehicle
//    property — VehicleProfile.defaultCurrentEthanolPercent is intentionally not read below.
//  - Pump Ethanol and Gas Ethanol are app-level "remembered" preferences, never vehicle
//    properties — VehicleProfile.defaultPumpEthanolPercent / .gasEthanolPercent are
//    intentionally not read below.
//
//  Kept independent of SwiftUI/SwiftData (mirroring VehicleActivation / VehicleOdometerPolicy's
//  separation of pure rules from the state-coupled views that call them), except for
//  RememberedFuelPreferenceStore, which is the one deliberately-shared UserDefaults access point
//  for the "remembered" values so every call site (Calculator, At The Pump, Cost Calculator)
//  reads/writes the exact same keys with the exact same validation.
//
//  Every calculator-family screen (CalculatorView, AtThePumpView, CostCalculatorView,
//  FuelLogStore, TripPlannerView) resolves these four inputs by calling into this file, so the
//  precedence can never quietly diverge between screens.
//

import Foundation

enum FuelPreferenceDefaults {
    /// Internal, app-wide fallback used only when nothing else (vehicle, app preference,
    /// remembered value) applies. Never a stand-in for "unset" anywhere else in the app — see
    /// each resolver's doc comment below for its exact precedence chain.
    static let targetEthanolPercent: Double = 30
    static let currentEthanolPercent: Double = 10
    static let pumpEthanolPercent: Double = 85
    static let gasEthanolPercent: Double = 10
}

/// VehicleProfile.calculatorPreferenceSemanticsVersion values. An Int (not an enum) on the
/// model itself so a future version could be introduced without a SwiftData/CloudKit schema
/// change — see VehicleProfile.swift.
enum VehiclePreferenceSemantics {
    /// Pre-2.3.0 vehicles (and any vehicle that has never been re-saved through the 2.3.0+ Edit
    /// Vehicle form). `defaultTargetEthanolPercent` is still that vehicle's real, effective
    /// preferred target — existing users must not lose it. Every vehicle that predates this
    /// property reads as `0` automatically once the app updates (SwiftData's lightweight
    /// migration fills the new column with its inline default for every existing row), so no
    /// migration code has to run for this to be correct.
    static let legacy = 0
    /// 2.3.0+: `preferredEthanolTargetPercent` (a true optional) is authoritative for this
    /// vehicle. The legacy `default*`/`gasEthanolPercent` fields are frozen, unread
    /// compatibility columns from this point on — see VehicleProfile.swift.
    static let current = 1
}

/// True only for a finite value in the meaningful 0...100 ethanol-percent range. Used
/// throughout this file so an explicit 0 (a legitimate "pure gasoline" reading) is always
/// treated as present data, while NaN/±infinity/out-of-range values are treated as absent.
private func isValidEthanolPercent(_ value: Double) -> Bool {
    value.isFinite && (0...100).contains(value)
}

private func validEthanolPercent(_ value: Double?) -> Double? {
    guard let value, isValidEthanolPercent(value) else { return nil }
    return value
}

enum AppPreferredTargetBlend {
    /// Parses the persisted `@AppStorage(AppPreferenceKey.defaultTargetBlend)` raw value (e.g.
    /// "E30") into a concrete percent, defaulting to E30 for an unrecognized/corrupt value.
    static func percent(fromRawValue rawValue: String) -> Double {
        Double(rawValue.dropFirst()) ?? FuelPreferenceDefaults.targetEthanolPercent
    }

    /// Reads the current app-level preferred target directly from UserDefaults — for call sites
    /// that resolve it outside a live `@AppStorage`-backed SwiftUI property (FuelLogStore,
    /// AtThePumpView.init, TripPlannerView). CalculatorView instead reads its own `@AppStorage`
    /// binding so its UI stays live-observing; both paths read the same key and share
    /// `percent(fromRawValue:)`, so "E30" means the same thing everywhere.
    static func currentPercent() -> Double {
        let rawValue = UserDefaults.standard.string(forKey: AppPreferenceKey.defaultTargetBlend)
            ?? BlendPreferenceOption.e30.rawValue
        return percent(fromRawValue: rawValue)
    }
}

enum PreferredTargetResolution {
    /// Preferred Ethanol Target precedence:
    /// - Legacy-semantics vehicle: its stored `defaultTargetEthanolPercent` IS the effective
    ///   preference — always honored, never treated as absent, regardless of app preference.
    /// - New-semantics vehicle: `preferredEthanolTargetPercent` if present and valid, else the
    ///   app-level preferred target, else E30.
    /// - No vehicle selected: the app-level preferred target, else E30.
    static func resolve(vehicle: VehicleProfile?, appPreferredTarget: Double) -> Double {
        let appLevelOrDefault = validEthanolPercent(appPreferredTarget) ?? FuelPreferenceDefaults.targetEthanolPercent

        guard let vehicle else {
            return appLevelOrDefault
        }

        if vehicle.calculatorPreferenceSemanticsVersion < VehiclePreferenceSemantics.current {
            return vehicle.defaultTargetEthanolPercent
        }

        return validEthanolPercent(vehicle.preferredEthanolTargetPercent) ?? appLevelOrDefault
    }
}

enum TankSizeResolution {
    /// Tank size precedence (audit item 4/7) — a selected vehicle's own capacity if it has one,
    /// else whatever the calculator screen already had. A selected vehicle with no known tank
    /// capacity must never be silently treated as a real number (e.g. 16 gallons) — that's the
    /// gap this specifically closes for At The Pump. `0`/`nil` mean "not entered" for both
    /// inputs, matching VehicleProfile.tankSizeGallons/VehicleDraft's own sentinel: a real tank
    /// is never physically 0 gallons, so this is a safe, unambiguous sentinel (unlike an ethanol
    /// percent, where 0 is a real, meaningful value and must never be treated this way).
    static func resolve(vehicleTankSizeGallons: Double?, calculatorTankSizeGallons: Double) -> Double {
        if let vehicleTankSizeGallons, vehicleTankSizeGallons.isFinite, vehicleTankSizeGallons > 0 {
            return vehicleTankSizeGallons
        }
        return calculatorTankSizeGallons
    }
}

enum CurrentEthanolResolution {
    /// Current Ethanol precedence — tank/fill *state*, never a vehicle-permanent property:
    /// 1. the latest valid Fuel Log blend for the selected vehicle, 2. E10.
    ///
    /// `latestLoggedBlendPercent` must already be scoped to the vehicle being resolved for (see
    /// CalculatorView.lastLoggedBlendForActiveVehicle) — this function never accepts a
    /// vehicle-agnostic "last known" value, so switching vehicles can never leak one vehicle's
    /// current ethanol into another's.
    static func resolve(latestLoggedBlendPercent: Double?) -> Double {
        validEthanolPercent(latestLoggedBlendPercent) ?? FuelPreferenceDefaults.currentEthanolPercent
    }
}

enum PumpEthanolResolution {
    /// Pump Ethanol precedence — pump/session state, never a vehicle-permanent property:
    /// 1. the remembered last-used pump ethanol content (see RememberedFuelPreferenceStore),
    /// 2. E85.
    static func resolve(remembered: Double?) -> Double {
        validEthanolPercent(remembered) ?? FuelPreferenceDefaults.pumpEthanolPercent
    }
}

enum GasEthanolResolution {
    /// Gas Ethanol precedence — an app-level advanced setting, never a vehicle-permanent
    /// property: 1. the remembered app-level Gas Ethanol setting, 2. E10.
    static func resolve(remembered: Double?) -> Double {
        validEthanolPercent(remembered) ?? FuelPreferenceDefaults.gasEthanolPercent
    }
}

/// Reads/writes the app-level "remembered" pump and gas ethanol values shared by every
/// calculator surface (main Calculator tab, At The Pump, Cost Calculator). Centralized here so
/// every call site validates with the exact same range and reads/writes the exact same
/// UserDefaults keys.
enum RememberedFuelPreferenceStore {
    // Reuses At The Pump's pre-existing "last pump E85 content" key/range so this doesn't become
    // a second, conflicting memory — the main Calculator tab now reads AND writes it too, so
    // both screens share one memory (see AppPreferenceKey.lastPumpE85Content).
    private static let pumpEthanolRange: ClosedRange<Double> = 40...98

    // No prior memory existed for Gas Ethanol anywhere in the app.
    private static let gasEthanolRange: ClosedRange<Double> = 0...100

    static func rememberedPumpEthanolPercent() -> Double? {
        validated(AppPreferenceKey.lastPumpE85Content, pumpEthanolRange)
    }

    static func rememberPumpEthanolPercent(_ value: Double) {
        UserDefaults.standard.set(value, forKey: AppPreferenceKey.lastPumpE85Content)
    }

    static func rememberedGasEthanolPercent() -> Double? {
        validated(AppPreferenceKey.rememberedGasEthanolPercent, gasEthanolRange)
    }

    static func rememberGasEthanolPercent(_ value: Double) {
        UserDefaults.standard.set(value, forKey: AppPreferenceKey.rememberedGasEthanolPercent)
    }

    private static func validated(_ key: String, _ range: ClosedRange<Double>) -> Double? {
        guard let value = UserDefaults.standard.object(forKey: key) as? Double,
              value.isFinite,
              range.contains(value) else {
            return nil
        }
        return value
    }
}
