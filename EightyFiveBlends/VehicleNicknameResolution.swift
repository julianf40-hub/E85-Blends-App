//
//  VehicleNicknameResolution.swift
//  EightyFiveBlends
//
//  Runtime safety net for resolving a stored, already-persisted vehicle nickname (e.g.
//  MaintenanceReminder.vehicleName, FuelLogEntry.vehicleName) back to the ONE VehicleProfile it
//  refers to. VehicleNicknamePolicy prevents NEW blank/duplicate nicknames from being saved, but
//  existing users may already have duplicate nicknames from before that existed — this is the
//  fail-closed fallback for that legacy data: a nickname resolves only when it currently matches
//  EXACTLY ONE saved vehicle. Kept independent of SwiftUI/SwiftData, mirroring VehicleActivation/
//  VehicleOdometerPolicy's separation of pure rules from the SwiftData-coupled views that call
//  them.
//
//  Matching is exact-string (not trimmed, not case-insensitive) — the SAME comparison the legacy
//  vehicleName relationship is already matched with everywhere else in the app (GarageView.
//  propagateVehicleRename's `#Predicate { $0.vehicleName == oldName }`, VehicleFuelLogIdentity
//  Resolution). This does not introduce a new, broader normalization that could combine records
//  that were previously distinct.
//

import Foundation

enum VehicleNicknameResolution {
    /// The single VehicleProfile whose nickname exactly matches `nickname`, or `nil` when zero
    /// or more than one vehicle matches. Callers that write to the resolved vehicle (e.g.
    /// RemindersView.completeReminder advancing an odometer) must never fall back to guessing
    /// (first match, arbitrary ordering) when this returns `nil` for an ambiguous name.
    static func uniqueMatch(nickname: String, among vehicles: [VehicleProfile]) -> VehicleProfile? {
        let matches = vehicles.filter { $0.nickname == nickname }
        return matches.count == 1 ? matches.first : nil
    }

    /// True only when `nickname` matches 2+ saved vehicles — the specific "cannot safely resolve,
    /// must not guess" case. Distinct from a legitimate zero-match (no vehicle currently has this
    /// name — e.g. it was renamed or deleted), which callers should keep treating as a normal
    /// "nothing to update" outcome rather than an error to surface.
    static func isAmbiguous(nickname: String, among vehicles: [VehicleProfile]) -> Bool {
        vehicles.filter { $0.nickname == nickname }.count > 1
    }
}
