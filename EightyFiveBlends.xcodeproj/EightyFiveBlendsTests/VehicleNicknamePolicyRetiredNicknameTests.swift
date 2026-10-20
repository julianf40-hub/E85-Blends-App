//
//  VehicleNicknamePolicyRetiredNicknameTests.swift
//  EightyFiveBlendsTests
//
//  Tests for VehicleNicknamePolicy's retired-nickname guard (85Blends 2.4.1) — the safeguard
//  against a new/renamed vehicle silently inheriting Fuel Log/maintenance history left behind
//  by a deleted vehicle that used the same nickname. Exercises the exact `validationError(...,
//  orphanedHistoricalNicknameKeysResult:)` overload both GarageView.saveVehicle and
//  AddEditVehicleView call — not a duplicate reimplementation.
//

import Testing
@testable import EightyFiveBlends

struct VehicleNicknamePolicyRetiredNicknameTests {
    // Explicitly typed so `excluding: nil, among: noExistingVehicles` call sites below don't
    // leave Swift unable to infer the generic `ID` type from a bare `[]` literal.
    private static let noExistingVehicles: [(id: Int, nickname: String)] = []

    // MARK: - orphanedHistoricalNicknameKeys

    @Test("A historical name with no matching live vehicle is orphaned")
    func historicalName_noLiveMatch_isOrphaned() {
        let keys = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"],
            amongLiveNicknames: ["Sedan"]
        )
        #expect(keys.contains(VehicleNicknamePolicy.conflictKey("Truck")))
    }

    @Test("A historical name that still matches a live vehicle (even itself, unchanged) is not orphaned")
    func historicalName_matchingLiveVehicle_isNotOrphaned() {
        let keys = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"],
            amongLiveNicknames: ["Truck", "Sedan"]
        )
        #expect(keys.contains(VehicleNicknamePolicy.conflictKey("Truck")) == false)
    }

    @Test("A deleted vehicle with no historical records contributes nothing to the orphaned set")
    func noHistoricalRecords_noOrphanedKeys() {
        let keys = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: [],
            amongLiveNicknames: ["Sedan"]
        )
        #expect(keys.isEmpty)
    }

    @Test("Blank historical names never become reserved")
    func blankHistoricalName_isIgnored() {
        let keys = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["", "   "],
            amongLiveNicknames: []
        )
        #expect(keys.isEmpty)
    }

    // MARK: - validationError(..., orphanedHistoricalNicknameKeysResult:) — creating a new vehicle

    @Test("A genuinely unique nickname with no history at all is allowed")
    func newVehicle_uniqueNicknameNoHistory_isAllowed() {
        let existing: [(id: Int, nickname: String)] = [(1, "Sedan")]
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(historicalVehicleNames: [], amongLiveNicknames: ["Sedan"])
        #expect(
            VehicleNicknamePolicy.validationError(
                for: "Wagon", excluding: nil, among: existing,
                orphanedHistoricalNicknameKeysResult: .success(orphaned)
            ) == nil
        )
    }

    @Test("A live duplicate nickname is still rejected the same way, before the history check ever runs")
    func newVehicle_liveDuplicate_isRejected() {
        let existing: [(id: Int, nickname: String)] = [(1, "Sedan")]
        #expect(
            VehicleNicknamePolicy.validationError(
                for: "Sedan", excluding: nil, among: existing,
                orphanedHistoricalNicknameKeysResult: .success([])
            ) == "Another vehicle already uses this nickname."
        )
    }

    @Test("Creating a new vehicle with a retired nickname that has orphaned Fuel Log history is rejected")
    func newVehicle_retiredNicknameFromFuelLog_isRejected() {
        // "Truck" was deleted; its Fuel Log entries are still vehicleName == "Truck" with no
        // live vehicle. No other vehicle is currently named "Truck".
        let existing: [(id: Int, nickname: String)] = [(1, "Sedan")]
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"], // from FuelLogEntry.vehicleName
            amongLiveNicknames: ["Sedan"]
        )
        let message = VehicleNicknamePolicy.validationError(
            for: "Truck", excluding: nil, among: existing,
            orphanedHistoricalNicknameKeysResult: .success(orphaned)
        )
        #expect(message != nil)
        #expect(message != "Another vehicle already uses this nickname.")
    }

    @Test("Creating a new vehicle with a retired nickname that has orphaned maintenance reminder history is rejected")
    func newVehicle_retiredNicknameFromReminders_isRejected() {
        let existing: [(id: Int, nickname: String)] = []
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"], // from MaintenanceReminder.vehicleName
            amongLiveNicknames: []
        )
        #expect(
            VehicleNicknamePolicy.validationError(
                for: "Truck", excluding: nil, among: existing,
                orphanedHistoricalNicknameKeysResult: .success(orphaned)
            ) != nil
        )
    }

    @Test("Creating a new vehicle with a retired nickname that has orphaned completion-record history is rejected")
    func newVehicle_retiredNicknameFromCompletionRecords_isRejected() {
        let existing: [(id: Int, nickname: String)] = []
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"], // from ReminderCompletionRecord.vehicleName
            amongLiveNicknames: []
        )
        #expect(
            VehicleNicknamePolicy.validationError(
                for: "Truck", excluding: nil, among: existing,
                orphanedHistoricalNicknameKeysResult: .success(orphaned)
            ) != nil
        )
    }

    @Test("A case variant of a retired nickname is also rejected")
    func newVehicle_retiredNicknameCaseVariant_isRejected() {
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"],
            amongLiveNicknames: []
        )
        #expect(
            VehicleNicknamePolicy.validationError(
                for: "TRUCK", excluding: nil, among: Self.noExistingVehicles,
                orphanedHistoricalNicknameKeysResult: .success(orphaned)
            ) != nil
        )
    }

    @Test("A surrounding-whitespace variant of a retired nickname is also rejected")
    func newVehicle_retiredNicknameWhitespaceVariant_isRejected() {
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"],
            amongLiveNicknames: []
        )
        #expect(
            VehicleNicknamePolicy.validationError(
                for: "  Truck  ", excluding: nil, among: Self.noExistingVehicles,
                orphanedHistoricalNicknameKeysResult: .success(orphaned)
            ) != nil
        )
    }

    @Test("Reusing a deleted vehicle's nickname is allowed when that vehicle had no historical records at all")
    func newVehicle_deletedVehicleWithNoHistory_reuseIsAllowed() {
        // "Truck" was deleted, but it never had a single Fuel Log/Reminder/Completion record —
        // nothing for it to have orphaned.
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: [],
            amongLiveNicknames: []
        )
        #expect(
            VehicleNicknamePolicy.validationError(
                for: "Truck", excluding: nil, among: Self.noExistingVehicles,
                orphanedHistoricalNicknameKeysResult: .success(orphaned)
            ) == nil
        )
    }

    // MARK: - Editing an existing vehicle

    @Test("Editing a vehicle without changing its nickname is allowed, even though its own history uses that name")
    func editVehicle_unchangedNicknameOwningItsOwnHistory_isAllowed() {
        // Vehicle 1 is live, named "Truck", and genuinely owns Fuel Log history under "Truck".
        let existing: [(id: Int, nickname: String)] = [(1, "Truck")]
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"],
            amongLiveNicknames: ["Truck"] // vehicle 1 itself
        )
        #expect(
            VehicleNicknamePolicy.validationError(
                for: "Truck", excluding: 1, among: existing,
                orphanedHistoricalNicknameKeysResult: .success(orphaned)
            ) == nil
        )
    }

    @Test("Renaming a vehicle to a genuinely new, unreserved nickname is allowed")
    func renameVehicle_toFreshUniqueName_isAllowed() {
        let existing: [(id: Int, nickname: String)] = [(1, "Truck"), (2, "Sedan")]
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"],
            amongLiveNicknames: ["Truck", "Sedan"]
        )
        #expect(
            VehicleNicknamePolicy.validationError(
                for: "Wagon", excluding: 1, among: existing,
                orphanedHistoricalNicknameKeysResult: .success(orphaned)
            ) == nil
        )
    }

    @Test("Renaming a vehicle into a retired nickname with orphaned history is rejected")
    func renameVehicle_intoRetiredNickname_isRejected() {
        // Vehicle 2 ("Sedan") tries to rename to "Truck" — a name retired by a deleted vehicle
        // whose Fuel Log history is still saved under "Truck".
        let existing: [(id: Int, nickname: String)] = [(2, "Sedan")]
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"],
            amongLiveNicknames: ["Sedan"]
        )
        let message = VehicleNicknamePolicy.validationError(
            for: "Truck", excluding: 2, among: existing,
            orphanedHistoricalNicknameKeysResult: .success(orphaned)
        )
        #expect(message != nil)
        #expect(message != "Another vehicle already uses this nickname.")
    }

    @Test("Ambiguous legacy duplicate live nicknames are still rejected by the existing conflict check, not confused with the history message")
    func renameVehicle_intoAmbiguousLegacyLiveDuplicate_isRejectedByConflict() {
        // Two live vehicles already share "Truck" (legacy data predating VehicleNicknamePolicy).
        // A third vehicle trying to also become "Truck" must hit the live-conflict message.
        let existing: [(id: Int, nickname: String)] = [(1, "Truck"), (2, "Truck"), (3, "Sedan")]
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"],
            amongLiveNicknames: ["Truck", "Truck", "Sedan"]
        )
        #expect(
            VehicleNicknamePolicy.validationError(
                for: "Truck", excluding: 3, among: existing,
                orphanedHistoricalNicknameKeysResult: .success(orphaned)
            ) == "Another vehicle already uses this nickname."
        )
    }

    // MARK: - Fail-closed on fetch failure

    private struct FakeFetchError: Error {}

    @Test("A failed historical-name fetch blocks the save, even when the candidate is otherwise perfectly fine")
    func fetchFailure_blocksSaveEvenForOtherwiseValidCandidate() {
        let message = VehicleNicknamePolicy.validationError(
            for: "Wagon", excluding: nil, among: Self.noExistingVehicles,
            orphanedHistoricalNicknameKeysResult: .failure(FakeFetchError())
        )
        #expect(message != nil)
        #expect(message != "Another vehicle already uses this nickname.")
    }

    @Test("Blank-candidate and live-duplicate checks still run before a fetch failure would matter")
    func fetchFailure_blankCandidateStillReportsBlankFirst() {
        let message = VehicleNicknamePolicy.validationError(
            for: "   ", excluding: nil, among: Self.noExistingVehicles,
            orphanedHistoricalNicknameKeysResult: .failure(FakeFetchError())
        )
        #expect(message == "Enter a vehicle nickname.")
    }

    // MARK: - Determinism (no hidden mutation / side effects)

    @Test("Calling validationError twice with identical inputs yields identical results")
    func validationError_isPureAndDeterministic() {
        let existing: [(id: Int, nickname: String)] = [(1, "Sedan")]
        let orphaned = VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: ["Truck"],
            amongLiveNicknames: ["Sedan"]
        )
        let first = VehicleNicknamePolicy.validationError(
            for: "Truck", excluding: nil, among: existing,
            orphanedHistoricalNicknameKeysResult: .success(orphaned)
        )
        let second = VehicleNicknamePolicy.validationError(
            for: "Truck", excluding: nil, among: existing,
            orphanedHistoricalNicknameKeysResult: .success(orphaned)
        )
        #expect(first == second)
    }
}
