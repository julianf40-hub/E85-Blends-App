//
//  VehicleNicknamePolicy.swift
//  EightyFiveBlends
//
//  Pure decision logic for whether a vehicle nickname is safe to SAVE — blank/whitespace-only
//  rejection and conflict detection against other saved vehicles. Kept independent of SwiftUI/
//  SwiftData, mirroring VehicleActivation/VehicleOdometerPolicy's separation of pure rules from
//  the SwiftData-coupled views that call them, so the actual rules AddEditVehicleView and
//  GarageView.saveVehicle depend on are directly unit-testable.
//
//  85Blends 2.3.0 release-blocker fix: prior to this file, Garage accepted blank and duplicate
//  nicknames with no validation at all, which is unsafe for the legacy, exact-string
//  FuelLogEntry/MaintenanceReminder/ReminderCompletionRecord.vehicleName == VehicleProfile.
//  nickname relationship (see VehicleFuelLogIdentityResolution and VehicleNicknameResolution).
//  This is PREVENTION for new/edited vehicles; VehicleNicknameResolution is the separate runtime
//  safety net for vehicles that already have a duplicate nickname from before this existed.
//

import Foundation

enum VehicleNicknamePolicy {
    /// The value that actually gets persisted: leading/trailing whitespace and newlines
    /// trimmed. Deliberately does NOT lowercase, collapse internal whitespace, or perform any
    /// Unicode normalization — nothing about what the user typed is altered beyond trimming.
    static func normalizedForSave(_ nickname: String) -> String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `nickname` carries no real name after trimming — empty, or made only of
    /// whitespace/newlines.
    static func isBlank(_ nickname: String) -> Bool {
        normalizedForSave(nickname).isEmpty
    }

    /// Comparison key used ONLY to detect a save-time conflict between two nicknames — trimmed
    /// and lowercased, so "Charger" / "charger" / " Charger " are all treated as the same
    /// identity for this purpose. This is deliberately a different, narrower comparison than
    /// VehicleFuelLogIdentityResolution's exact-string Fuel Log lookup key: this function decides
    /// whether a nickname is safe to SAVE, it never changes how a nickname is actually persisted
    /// or how existing Fuel Log/Reminder records are matched against it.
    private static func conflictKey(_ nickname: String) -> String {
        normalizedForSave(nickname).lowercased()
    }

    /// True when `candidate` — the nickname about to be saved — matches (case-insensitively,
    /// trimmed) any OTHER vehicle in `existingVehicles`. `editingID` should be the id of the
    /// vehicle currently being edited (so it's excluded from conflicting with its own unchanged
    /// nickname); pass `nil` when creating a brand-new vehicle. `existingVehicles` should include
    /// every saved vehicle, including the one being edited — exclusion is handled here via
    /// `editingID`, not by the caller pre-filtering the list.
    static func conflicts<ID: Hashable>(
        candidate: String,
        excluding editingID: ID?,
        among existingVehicles: [(id: ID, nickname: String)]
    ) -> Bool {
        let candidateKey = conflictKey(candidate)
        return existingVehicles.contains { other in
            other.id != editingID && conflictKey(other.nickname) == candidateKey
        }
    }

    /// The actionable, non-technical validation message for `candidate`, or `nil` when it's safe
    /// to save. Checks blank before conflict, matching the order a user would fix problems in.
    static func validationError<ID: Hashable>(
        for candidate: String,
        excluding editingID: ID?,
        among existingVehicles: [(id: ID, nickname: String)]
    ) -> String? {
        guard isBlank(candidate) == false else {
            return "Enter a vehicle nickname."
        }
        guard conflicts(candidate: candidate, excluding: editingID, among: existingVehicles) == false else {
            return "Another vehicle already uses this nickname."
        }
        return nil
    }
}
