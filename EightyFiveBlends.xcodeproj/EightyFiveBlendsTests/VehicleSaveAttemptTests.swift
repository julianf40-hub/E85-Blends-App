//
//  VehicleSaveAttemptTests.swift
//  EightyFiveBlendsTests
//
//  Tests for VehicleSaveAttempt — the mutate-then-save orchestration GarageView.saveVehicle
//  delegates to for every add/edit that passes its nickname and vehicle-limit guards. Like
//  VehicleHistoricalNicknameLookupTests, these run the REAL production type against a REAL
//  in-memory SwiftData context (one container, the "main" context the attempt runs on, plus
//  brand-new contexts on the same store to read back what was actually committed) rather than
//  hand-built arrays, because the thing being proven is exactly what a failed attempt leaves on
//  a live context.
//
//  Failures are forced through VehicleSaveAttempt.Seams — the production seam for the history
//  fetch and the save — wrapped around the live implementations (see `makeSeams(...)` below), so the
//  success paths and the call-through are the same production code. A forced save failure does
//  not exercise a genuine Core Data write error; it exercises the same restore path a genuine one
//  would, since that path only depends on `save` having thrown.
//
//  Scope note: GarageView.saveVehicle itself (its SwiftUI sheet/alert state, the nickname,
//  retired-nickname, and vehicle-limit guards that run before this) remains SwiftUI-coupled
//  private view code that no test instantiates; those guards keep their own tests
//  (VehicleNicknamePolicyTests, VehicleNicknamePolicyRetiredNicknameTests,
//  VehicleCreationPolicyTests), which this file does not touch. Editor-draft retention and the
//  error alert are the view's `case .saveFailed` / `.historyLookupFailed` branches (leave
//  `sheetContext` set, set `saveErrorMessage`) — verified by inspection, not here.
//
//  How "nothing was left behind" is checked: in-memory values are compared with the snapshot
//  taken before the attempt, then the context's remaining pending changes are flushed with a
//  real `save()` — exactly what a later, unrelated save in the app would do — and a new context
//  reads the store back. Anything a failed attempt had left pending would surface there.
//

import Foundation
import SwiftData
import Testing
@testable import EightyFiveBlends

@MainActor
struct VehicleSaveAttemptTests {
    // MARK: - Fixtures

    private static let seededAt = Date(timeIntervalSince1970: 1_000_000)
    private static let unsavedAt = Date(timeIntervalSince1970: 2_000_000)

    private enum InjectedFailure: Error {
        case save
        case fetch
    }

    private final class CallCounter {
        var count = 0
    }

    private struct Store {
        let container: ModelContainer
        let context: ModelContext

        func freshContext() -> ModelContext {
            ModelContext(container)
        }
    }

    private struct VehicleState: Equatable {
        let id: PersistentIdentifier
        let nickname: String
        let year: String
        let make: String
        let model: String
        let trim: String
        let tankSizeGallons: Double
        let currentOdometer: Int
        let defaultTargetEthanolPercent: Double
        let defaultCurrentEthanolPercent: Double
        let defaultPumpEthanolPercent: Double
        let gasEthanolPercent: Double
        let preferredEthanolTargetPercent: Double?
        let calculatorPreferenceSemanticsVersion: Int
        let requiredOctane: Double
        let isFlexFuel: Bool
        let isActive: Bool
        let vehiclePhotoData: Data?
        let createdAt: Date
        let updatedAt: Date

        init(_ vehicle: VehicleProfile) {
            id = vehicle.persistentModelID
            nickname = vehicle.nickname
            year = vehicle.year
            make = vehicle.make
            model = vehicle.model
            trim = vehicle.trim
            tankSizeGallons = vehicle.tankSizeGallons
            currentOdometer = vehicle.currentOdometer
            defaultTargetEthanolPercent = vehicle.defaultTargetEthanolPercent
            defaultCurrentEthanolPercent = vehicle.defaultCurrentEthanolPercent
            defaultPumpEthanolPercent = vehicle.defaultPumpEthanolPercent
            gasEthanolPercent = vehicle.gasEthanolPercent
            preferredEthanolTargetPercent = vehicle.preferredEthanolTargetPercent
            calculatorPreferenceSemanticsVersion = vehicle.calculatorPreferenceSemanticsVersion
            requiredOctane = vehicle.requiredOctane
            isFlexFuel = vehicle.isFlexFuel
            isActive = vehicle.isActive
            vehiclePhotoData = vehicle.vehiclePhotoData
            createdAt = vehicle.createdAt
            updatedAt = vehicle.updatedAt
        }
    }

    private struct FuelLogState: Equatable {
        let id: PersistentIdentifier
        let vehicleName: String
        let date: Date
        let stationName: String
        let odometer: Int
        let totalCost: Double
        let notes: String

        init(_ log: FuelLogEntry) {
            id = log.persistentModelID
            vehicleName = log.vehicleName
            date = log.date
            stationName = log.stationName
            odometer = log.odometer
            totalCost = log.totalCost
            notes = log.notes
        }
    }

    private struct ReminderState: Equatable {
        let id: PersistentIdentifier
        let vehicleName: String
        let title: String
        let category: String
        let notes: String
        let reminderIdentifier: String

        init(_ reminder: MaintenanceReminder) {
            id = reminder.persistentModelID
            vehicleName = reminder.vehicleName
            title = reminder.title
            category = reminder.category
            notes = reminder.notes
            reminderIdentifier = reminder.reminderIdentifier
        }
    }

    private struct CompletionState: Equatable {
        let id: PersistentIdentifier
        let vehicleName: String
        let reminderTitle: String
        let category: String
        let completedAt: Date
        let notes: String?
        let reminderIdentifier: String

        init(_ record: ReminderCompletionRecord) {
            id = record.persistentModelID
            vehicleName = record.vehicleName
            reminderTitle = record.reminderTitle
            category = record.category
            completedAt = record.completedAt
            notes = record.notes
            reminderIdentifier = record.reminderIdentifier
        }
    }

    /// One Fuel Log, one maintenance reminder, and one completion record sharing a vehicleName.
    private struct HistoryRows {
        let fuelLog: FuelLogEntry
        let reminder: MaintenanceReminder
        let completion: ReminderCompletionRecord

        var fuelLogState: FuelLogState { FuelLogState(fuelLog) }
        var reminderState: ReminderState { ReminderState(reminder) }
        var completionState: CompletionState { CompletionState(completion) }
    }

    /// Everything committed to the store, read through a brand-new context.
    private struct StoreContents: Equatable {
        let vehicles: [VehicleState]
        let fuelLogs: [FuelLogState]
        let reminders: [ReminderState]
        let completions: [CompletionState]
    }

    /// A saved garage: "Truck" (active) and "Spare" (inactive), each with history under its own
    /// nickname, plus history under "truck" that no live vehicle owns — the exact-match trap
    /// VehicleNicknamePolicy.orphanedHistoricalNicknameKeys documents.
    private struct Garage {
        let store: Store
        let truck: VehicleProfile
        let spare: VehicleProfile
        let truckHistory: HistoryRows
        let spareHistory: HistoryRows
        let orphanHistory: HistoryRows
    }

    private func makeStore() throws -> Store {
        let schema = Schema([
            VehicleProfile.self,
            FuelLogEntry.self,
            MaintenanceReminder.self,
            ReminderCompletionRecord.self
        ])
        // CloudKit explicitly off: the default (.automatic) lets the app's iCloud entitlement start
        // CloudKit setup against this throwaway store, which tears it down mid-test when there is
        // no iCloud account.
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        return Store(container: container, context: ModelContext(container))
    }

    @discardableResult
    private func seedVehicle(
        _ context: ModelContext,
        _ nickname: String,
        order: Int,
        isActive: Bool,
        odometer: Int = 10_000
    ) -> VehicleProfile {
        // Legacy semantics on purpose: an edit transitions the vehicle to `current`, so a failed
        // edit that forgot to put the version back would show up as a changed value.
        let vehicle = VehicleProfile(
            nickname: nickname,
            year: "2020",
            make: "Dodge",
            model: "Charger",
            trim: "RT",
            tankSizeGallons: 18,
            currentOdometer: odometer,
            requiredOctane: 91,
            isFlexFuel: true,
            isActive: isActive,
            createdAt: Date(timeIntervalSince1970: Double(order)),
            updatedAt: Self.seededAt,
            preferredEthanolTargetPercent: nil,
            calculatorPreferenceSemanticsVersion: VehiclePreferenceSemantics.legacy
        )
        context.insert(vehicle)
        return vehicle
    }

    private func seedHistory(_ context: ModelContext, for vehicleName: String, index: Int) -> HistoryRows {
        let fuelLog = FuelLogEntry(
            vehicleName: vehicleName,
            date: Date(timeIntervalSince1970: 5_000 + Double(index)),
            stationName: "Station \(index)",
            odometer: 12_000 + index,
            totalCost: 40 + Double(index),
            notes: "log note \(index)"
        )
        let reminder = MaintenanceReminder(
            vehicleName: vehicleName,
            title: "Oil change",
            category: "Oil",
            notes: "reminder note \(index)",
            reminderIdentifier: "reminder-\(index)"
        )
        let completion = ReminderCompletionRecord(
            reminderTitle: "Oil change",
            vehicleName: vehicleName,
            category: "Oil",
            completedAt: Date(timeIntervalSince1970: 6_000 + Double(index)),
            notes: "completion note \(index)",
            reminderIdentifier: "reminder-\(index)"
        )
        context.insert(fuelLog)
        context.insert(reminder)
        context.insert(completion)
        return HistoryRows(fuelLog: fuelLog, reminder: reminder, completion: completion)
    }

    private func makeGarage() throws -> Garage {
        let store = try makeStore()
        let truck = seedVehicle(store.context, "Truck", order: 1, isActive: true)
        let spare = seedVehicle(store.context, "Spare", order: 2, isActive: false)
        let truckHistory = seedHistory(store.context, for: "Truck", index: 0)
        let spareHistory = seedHistory(store.context, for: "Spare", index: 1)
        let orphanHistory = seedHistory(store.context, for: "truck", index: 2)
        try store.context.save()
        return Garage(
            store: store,
            truck: truck,
            spare: spare,
            truckHistory: truckHistory,
            spareHistory: spareHistory,
            orphanHistory: orphanHistory
        )
    }

    private func readStore(_ store: Store) throws -> StoreContents {
        let fresh = store.freshContext()
        let vehicles = try fresh.fetch(FetchDescriptor<VehicleProfile>(sortBy: [SortDescriptor(\.createdAt)]))
        let fuelLogs = try fresh.fetch(FetchDescriptor<FuelLogEntry>(sortBy: [SortDescriptor(\.date)]))
        let reminders = try fresh.fetch(FetchDescriptor<MaintenanceReminder>(sortBy: [SortDescriptor(\.reminderIdentifier)]))
        let completions = try fresh.fetch(FetchDescriptor<ReminderCompletionRecord>(sortBy: [SortDescriptor(\.reminderIdentifier)]))
        return StoreContents(
            vehicles: vehicles.map(VehicleState.init),
            fuelLogs: fuelLogs.map(FuelLogState.init),
            reminders: reminders.map(ReminderState.init),
            completions: completions.map(CompletionState.init)
        )
    }

    /// GarageView's @Query: every saved vehicle (pending inserts included), oldest first.
    private func liveVehicles(in context: ModelContext) throws -> [VehicleProfile] {
        try context.fetch(FetchDescriptor<VehicleProfile>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    private func newDraft(_ nickname: String, existingCount: Int, active: Bool? = nil) -> VehicleDraft {
        var draft = VehicleDraft(vehicle: nil, existingVehiclesCount: existingCount)
        draft.nickname = nickname
        draft.make = "Subaru"
        draft.model = "WRX"
        if let active {
            draft.isActive = active
        }
        return draft
    }

    /// An edit draft that changes every field AddEditVehicleView can change, so a restore that
    /// misses one shows up as a difference.
    private func rewrittenDraft(for vehicle: VehicleProfile, nickname: String, isActive: Bool) -> VehicleDraft {
        var draft = VehicleDraft(vehicle: vehicle, existingVehiclesCount: 2)
        draft.nickname = nickname
        draft.year = "1999"
        draft.make = "Ford"
        draft.model = "F-150"
        draft.trim = "XLT"
        draft.tankSizeGallons = 26
        draft.currentOdometer = vehicle.currentOdometer + 500
        draft.requiredOctane = 87
        draft.preferredEthanolTargetPercent = 50
        draft.isFlexFuel = vehicle.isFlexFuel == false
        draft.isActive = isActive
        draft.vehiclePhotoData = Data([0x01, 0x02, 0x03])
        return draft
    }

    /// The live seams, counting calls and optionally throwing in place of the real step.
    private func makeSeams(
        failingSave: Bool = false,
        failingFetch: Bool = false,
        saveCalls: CallCounter? = nil,
        fetchCalls: CallCounter? = nil
    ) -> VehicleSaveAttempt.Seams {
        // Resolved here, not as default arguments: default-argument expressions are evaluated
        // outside this method's main-actor isolation.
        let saveCalls = saveCalls ?? CallCounter()
        let fetchCalls = fetchCalls ?? CallCounter()
        var seams = VehicleSaveAttempt.Seams.live
        let liveSave = seams.save
        let liveFetch = seams.fetchHistory
        seams.save = { context in
            saveCalls.count += 1
            if failingSave {
                throw InjectedFailure.save
            }
            try liveSave(context)
        }
        seams.fetchHistory = { context, name in
            fetchCalls.count += 1
            if failingFetch {
                throw InjectedFailure.fetch
            }
            return try liveFetch(context, name)
        }
        return seams
    }

    private func attempt(
        _ draft: VehicleDraft,
        editing vehicle: VehicleProfile?,
        in context: ModelContext,
        seams: VehicleSaveAttempt.Seams? = nil
    ) throws -> VehicleSaveAttempt.Outcome {
        let vehicles = try liveVehicles(in: context)
        return VehicleSaveAttempt.perform(
            draft: draft,
            editing: vehicle,
            among: vehicles,
            in: context,
            seams: seams ?? .live
        )
    }

    private func isSaved(_ outcome: VehicleSaveAttempt.Outcome) -> Bool {
        if case .saved = outcome { return true }
        return false
    }

    private func isSaveFailure(_ outcome: VehicleSaveAttempt.Outcome) -> Bool {
        if case .saveFailed = outcome { return true }
        return false
    }

    private func isHistoryLookupFailure(_ outcome: VehicleSaveAttempt.Outcome) -> Bool {
        if case .historyLookupFailed = outcome { return true }
        return false
    }

    /// The error GarageView would show for `candidate` right now: the real nickname policy fed
    /// from the real store, the way saveVehicle feeds it.
    private func nicknameError(
        for candidate: String,
        among vehicles: [VehicleProfile],
        in context: ModelContext
    ) -> String? {
        VehicleNicknamePolicy.validationError(
            for: candidate,
            excluding: Optional<PersistentIdentifier>.none,
            among: vehicles.map { (id: $0.persistentModelID, nickname: $0.nickname) },
            orphanedHistoricalNicknameKeysResult: VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeysResult(
                modelContext: context,
                amongLiveNicknames: vehicles.map(\.nickname)
            )
        )
    }

    // MARK: - Success paths

    @Test("Adding the first vehicle saves it active")
    func add_firstVehicle_savesActive() throws {
        let store = try makeStore()

        let outcome = try attempt(newDraft("Charger", existingCount: 0), editing: nil, in: store.context)

        #expect(isSaved(outcome))
        let contents = try readStore(store)
        #expect(contents.vehicles.map(\.nickname) == ["Charger"])
        #expect(contents.vehicles.first?.isActive == true)
        #expect(contents.vehicles.first?.calculatorPreferenceSemanticsVersion == VehiclePreferenceSemantics.current)
    }

    @Test("Adding an active vehicle deactivates the others and persists both changes")
    func add_activeVehicle_deactivatesOthers() throws {
        let garage = try makeGarage()

        let outcome = try attempt(newDraft("Wagon", existingCount: 2, active: true), editing: nil, in: garage.store.context)

        #expect(isSaved(outcome))
        let contents = try readStore(garage.store)
        let byName = Dictionary(uniqueKeysWithValues: contents.vehicles.map { ($0.nickname, $0) })
        #expect(byName.count == 3)
        #expect(byName["Wagon"]?.isActive == true)
        #expect(byName["Truck"]?.isActive == false)
        #expect(byName["Spare"]?.isActive == false)
        if let truckUpdatedAt = byName["Truck"]?.updatedAt {
            #expect(truckUpdatedAt > Self.seededAt)
        }
    }

    @Test("Adding an inactive vehicle leaves every existing vehicle untouched")
    func add_inactiveVehicle_leavesOthersUntouched() throws {
        let garage = try makeGarage()
        let before = try readStore(garage.store)

        let outcome = try attempt(newDraft("Wagon", existingCount: 2, active: false), editing: nil, in: garage.store.context)

        #expect(isSaved(outcome))
        let after = try readStore(garage.store)
        #expect(after.vehicles.count == 3)
        #expect(after.vehicles.filter { $0.nickname != "Wagon" } == before.vehicles)
        #expect(after.vehicles.first(where: { $0.nickname == "Wagon" })?.isActive == false)
    }

    @Test("Renaming a vehicle saves it and renames only the history rows that exactly match its old nickname")
    func edit_rename_renamesOnlyExactMatchingHistory() throws {
        let garage = try makeGarage()
        let draft = rewrittenDraft(for: garage.truck, nickname: "Pickup", isActive: true)

        let outcome = try attempt(draft, editing: garage.truck, in: garage.store.context)

        #expect(isSaved(outcome))
        let after = try readStore(garage.store)
        let truck = try #require(after.vehicles.first(where: { $0.id == garage.truck.persistentModelID }))
        #expect(truck.nickname == "Pickup")
        #expect(truck.make == "Ford")
        #expect(truck.currentOdometer == 10_500)
        #expect(truck.calculatorPreferenceSemanticsVersion == VehiclePreferenceSemantics.current)
        #expect(truck.updatedAt > Self.seededAt)
        // Sorted by seeded date / reminderIdentifier: Truck's rows, Spare's rows, then the
        // lowercase "truck" orphan's rows — only the first were renamed.
        #expect(after.fuelLogs.map(\.vehicleName) == ["Pickup", "Spare", "truck"])
        #expect(after.reminders.map(\.vehicleName) == ["Pickup", "Spare", "truck"])
        #expect(after.completions.map(\.vehicleName) == ["Pickup", "Spare", "truck"])
    }

    @Test("Editing the active vehicle's Active toggle off keeps the sole active vehicle active")
    func edit_soleActiveVehicle_staysActive() throws {
        let store = try makeStore()
        let truck = seedVehicle(store.context, "Truck", order: 1, isActive: true)
        try store.context.save()
        var draft = VehicleDraft(vehicle: truck, existingVehiclesCount: 1)
        draft.isActive = false

        let outcome = try attempt(draft, editing: truck, in: store.context)

        #expect(isSaved(outcome))
        let contents = try readStore(store)
        #expect(contents.vehicles.first?.isActive == true)
    }

    @Test("Activating an inactive vehicle through Edit deactivates the previously active one")
    func edit_activateInactiveVehicle_deactivatesOthers() throws {
        let garage = try makeGarage()
        var draft = VehicleDraft(vehicle: garage.spare, existingVehiclesCount: 2)
        draft.isActive = true

        let outcome = try attempt(draft, editing: garage.spare, in: garage.store.context)

        #expect(isSaved(outcome))
        let contents = try readStore(garage.store)
        #expect(contents.vehicles.map(\.nickname) == ["Truck", "Spare"])
        #expect(contents.vehicles.map(\.isActive) == [false, true])
    }

    @Test("An edit that keeps the nickname never fetches history, so a broken history fetch cannot block it")
    func edit_unchangedNickname_doesNotFetchHistory() throws {
        let garage = try makeGarage()
        var draft = VehicleDraft(vehicle: garage.truck, existingVehiclesCount: 2)
        draft.trim = "Limited"
        let fetchCalls = CallCounter()

        let outcome = try attempt(
            draft,
            editing: garage.truck,
            in: garage.store.context,
            seams: makeSeams(failingFetch: true, fetchCalls: fetchCalls)
        )

        #expect(isSaved(outcome))
        #expect(fetchCalls.count == 0)
        let after = try readStore(garage.store)
        #expect(after.vehicles.first(where: { $0.id == garage.truck.persistentModelID })?.trim == "Limited")
        #expect(after.fuelLogs.map(\.vehicleName) == ["Truck", "Spare", "truck"])
    }

    @Test("A routine edit never lowers the odometer")
    func edit_neverLowersOdometer() throws {
        let garage = try makeGarage()
        var draft = VehicleDraft(vehicle: garage.truck, existingVehiclesCount: 2)
        draft.currentOdometer = 1_000

        let outcome = try attempt(draft, editing: garage.truck, in: garage.store.context)

        #expect(isSaved(outcome))
        let after = try readStore(garage.store)
        #expect(after.vehicles.first(where: { $0.id == garage.truck.persistentModelID })?.currentOdometer == 10_000)
    }

    // MARK: - Failed save: only this attempt's writes are undone

    @Test("A failed add removes only its own vehicle and restores every vehicle whose active flag it cleared")
    func failedAdd_removesOwnVehicle_restoresActiveFlagsAndTimestamps() throws {
        let garage = try makeGarage()
        let before = try readStore(garage.store)
        let truckBefore = VehicleState(garage.truck)
        let spareBefore = VehicleState(garage.spare)
        let saveCalls = CallCounter()

        let outcome = try attempt(
            newDraft("Wagon", existingCount: 2, active: true),
            editing: nil,
            in: garage.store.context,
            seams: makeSeams(failingSave: true, saveCalls: saveCalls)
        )

        #expect(isSaveFailure(outcome))
        #expect(saveCalls.count == 1)
        #expect(VehicleState(garage.truck) == truckBefore)
        #expect(VehicleState(garage.spare) == spareBefore)
        let live = try liveVehicles(in: garage.store.context)
        #expect(live.map(\.nickname) == ["Truck", "Spare"])

        // A later save of whatever is still pending must commit nothing from the failed attempt.
        try garage.store.context.save()
        let after = try readStore(garage.store)
        #expect(after == before)
    }

    @Test("A failed edit restores every field the attempt wrote, including the preference-semantics transition")
    func failedEdit_restoresEveryWrittenField() throws {
        let garage = try makeGarage()
        let before = try readStore(garage.store)
        let truckBefore = VehicleState(garage.truck)
        let draft = rewrittenDraft(for: garage.truck, nickname: "Pickup", isActive: true)

        let outcome = try attempt(
            draft,
            editing: garage.truck,
            in: garage.store.context,
            seams: makeSeams(failingSave: true)
        )

        #expect(isSaveFailure(outcome))
        #expect(VehicleState(garage.truck) == truckBefore)
        #expect(garage.truck.nickname == "Truck")
        #expect(garage.truck.calculatorPreferenceSemanticsVersion == VehiclePreferenceSemantics.legacy)

        try garage.store.context.save()
        let after = try readStore(garage.store)
        #expect(after == before)
    }

    @Test("A failed activation-transferring edit restores both the edited and the previously active vehicle")
    func failedEdit_activationTransfer_restoresBothVehicles() throws {
        let garage = try makeGarage()
        let before = try readStore(garage.store)
        let truckBefore = VehicleState(garage.truck)
        let spareBefore = VehicleState(garage.spare)
        var draft = VehicleDraft(vehicle: garage.spare, existingVehiclesCount: 2)
        draft.isActive = true

        let outcome = try attempt(
            draft,
            editing: garage.spare,
            in: garage.store.context,
            seams: makeSeams(failingSave: true)
        )

        #expect(isSaveFailure(outcome))
        #expect(VehicleState(garage.truck) == truckBefore)
        #expect(VehicleState(garage.spare) == spareBefore)
        #expect(garage.truck.isActive)
        #expect(garage.spare.isActive == false)

        try garage.store.context.save()
        let after = try readStore(garage.store)
        #expect(after == before)
    }

    @Test("A failed rename leaves every historical row's identity and content exactly as it was")
    func failedRename_preservesHistoryRowIdentityAndContent() throws {
        let garage = try makeGarage()
        let before = try readStore(garage.store)
        let fuelLogBefore = garage.truckHistory.fuelLogState
        let reminderBefore = garage.truckHistory.reminderState
        let completionBefore = garage.truckHistory.completionState
        let orphanFuelLogBefore = garage.orphanHistory.fuelLogState
        let draft = rewrittenDraft(for: garage.truck, nickname: "Pickup", isActive: true)

        let outcome = try attempt(
            draft,
            editing: garage.truck,
            in: garage.store.context,
            seams: makeSeams(failingSave: true)
        )

        #expect(isSaveFailure(outcome))
        #expect(garage.truckHistory.fuelLogState == fuelLogBefore)
        #expect(garage.truckHistory.reminderState == reminderBefore)
        #expect(garage.truckHistory.completionState == completionBefore)
        #expect(garage.orphanHistory.fuelLogState == orphanFuelLogBefore)

        try garage.store.context.save()
        let after = try readStore(garage.store)
        // Same rows (identifiers included), same names, same content — nothing recreated.
        #expect(after == before)
    }

    @Test("A failed attempt restores pre-attempt UNSAVED values on the models it touched, not the persisted ones")
    func failedAttempt_preservesPriorUnsavedValuesOnTouchedModels() throws {
        let garage = try makeGarage()
        // Unsaved edits made elsewhere before this attempt: on the vehicle being edited (a
        // property the attempt overwrites), on the vehicle whose active flag it will clear (a
        // property it also writes, and one it doesn't), and on a history row it will rename.
        garage.spare.trim = "Unsaved Spare Trim"
        garage.truck.trim = "Unsaved Truck Trim"
        garage.truck.updatedAt = Self.unsavedAt
        garage.spareHistory.fuelLog.notes = "unsaved log note"
        let draft = rewrittenDraft(for: garage.spare, nickname: "Backup", isActive: true)

        let outcome = try attempt(
            draft,
            editing: garage.spare,
            in: garage.store.context,
            seams: makeSeams(failingSave: true)
        )

        #expect(isSaveFailure(outcome))
        #expect(garage.spare.trim == "Unsaved Spare Trim")
        #expect(garage.spare.nickname == "Spare")
        #expect(garage.spare.isActive == false)
        #expect(garage.truck.trim == "Unsaved Truck Trim")
        #expect(garage.truck.updatedAt == Self.unsavedAt)
        #expect(garage.truck.isActive)
        #expect(garage.spareHistory.fuelLog.notes == "unsaved log note")
        #expect(garage.spareHistory.fuelLog.vehicleName == "Spare")

        // Those earlier unsaved values were not the attempt's to discard: the next real save
        // commits them, and commits nothing the failed attempt wrote.
        try garage.store.context.save()
        let after = try readStore(garage.store)
        let spare = try #require(after.vehicles.first(where: { $0.id == garage.spare.persistentModelID }))
        let truck = try #require(after.vehicles.first(where: { $0.id == garage.truck.persistentModelID }))
        #expect(spare.trim == "Unsaved Spare Trim")
        #expect(spare.nickname == "Spare")
        #expect(spare.isActive == false)
        #expect(truck.trim == "Unsaved Truck Trim")
        #expect(truck.updatedAt == Self.unsavedAt)
        #expect(truck.isActive)
        #expect(after.fuelLogs.first(where: { $0.id == garage.spareHistory.fuelLog.persistentModelID })?.notes == "unsaved log note")
        #expect(after.fuelLogs.map(\.vehicleName) == ["Truck", "Spare", "truck"])
    }

    @Test("A failed add keeps unrelated pending inserts, updates, and deletes pending")
    func failedAdd_preservesUnrelatedPendingChanges() throws {
        let garage = try makeGarage()
        let elsewhere = seedHistory(garage.store.context, for: "Elsewhere", index: 3)
        try garage.store.context.save()

        // Pending, unsaved work belonging to nobody in this attempt: an updated row, a deleted
        // row, an inserted row, and an inserted vehicle that IS in the attempt's `vehicles` list
        // (so its active flag/timestamp are touched and must be put back).
        elsewhere.fuelLog.notes = "pending update"
        garage.store.context.delete(elsewhere.reminder)
        garage.store.context.insert(FuelLogEntry(
            vehicleName: "Elsewhere",
            date: Date(timeIntervalSince1970: 9_000),
            notes: "pending insert"
        ))
        let staged = VehicleProfile(
            nickname: "Staged",
            isActive: false,
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: Self.unsavedAt
        )
        garage.store.context.insert(staged)

        let outcome = try attempt(
            newDraft("Wagon", existingCount: 3, active: true),
            editing: nil,
            in: garage.store.context,
            seams: makeSeams(failingSave: true)
        )

        #expect(isSaveFailure(outcome))
        #expect(staged.isActive == false)
        #expect(staged.updatedAt == Self.unsavedAt)
        #expect(elsewhere.fuelLog.notes == "pending update")

        try garage.store.context.save()
        let after = try readStore(garage.store)
        // Oldest first: Truck (createdAt 1), Spare (2), Staged (50).
        #expect(after.vehicles.map(\.nickname) == ["Truck", "Spare", "Staged"])
        #expect(after.vehicles.first(where: { $0.nickname == "Staged" })?.updatedAt == Self.unsavedAt)
        #expect(after.vehicles.first(where: { $0.nickname == "Truck" })?.isActive == true)
        #expect(after.fuelLogs.first(where: { $0.id == elsewhere.fuelLog.persistentModelID })?.notes == "pending update")
        #expect(after.fuelLogs.contains(where: { $0.notes == "pending insert" }))
        #expect(after.reminders.contains(where: { $0.vehicleName == "Elsewhere" }) == false)
        #expect(after.completions.contains(where: { $0.vehicleName == "Elsewhere" }))
    }

    @Test("A failed rename keeps unrelated pending changes pending too")
    func failedRename_preservesUnrelatedPendingChanges() throws {
        let garage = try makeGarage()
        let elsewhere = seedHistory(garage.store.context, for: "Elsewhere", index: 3)
        try garage.store.context.save()
        elsewhere.fuelLog.notes = "pending update"
        garage.store.context.delete(elsewhere.reminder)
        garage.store.context.insert(FuelLogEntry(
            vehicleName: "Elsewhere",
            date: Date(timeIntervalSince1970: 9_000),
            notes: "pending insert"
        ))
        let draft = rewrittenDraft(for: garage.truck, nickname: "Pickup", isActive: true)

        let outcome = try attempt(
            draft,
            editing: garage.truck,
            in: garage.store.context,
            seams: makeSeams(failingSave: true)
        )

        #expect(isSaveFailure(outcome))
        try garage.store.context.save()
        let after = try readStore(garage.store)
        #expect(after.vehicles.first(where: { $0.id == garage.truck.persistentModelID })?.nickname == "Truck")
        #expect(after.fuelLogs.map(\.vehicleName).sorted() == ["Elsewhere", "Elsewhere", "Spare", "Truck", "truck"])
        #expect(after.fuelLogs.first(where: { $0.id == elsewhere.fuelLog.persistentModelID })?.notes == "pending update")
        #expect(after.fuelLogs.contains(where: { $0.notes == "pending insert" }))
        #expect(after.reminders.contains(where: { $0.vehicleName == "Elsewhere" }) == false)
    }

    // MARK: - Failed history lookup: nothing is mutated

    @Test("A history lookup failure aborts before any mutation and never reaches save")
    func historyLookupFailure_abortsBeforeAnyMutation() throws {
        let garage = try makeGarage()
        let before = try readStore(garage.store)
        let truckBefore = VehicleState(garage.truck)
        let spareBefore = VehicleState(garage.spare)
        let spareHistoryBefore = garage.spareHistory.fuelLogState
        let saveCalls = CallCounter()
        let fetchCalls = CallCounter()
        // Rename + activate: the two mutations that would otherwise run before/around the fetch.
        let draft = rewrittenDraft(for: garage.spare, nickname: "Backup", isActive: true)

        let outcome = try attempt(
            draft,
            editing: garage.spare,
            in: garage.store.context,
            seams: makeSeams(failingFetch: true, saveCalls: saveCalls, fetchCalls: fetchCalls)
        )

        #expect(isHistoryLookupFailure(outcome))
        #expect(fetchCalls.count == 1)
        #expect(saveCalls.count == 0)
        #expect(VehicleState(garage.truck) == truckBefore)
        #expect(VehicleState(garage.spare) == spareBefore)
        #expect(garage.spareHistory.fuelLogState == spareHistoryBefore)

        try garage.store.context.save()
        let after = try readStore(garage.store)
        #expect(after == before)
    }

    // MARK: - Failure, then retry

    @Test("Retrying a failed add succeeds with exactly one new vehicle — no ghost, and its nickname isn't reserved by itself")
    func failedAdd_thenRetry_succeedsWithoutGhostDuplicate() throws {
        let store = try makeStore()
        let draft = newDraft("Wagon", existingCount: 0)

        let failed = try attempt(draft, editing: nil, in: store.context, seams: makeSeams(failingSave: true))

        #expect(isSaveFailure(failed))
        let liveAfterFailure = try liveVehicles(in: store.context)
        #expect(liveAfterFailure.isEmpty)
        // The retry's own nickname guard sees no live duplicate of the failed attempt's vehicle.
        #expect(nicknameError(for: "Wagon", among: liveAfterFailure, in: store.context) == nil)

        let retried = try attempt(draft, editing: nil, in: store.context)

        #expect(isSaved(retried))
        let contents = try readStore(store)
        #expect(contents.vehicles.map(\.nickname) == ["Wagon"])
        #expect(contents.vehicles.first?.isActive == true)
    }

    @Test("Retrying a failed rename succeeds and renames each historical row exactly once")
    func failedRename_thenRetry_succeeds() throws {
        let garage = try makeGarage()
        let draft = rewrittenDraft(for: garage.truck, nickname: "Pickup", isActive: true)

        let failed = try attempt(draft, editing: garage.truck, in: garage.store.context, seams: makeSeams(failingSave: true))
        #expect(isSaveFailure(failed))
        // The vehicle reads as its persisted self again, which is what the retired-nickname
        // guard's unchanged-name exemption compares against on the retry.
        #expect(garage.truck.nickname == "Truck")

        let retried = try attempt(draft, editing: garage.truck, in: garage.store.context)

        #expect(isSaved(retried))
        let after = try readStore(garage.store)
        #expect(after.vehicles.map(\.nickname) == ["Pickup", "Spare"])
        #expect(after.fuelLogs.map(\.vehicleName) == ["Pickup", "Spare", "truck"])
        #expect(after.reminders.map(\.vehicleName) == ["Pickup", "Spare", "truck"])
        #expect(after.completions.map(\.vehicleName) == ["Pickup", "Spare", "truck"])
    }

    @Test("Retrying after a history lookup failure succeeds")
    func historyLookupFailure_thenRetry_succeeds() throws {
        let garage = try makeGarage()
        let draft = rewrittenDraft(for: garage.truck, nickname: "Pickup", isActive: true)

        let failed = try attempt(draft, editing: garage.truck, in: garage.store.context, seams: makeSeams(failingFetch: true))
        #expect(isHistoryLookupFailure(failed))

        let retried = try attempt(draft, editing: garage.truck, in: garage.store.context)

        #expect(isSaved(retried))
        let after = try readStore(garage.store)
        #expect(after.vehicles.map(\.nickname) == ["Pickup", "Spare"])
        #expect(after.fuelLogs.map(\.vehicleName) == ["Pickup", "Spare", "truck"])
    }

    // MARK: - Failure, then Cancel, then a later unrelated save

    @Test("After a failed rename and Cancel, a later unrelated save persists no part of the edit and reserves nothing")
    func failedRename_thenCancel_laterUnrelatedSave_persistsNothingOfTheEdit() throws {
        let garage = try makeGarage()
        let before = try readStore(garage.store)
        let draft = rewrittenDraft(for: garage.truck, nickname: "Pickup", isActive: true)

        let failed = try attempt(draft, editing: garage.truck, in: garage.store.context, seams: makeSeams(failingSave: true))
        #expect(isSaveFailure(failed))
        // Cancel: the editor closes and nothing else happens — there is no call into the
        // attempt. The user then logs an unrelated fill-up, which saves the shared context.
        garage.store.context.insert(FuelLogEntry(
            vehicleName: "Truck",
            date: Date(timeIntervalSince1970: 9_000),
            notes: "fill-up after cancel"
        ))
        try garage.store.context.save()

        let after = try readStore(garage.store)
        #expect(after.vehicles == before.vehicles)
        #expect(after.reminders == before.reminders)
        #expect(after.completions == before.completions)
        #expect(after.fuelLogs.filter { $0.notes != "fill-up after cancel" } == before.fuelLogs)
        #expect(after.fuelLogs.contains(where: { $0.vehicleName == "Pickup" }) == false)

        // "Pickup" is neither a live vehicle's name nor retired history, so it isn't reserved.
        let fresh = garage.store.freshContext()
        let freshVehicles = try liveVehicles(in: fresh)
        #expect(nicknameError(for: "Pickup", among: freshVehicles, in: fresh) == nil)
        let orphanedKeys = try VehicleHistoricalNicknameLookup.orphanedHistoricalNicknameKeys(
            modelContext: fresh,
            amongLiveNicknames: freshVehicles.map(\.nickname)
        )
        #expect(orphanedKeys == ["truck"])
    }

    @Test("After a failed add and Cancel, a later unrelated save persists no ghost vehicle and the nickname stays free")
    func failedAdd_thenCancel_laterUnrelatedSave_persistsNoGhost() throws {
        let garage = try makeGarage()
        let before = try readStore(garage.store)

        let failed = try attempt(
            newDraft("Wagon", existingCount: 2, active: true),
            editing: nil,
            in: garage.store.context,
            seams: makeSeams(failingSave: true)
        )
        #expect(isSaveFailure(failed))
        garage.store.context.insert(FuelLogEntry(
            vehicleName: "Truck",
            date: Date(timeIntervalSince1970: 9_000),
            notes: "fill-up after cancel"
        ))
        try garage.store.context.save()

        let after = try readStore(garage.store)
        #expect(after.vehicles == before.vehicles)
        #expect(after.fuelLogs.contains(where: { $0.notes == "fill-up after cancel" }))

        let fresh = garage.store.freshContext()
        let freshVehicles = try liveVehicles(in: fresh)
        #expect(freshVehicles.map(\.nickname) == ["Truck", "Spare"])
        #expect(nicknameError(for: "Wagon", among: freshVehicles, in: fresh) == nil)
    }
}
