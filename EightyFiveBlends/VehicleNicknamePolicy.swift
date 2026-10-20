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
    ///
    /// Internal (not private) so the retired-nickname guard below can reuse the exact same
    /// comparison — a case/whitespace variant of a retired name must be caught the same way a
    /// case/whitespace variant of a live duplicate already is.
    static func conflictKey(_ nickname: String) -> String {
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

    // MARK: - Retired-nickname guard (85Blends 2.4.1)
    //
    // Garage vehicle deletion intentionally never touches FuelLogEntry/MaintenanceReminder/
    // ReminderCompletionRecord — there is no @Relationship between VehicleProfile and those
    // models, only the legacy vehicleName == nickname string match (see
    // GarageView.confirmDeletion, VehicleFuelLogIdentityResolution). That's correct for
    // preserving history, but it means a deleted vehicle's historical records are left behind
    // with no live owner. If a NEW vehicle is later saved with that same (or a case/whitespace
    // variant) nickname, every exact-string match elsewhere in the app would silently treat it
    // as the owner of history it never actually generated. This section exists purely to block
    // that reattachment at the point a nickname is saved — it never claims, reassigns, renames,
    // or deletes any historical record itself.

    /// The retired-nickname comparison keys (see `conflictKey`) that are currently "reserved":
    /// present on at least one historical Fuel Log/Reminder/Completion record whose vehicleName
    /// does NOT EXACTLY match any currently live vehicle's nickname. A name that still exactly
    /// matches a live vehicle (even the one being edited, keeping its own unchanged nickname) is
    /// never reserved — that history legitimately belongs to that vehicle today, not to an
    /// orphan.
    ///
    /// Ownership here is deliberately decided by EXACT string equality, not `conflictKey` — the
    /// same exact-string comparison that actually determines ownership everywhere else in the
    /// app (`GarageView.propagateVehicleRename`'s `#Predicate { $0.vehicleName == oldName }`,
    /// `VehicleNicknameResolution`, `VehicleFuelLogIdentityResolution`). Using the broader,
    /// case/whitespace-insensitive `conflictKey` for this ownership check would be wrong: if a
    /// live vehicle "Truck" coexists with genuinely orphaned history already stored as "truck",
    /// `conflictKey`-based ownership would treat "truck" as already owned by "Truck" — so
    /// renaming "Truck" to "truck" would pass this guard, and `propagateVehicleRename`'s exact
    /// rename would then move "Truck"'s own history onto "truck", merging it with the orphaned
    /// "truck" records it never actually owned. `conflictKey` is still the right (broader)
    /// comparison for the *candidate* side below — catching a case/whitespace variant of a
    /// retired name — just not for deciding what already counts as "owned."
    ///
    /// Pure: callers are responsible for fetching `historicalVehicleNames` (every vehicleName,
    /// with duplicates, from all three history models) and `liveNicknames` (every currently
    /// saved VehicleProfile's nickname, including the one being edited) via SwiftData — this
    /// function performs no I/O itself.
    static func orphanedHistoricalNicknameKeys(
        historicalVehicleNames: [String],
        amongLiveNicknames liveNicknames: [String]
    ) -> Set<String> {
        let liveExactNames = Set(liveNicknames.filter { isBlank($0) == false })
        var orphanedKeys = Set<String>()
        for name in historicalVehicleNames where isBlank(name) == false {
            if liveExactNames.contains(name) == false {
                orphanedKeys.insert(conflictKey(name))
            }
        }
        return orphanedKeys
    }

    /// True when `candidate` matches (same comparison as `conflicts`) a retired, orphaned
    /// historical nickname.
    static func isReservedByHistory(candidate: String, orphanedHistoricalNicknameKeys: Set<String>) -> Bool {
        guard isBlank(candidate) == false else { return false }
        return orphanedHistoricalNicknameKeys.contains(conflictKey(candidate))
    }

    /// Overload of `validationError` that also enforces the retired-nickname guard. Takes a
    /// `Result` rather than a plain `Set<String>` so a failed SwiftData fetch of historical
    /// vehicleName values can never be silently treated as "nothing is reserved" — a fetch
    /// failure fails CLOSED (blocks the save with an actionable message) rather than fail-open
    /// (skipping the check it was supposed to perform). This is the one function GarageView.
    /// saveVehicle and AddEditVehicleView both call, so both the editor's live hint and the
    /// authoritative save boundary make the exact same decision.
    static func validationError<ID: Hashable>(
        for candidate: String,
        excluding editingID: ID?,
        among existingVehicles: [(id: ID, nickname: String)],
        orphanedHistoricalNicknameKeysResult: Result<Set<String>, Error>
    ) -> String? {
        guard isBlank(candidate) == false else {
            return "Enter a vehicle nickname."
        }
        guard conflicts(candidate: candidate, excluding: editingID, among: existingVehicles) == false else {
            return "Another vehicle already uses this nickname."
        }
        switch orphanedHistoricalNicknameKeysResult {
        case .failure:
            return "Couldn't verify this nickname against your saved Fuel Log and maintenance history. Please try again."
        case .success(let orphanedHistoricalNicknameKeys):
            guard isReservedByHistory(candidate: candidate, orphanedHistoricalNicknameKeys: orphanedHistoricalNicknameKeys) == false else {
                return "This nickname was used by a vehicle you removed, and its Fuel Log or maintenance history is still saved under that name. Choose a different nickname to avoid mixing histories."
            }
            return nil
        }
    }
}
