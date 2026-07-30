//
//  VehicleOdometerPolicy.swift
//  EightyFiveBlends
//
//  Pure decision logic for keeping VehicleProfile.currentOdometer forward-only during routine
//  vehicle editing. Kept independent of SwiftUI/SwiftData, mirroring VehicleActivation and
//  ReminderScheduling's separation of pure rules from the SwiftData-coupled views that call
//  them, so the actual rule this fix depends on is directly unit-testable.
//
//  This only governs the general Edit Vehicle form. The dedicated Garage odometer-update sheet
//  (GarageView.saveOdometerUpdate) and reminder completion (ReminderScheduling.advancedOdometer)
//  already enforce their own forward-only comparisons independently and are unchanged here.
//

import Foundation

enum VehicleOdometerPolicy {
    /// True when `requested` is lower than `existing` — a regression that routine vehicle
    /// editing must never persist. Equal or higher values are never a regression.
    static func isRegression(existing: Int, requested: Int) -> Bool {
        requested < existing
    }

    /// The odometer value a routine vehicle edit should actually persist: `requested` if it's
    /// at or above `existing`, otherwise `existing` is kept unchanged. This is the save-boundary
    /// guarantee — it holds even if a UI layer's own validation is ever bypassed or stale.
    static func resolvedOdometerForRoutineEdit(existing: Int, requested: Int) -> Int {
        isRegression(existing: existing, requested: requested) ? existing : requested
    }
}
