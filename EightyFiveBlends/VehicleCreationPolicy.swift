//
//  VehicleCreationPolicy.swift
//  EightyFiveBlends
//
//  Pure decision logic for 85Blends' Free/Pro vehicle-creation entitlement: Free users may
//  create up to SubscriptionManager.freeVehicleLimit vehicles; Pro users (per
//  SubscriptionManager.canAccessUnlimitedVehicles) may create unlimited vehicles. Kept
//  independent of SwiftUI/SwiftData and of SubscriptionManager's StoreKit/observable plumbing,
//  mirroring VehicleActivation/VehicleOdometerPolicy's separation of pure rules from the views
//  and entitlement source that call them, so the actual rule this feature depends on is
//  directly unit-testable.
//
//  This governs CREATION only. It never governs reading, displaying, editing, or deleting a
//  vehicle, and never governs Fuel Logs, Reminders, Calculator use, At The Pump, or CloudKit
//  synchronization — a Free user who already has more vehicles than the current limit (e.g.
//  after downgrading from Pro, or after CloudKit syncs in vehicles created on another device)
//  keeps every one of them, fully usable, indefinitely. Only creating one more is affected, and
//  only while over the limit. See CLAUDE.md's Cloud Sync product-policy note — this entitlement
//  is deliberately scoped to creation so it can never be read as touching that standing rule.
//

import Foundation

enum VehicleCreationPolicy {
    /// Whether a user may create one more vehicle right now. `canAccessUnlimitedVehicles` users
    /// are always eligible, regardless of count. Otherwise eligible only while `currentCount` is
    /// below `freeLimit`. Evaluated fresh from the current count every call — never cached — so
    /// it re-derives correctly after a delete, a CloudKit sync bringing in more vehicles, or an
    /// entitlement change (purchase, restore, downgrade, or the internal debug override).
    static func canAddVehicle(currentCount: Int, freeLimit: Int, canAccessUnlimitedVehicles: Bool) -> Bool {
        canAccessUnlimitedVehicles || currentCount < freeLimit
    }
}
