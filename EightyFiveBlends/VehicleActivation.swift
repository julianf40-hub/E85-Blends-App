//
//  VehicleActivation.swift
//  EightyFiveBlends
//
//  Pure decision logic for keeping VehicleProfile.isActive in a valid state — at least one
//  active vehicle whenever any vehicle exists. Kept independent of SwiftUI/SwiftData, mirroring
//  ReminderScheduling's separation of pure math from the SwiftData-coupled views that call it,
//  so the actual rules this fix depends on are directly unit-testable.
//

import Foundation

enum VehicleActivation {
    /// Whether an edit to a vehicle's "Active" flag should be overridden back to `true` rather
    /// than saved as the user's requested value. True only when the vehicle being edited is
    /// currently active, the requested new value is `false`, and no other vehicle is active —
    /// i.e. saving the requested value as-is would leave zero active vehicles.
    static func shouldKeepActive(
        editedVehicleIsActive: Bool,
        requestedActive: Bool,
        anyOtherVehicleIsActive: Bool
    ) -> Bool {
        editedVehicleIsActive && requestedActive == false && anyOtherVehicleIsActive == false
    }

    /// Whether a view scoped to "the active vehicle" should fall back to showing data across
    /// every vehicle instead of matching against a nonexistent active vehicle. True only when
    /// no vehicle is currently active but at least one vehicle exists — never true when there
    /// are no vehicles at all (a different, already-handled empty state) and never true when an
    /// active vehicle already exists (that case is a normal, honest match/no-match outcome).
    static func shouldFallBackToAllVehicles(hasActiveVehicle: Bool, hasAnyVehicle: Bool) -> Bool {
        hasActiveVehicle == false && hasAnyVehicle
    }
}
