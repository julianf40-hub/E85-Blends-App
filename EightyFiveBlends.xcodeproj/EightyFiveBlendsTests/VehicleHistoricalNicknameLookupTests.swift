//
//  VehicleHistoricalNicknameLookupTests.swift
//  EightyFiveBlendsTests
//
//  Tests for VehicleHistoricalNicknameLookup — the shared SwiftData fetch GarageView.saveVehicle
//  and OnboardingView.completeOnboarding both call before deciding a nickname via
//  VehicleNicknamePolicy. Unlike every other file in this directory, this exercises a REAL,
//  in-memory SwiftData ModelContainer/ModelContext rather than hand-built arrays, so the actual
//  fetch-and-aggregate step (not just the pure policy downstream of it) is proven, not mocked.
//  This is new coverage: VehicleNicknamePolicyRetiredNicknameTests.swift already proves the pure
//  decision exhaustively; what it cannot prove is that the real FetchDescriptor-based lookup
//  feeds that decision correctly from genuine FuelLogEntry/MaintenanceReminder/
//  ReminderCompletionRecord/VehicleProfile rows.
//
//  Scope note: OnboardingView.completeOnboarding's OWN gating (shouldCreateVehicle, canFinishOnboarding)
//  is SwiftUI/@AppStorage-coupled private view state, not extracted into a pure/testable function
//  (unlike VehicleNicknamePolicy et al.) — instantiating the full view to exercise it would mean
//  driving AppStorage/environment/sheet state, which no test in this codebase does. What IS
//  tested here is the exact shared decision call (VehicleHistoricalNicknameLookup +
//  VehicleNicknamePolicy.validationError) OnboardingView.completeOnboarding makes once it decides
//  to attempt creation — the same call GarageView.saveVehicle makes.
//

import Foundation
import SwiftData
import Testing
@testable import EightyFiveBlends

struct VehicleHistoricalNicknameLookupTests {
    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([
            VehicleProfile.self,
            FuelLogEntry.self,
            MaintenanceReminder.self,
            ReminderCompletionRecord.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    // MARK: - Normal first-launch creation (no history, no other vehicles)

    @Test("First-launch onboarding with no existing history or vehicles: a unique nickname is allowed")
    func firstLaunch_noHistoryNoVehicles_uniqueNickname_isAllowed() throws {
        let context = try makeInMemoryContext()

        let orphanedResult = VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeysResult(
            modelContext: context,
            amongLiveNicknames: []
        )
        let message = VehicleNicknamePolicy.validationError(
            for: "Charger",
            excluding: Optional<PersistentIdentifier>.none,
            among: [],
            orphanedHistoricalNicknameKeysResult: orphanedResult
        )
        #expect(message == nil)
    }

    // MARK: - Live duplicate (e.g. a CloudKit-restored vehicle already present)

    @Test("A nickname matching a cloud-restored live vehicle already present is rejected")
    func cloudRestoredLiveVehicle_duplicateNickname_isRejected() throws {
        let context = try makeInMemoryContext()
        let restoredVehicle = VehicleProfile(nickname: "Charger")
        context.insert(restoredVehicle)
        try context.save()

        let liveVehicles = try context.fetch(FetchDescriptor<VehicleProfile>())
        let orphanedResult = VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeysResult(
            modelContext: context,
            amongLiveNicknames: liveVehicles.map(\.nickname)
        )
        let message = VehicleNicknamePolicy.validationError(
            for: "Charger",
            excluding: Optional<PersistentIdentifier>.none,
            among: liveVehicles.map { (id: $0.persistentModelID, nickname: $0.nickname) },
            orphanedHistoricalNicknameKeysResult: orphanedResult
        )
        #expect(message == "Another vehicle already uses this nickname.")
    }

    @Test("A genuinely different nickname is still allowed when a cloud-restored live vehicle is present")
    func cloudRestoredLiveVehicle_differentNickname_isAllowed() throws {
        let context = try makeInMemoryContext()
        let restoredVehicle = VehicleProfile(nickname: "Charger")
        context.insert(restoredVehicle)
        try context.save()

        let liveVehicles = try context.fetch(FetchDescriptor<VehicleProfile>())
        let orphanedResult = VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeysResult(
            modelContext: context,
            amongLiveNicknames: liveVehicles.map(\.nickname)
        )
        let message = VehicleNicknamePolicy.validationError(
            for: "Wagon",
            excluding: Optional<PersistentIdentifier>.none,
            among: liveVehicles.map { (id: $0.persistentModelID, nickname: $0.nickname) },
            orphanedHistoricalNicknameKeysResult: orphanedResult
        )
        #expect(message == nil)
    }

    // MARK: - Retired nickname reserved by real, persisted history rows

    @Test("A nickname with real, persisted orphaned Fuel Log history is rejected")
    func realFuelLogHistory_retiredNickname_isRejected() throws {
        let context = try makeInMemoryContext()
        context.insert(FuelLogEntry(vehicleName: "Truck"))
        try context.save()

        let orphanedResult = VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeysResult(
            modelContext: context,
            amongLiveNicknames: []
        )
        let message = VehicleNicknamePolicy.validationError(
            for: "Truck",
            excluding: Optional<PersistentIdentifier>.none,
            among: [],
            orphanedHistoricalNicknameKeysResult: orphanedResult
        )
        #expect(message != nil)
        #expect(message != "Another vehicle already uses this nickname.")
    }

    @Test("A nickname with real, persisted orphaned maintenance reminder history is rejected")
    func realMaintenanceReminderHistory_retiredNickname_isRejected() throws {
        let context = try makeInMemoryContext()
        context.insert(MaintenanceReminder(vehicleName: "Truck"))
        try context.save()

        let orphanedResult = VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeysResult(
            modelContext: context,
            amongLiveNicknames: []
        )
        let message = VehicleNicknamePolicy.validationError(
            for: "Truck",
            excluding: Optional<PersistentIdentifier>.none,
            among: [],
            orphanedHistoricalNicknameKeysResult: orphanedResult
        )
        #expect(message != nil)
        #expect(message != "Another vehicle already uses this nickname.")
    }

    @Test("A nickname with real, persisted orphaned completion-record history is rejected")
    func realCompletionRecordHistory_retiredNickname_isRejected() throws {
        let context = try makeInMemoryContext()
        context.insert(ReminderCompletionRecord(vehicleName: "Truck"))
        try context.save()

        let orphanedResult = VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeysResult(
            modelContext: context,
            amongLiveNicknames: []
        )
        let message = VehicleNicknamePolicy.validationError(
            for: "Truck",
            excluding: Optional<PersistentIdentifier>.none,
            among: [],
            orphanedHistoricalNicknameKeysResult: orphanedResult
        )
        #expect(message != nil)
        #expect(message != "Another vehicle already uses this nickname.")
    }

    @Test("A case/whitespace variant of a real, persisted retired nickname is also rejected")
    func realHistory_caseWhitespaceVariant_isRejected() throws {
        let context = try makeInMemoryContext()
        context.insert(FuelLogEntry(vehicleName: "Truck"))
        try context.save()

        let orphanedResult = VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeysResult(
            modelContext: context,
            amongLiveNicknames: []
        )
        let message = VehicleNicknamePolicy.validationError(
            for: "  truck  ",
            excluding: Optional<PersistentIdentifier>.none,
            among: [],
            orphanedHistoricalNicknameKeysResult: orphanedResult
        )
        #expect(message != nil)
    }

    @Test("A live vehicle's own real, persisted history does not reserve its exact nickname")
    func realHistory_ownedByLiveVehicle_isNotReserved() throws {
        let context = try makeInMemoryContext()
        let liveVehicle = VehicleProfile(nickname: "Truck")
        context.insert(liveVehicle)
        context.insert(FuelLogEntry(vehicleName: "Truck"))
        try context.save()

        let liveVehicles = try context.fetch(FetchDescriptor<VehicleProfile>())
        let orphanedResult = VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeysResult(
            modelContext: context,
            amongLiveNicknames: liveVehicles.map(\.nickname)
        )
        // Editing that same live vehicle, keeping its own nickname, must be allowed.
        let message = VehicleNicknamePolicy.validationError(
            for: "Truck",
            excluding: liveVehicle.persistentModelID,
            among: liveVehicles.map { (id: $0.persistentModelID, nickname: $0.nickname) },
            editingVehicleCurrentNickname: "Truck",
            orphanedHistoricalNicknameKeysResult: orphanedResult
        )
        #expect(message == nil)
    }

    @Test("Reusing a deleted vehicle's nickname is allowed when it never had any real, persisted history")
    func deletedVehicleWithNoRealHistory_reuseIsAllowed() throws {
        // Simulates: a vehicle named "Truck" existed and was deleted (its row is simply gone —
        // GarageView.confirmDeletion never touches history), but it never generated a single
        // Fuel Log/Reminder/Completion row, so there is nothing real for it to have orphaned.
        let context = try makeInMemoryContext()

        let orphanedResult = VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeysResult(
            modelContext: context,
            amongLiveNicknames: []
        )
        let message = VehicleNicknamePolicy.validationError(
            for: "Truck",
            excluding: Optional<PersistentIdentifier>.none,
            among: [],
            orphanedHistoricalNicknameKeysResult: orphanedResult
        )
        #expect(message == nil)
    }
}
