//
//  VehicleSaveAttempt.swift
//  EightyFiveBlends
//
//  The mutate-then-save orchestration behind GarageView.saveVehicle's add/edit path (85Blends
//  2.4.1), extracted so it can run against a real in-memory ModelContext in tests. Every rule
//  it applies — VehicleActivation, VehicleOdometerPolicy, VehiclePreferenceSemantics — is
//  already pure and separately tested; what only this type can prove is that a FAILED attempt
//  leaves nothing behind.
//
//  Why this exists: GarageView used to mutate live models (clearing other vehicles' active
//  flags, editing the vehicle, renaming Fuel Log/Reminder/Completion history, inserting a new
//  vehicle) and only then call `modelContext.save()`. A thrown save kept the editor open with
//  the user's draft intact — but left every one of those in-memory mutations on the shared main
//  context, so:
//    - a retry could insert a SECOND vehicle next to the first attempt's ghost,
//    - tapping Cancel and later saving something unrelated could persist the "failed" edit (or
//      the ghost vehicle, or a half-applied history rename that reserved the attempted
//      nickname),
//    - an edited vehicle's `nickname` already held the attempted value, so the retired-nickname
//      guard's unchanged-name exemption (`editingVehicleCurrentNickname`) compared against the
//      wrong "persisted" value on retry.
//
//  Why not `modelContext.rollback()`: the Garage shares its context with the rest of the app, so
//  a blanket rollback would also discard unrelated pending inserts, updates, and deletes — and
//  would revert unsaved values on the very models this attempt touched, not just this
//  attempt's own writes. Instead, this records the live (possibly already-unsaved) value of
//  every property the attempt is about to write, and on failure puts exactly those back and
//  deletes only the vehicle this attempt inserted.
//
//  History is fetched BEFORE any mutation. The old rename used `try?` per model, so a fetch
//  error silently skipped that model while the others were renamed — a partial history rename.
//  Now a failed lookup aborts the attempt untouched.
//
//  Scope: the nickname/retired-nickname/creation-limit guards stay in GarageView.saveVehicle and
//  run before this is ever called. GarageView.setActiveVehicle, confirmDeletion, and
//  saveOdometerUpdate are separate actions and are not routed through here.
//

import Foundation
import SwiftData

// Explicitly main-actor: the ModelContext and the @Model instances it hands back are read and
// written synchronously throughout, and every caller (GarageView, the tests) is on the main actor.
@MainActor
enum VehicleSaveAttempt {
    enum Outcome {
        case saved
        /// The Fuel Log/Reminder/Completion rows to rename could not be fetched. Nothing was
        /// mutated and the save was never attempted.
        case historyLookupFailed(Error)
        /// `save` threw. Every mutation this attempt made has been undone; the caller should
        /// keep the editor open and surface an error.
        case saveFailed(Error)
    }

    /// The historical rows whose `vehicleName` an edit's rename rewrites.
    struct HistoricalRows {
        var fuelLogs: [FuelLogEntry] = []
        var reminders: [MaintenanceReminder] = []
        var completionRecords: [ReminderCompletionRecord] = []
    }

    /// The two I/O steps of an attempt, injectable so tests can force a thrown history fetch or a
    /// thrown save against a real in-memory context. `live` is what production uses.
    struct Seams {
        var fetchHistory: (ModelContext, String) throws -> HistoricalRows
        var save: (ModelContext) throws -> Void

        static var live: Seams {
            Seams(
                fetchHistory: { try VehicleSaveAttempt.fetchHistoricalRows(in: $0, named: $1) },
                save: { try $0.save() }
            )
        }
    }

    /// Every row whose `vehicleName` EXACTLY equals `oldName` — the same exact-string match the
    /// rest of the app uses to decide which vehicle owns a historical record. Throws on any
    /// fetch error instead of returning a partial result.
    static func fetchHistoricalRows(in modelContext: ModelContext, named oldName: String) throws -> HistoricalRows {
        let fuelLogs = try modelContext.fetch(FetchDescriptor<FuelLogEntry>(
            predicate: #Predicate { $0.vehicleName == oldName }
        ))
        let reminders = try modelContext.fetch(FetchDescriptor<MaintenanceReminder>(
            predicate: #Predicate { $0.vehicleName == oldName }
        ))
        let completionRecords = try modelContext.fetch(FetchDescriptor<ReminderCompletionRecord>(
            predicate: #Predicate { $0.vehicleName == oldName }
        ))
        return HistoricalRows(fuelLogs: fuelLogs, reminders: reminders, completionRecords: completionRecords)
    }

    /// Applies `draft` — creating a new vehicle when `vehicle == nil`, otherwise editing
    /// `vehicle` — and saves. `vehicles` is every currently saved vehicle (GarageView's @Query
    /// result, including `vehicle` itself when editing), read before anything is mutated.
    ///
    /// Callers must have already passed the draft through the nickname, retired-nickname, and
    /// vehicle-creation-limit guards; this performs none of them.
    static func perform(
        draft: VehicleDraft,
        editing vehicle: VehicleProfile?,
        among vehicles: [VehicleProfile],
        in modelContext: ModelContext,
        seams: Seams? = nil
    ) -> Outcome {
        // Resolved here, not as a `.live` default argument: default-argument expressions are
        // evaluated outside this function's main-actor isolation.
        let seams = seams ?? .live
        var shouldBeActive = vehicle == nil ? (vehicles.isEmpty || draft.isActive) : draft.isActive

        // Never let a normal edit leave every vehicle inactive: if this is the only currently
        // active vehicle and the edit would turn it off, keep it active instead. Zero active
        // vehicles hides every reminder under the Reminders tab's default filter, so this
        // invariant is enforced here regardless of what AddEditVehicleView's toggle shows —
        // that view surfaces the matching explanation, but this is the actual guarantee.
        if let vehicle, VehicleActivation.shouldKeepActive(
            editedVehicleIsActive: vehicle.isActive,
            requestedActive: shouldBeActive,
            anyOtherVehicleIsActive: vehicles.contains(where: { $0.persistentModelID != vehicle.persistentModelID && $0.isActive })
        ) {
            shouldBeActive = true
        }

        // Preflight, before ANY mutation: the rows a rename would rewrite. A throw here returns
        // with nothing touched, so a fetch error can never leave some history renamed and the
        // rest not.
        var historicalRows: HistoricalRows?
        if let vehicle, vehicle.nickname != draft.nickname, vehicle.nickname.isEmpty == false {
            do {
                historicalRows = try seams.fetchHistory(modelContext, vehicle.nickname)
            } catch {
                return .historyLookupFailed(error)
            }
        }

        // Record the live value of everything this attempt will write. These are the models'
        // current in-memory values — which may themselves be unsaved edits from elsewhere — so
        // restoring them returns to exactly the state this attempt started from.
        let deactivatedVehicles = shouldBeActive
            ? vehicles.filter { $0.persistentModelID != vehicle?.persistentModelID }.map { ActiveState($0) }
            : []
        let editedFields = vehicle.map { VehicleFields($0) }
        let fuelLogNames = (historicalRows?.fuelLogs ?? []).map { ($0, $0.vehicleName) }
        let reminderNames = (historicalRows?.reminders ?? []).map { ($0, $0.vehicleName) }
        let completionNames = (historicalRows?.completionRecords ?? []).map { ($0, $0.vehicleName) }
        var insertedVehicle: VehicleProfile?

        if shouldBeActive {
            for other in vehicles where other.persistentModelID != vehicle?.persistentModelID {
                other.isActive = false
                other.updatedAt = .now
            }
        }

        if let vehicle {
            vehicle.nickname = draft.nickname
            vehicle.year = draft.year
            vehicle.make = draft.make
            vehicle.model = draft.model
            vehicle.trim = draft.trim
            vehicle.tankSizeGallons = draft.tankSizeGallons
            // Routine editing must never lower the odometer — AddEditVehicleView disables Save
            // while the entered value is a regression, but this is the actual guarantee: it
            // holds even if that UI check is ever bypassed or stale.
            vehicle.currentOdometer = VehicleOdometerPolicy.resolvedOdometerForRoutineEdit(
                existing: vehicle.currentOdometer,
                requested: draft.currentOdometer
            )
            // Saving through the Edit Vehicle form always transitions the vehicle to the current
            // preference semantics — even if the resulting value equals what the legacy field
            // already held (see VehicleProfile.calculatorPreferenceSemanticsVersion). The legacy
            // default*/gasEthanolPercent fields are intentionally left untouched below: they are
            // frozen, unread compatibility columns from here on — see VehicleProfile.swift.
            vehicle.preferredEthanolTargetPercent = draft.preferredEthanolTargetPercent
            vehicle.calculatorPreferenceSemanticsVersion = VehiclePreferenceSemantics.current
            vehicle.requiredOctane = draft.requiredOctane
            vehicle.isFlexFuel = draft.isFlexFuel
            vehicle.isActive = shouldBeActive
            vehicle.vehiclePhotoData = draft.vehiclePhotoData
            vehicle.updatedAt = .now
            if let historicalRows {
                for log in historicalRows.fuelLogs { log.vehicleName = draft.nickname }
                for reminder in historicalRows.reminders { reminder.vehicleName = draft.nickname }
                for record in historicalRows.completionRecords { record.vehicleName = draft.nickname }
            }
        } else {
            // Legacy default*/gasEthanolPercent fields are intentionally omitted here — they
            // take VehicleProfile's own persistence-compatible defaults and are never read as a
            // preference for a new-semantics vehicle. See VehicleProfile.swift.
            let newVehicle = VehicleProfile(
                nickname: draft.nickname,
                year: draft.year,
                make: draft.make,
                model: draft.model,
                trim: draft.trim,
                tankSizeGallons: draft.tankSizeGallons,
                currentOdometer: draft.currentOdometer,
                requiredOctane: draft.requiredOctane,
                isFlexFuel: draft.isFlexFuel,
                isActive: shouldBeActive,
                vehiclePhotoData: draft.vehiclePhotoData,
                createdAt: .now,
                updatedAt: .now,
                preferredEthanolTargetPercent: draft.preferredEthanolTargetPercent,
                calculatorPreferenceSemanticsVersion: VehiclePreferenceSemantics.current
            )
            modelContext.insert(newVehicle)
            insertedVehicle = newVehicle
        }

        do {
            try seams.save(modelContext)
            return .saved
        } catch {
            // Undo only this attempt's own writes. Nothing here reads a model after it has been
            // deleted, and nothing touches any other pending change on the context.
            for (log, name) in fuelLogNames { log.vehicleName = name }
            for (reminder, name) in reminderNames { reminder.vehicleName = name }
            for (record, name) in completionNames { record.vehicleName = name }
            editedFields?.restore()
            for state in deactivatedVehicles { state.restore() }
            if let insertedVehicle {
                modelContext.delete(insertedVehicle)
            }
            return .saveFailed(error)
        }
    }

    /// Another vehicle's `isActive`/`updatedAt` before this attempt cleared its active flag.
    private struct ActiveState {
        let vehicle: VehicleProfile
        let isActive: Bool
        let updatedAt: Date

        init(_ vehicle: VehicleProfile) {
            self.vehicle = vehicle
            isActive = vehicle.isActive
            updatedAt = vehicle.updatedAt
        }

        func restore() {
            vehicle.isActive = isActive
            vehicle.updatedAt = updatedAt
        }
    }

    /// Every property `perform` writes on an edited vehicle, as they were before the attempt.
    /// Keep in lockstep with the edit branch above: a property written there but missing here
    /// would survive a failed attempt.
    private struct VehicleFields {
        let vehicle: VehicleProfile
        let nickname: String
        let year: String
        let make: String
        let model: String
        let trim: String
        let tankSizeGallons: Double
        let currentOdometer: Int
        let preferredEthanolTargetPercent: Double?
        let calculatorPreferenceSemanticsVersion: Int
        let requiredOctane: Double
        let isFlexFuel: Bool
        let isActive: Bool
        let vehiclePhotoData: Data?
        let updatedAt: Date

        init(_ vehicle: VehicleProfile) {
            self.vehicle = vehicle
            nickname = vehicle.nickname
            year = vehicle.year
            make = vehicle.make
            model = vehicle.model
            trim = vehicle.trim
            tankSizeGallons = vehicle.tankSizeGallons
            currentOdometer = vehicle.currentOdometer
            preferredEthanolTargetPercent = vehicle.preferredEthanolTargetPercent
            calculatorPreferenceSemanticsVersion = vehicle.calculatorPreferenceSemanticsVersion
            requiredOctane = vehicle.requiredOctane
            isFlexFuel = vehicle.isFlexFuel
            isActive = vehicle.isActive
            vehiclePhotoData = vehicle.vehiclePhotoData
            updatedAt = vehicle.updatedAt
        }

        func restore() {
            vehicle.nickname = nickname
            vehicle.year = year
            vehicle.make = make
            vehicle.model = model
            vehicle.trim = trim
            vehicle.tankSizeGallons = tankSizeGallons
            vehicle.currentOdometer = currentOdometer
            vehicle.preferredEthanolTargetPercent = preferredEthanolTargetPercent
            vehicle.calculatorPreferenceSemanticsVersion = calculatorPreferenceSemanticsVersion
            vehicle.requiredOctane = requiredOctane
            vehicle.isFlexFuel = isFlexFuel
            vehicle.isActive = isActive
            vehicle.vehiclePhotoData = vehiclePhotoData
            vehicle.updatedAt = updatedAt
        }
    }
}
