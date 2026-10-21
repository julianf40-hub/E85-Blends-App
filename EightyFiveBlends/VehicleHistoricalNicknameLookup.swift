//
//  VehicleHistoricalNicknameLookup.swift
//  EightyFiveBlends
//
//  Shared SwiftData fetch for the retired-nickname guard (85Blends 2.4.1) — used identically by
//  every authoritative vehicle-creation/edit boundary (GarageView.saveVehicle, OnboardingView.
//  completeOnboarding) so they all make the exact same decision through VehicleNicknamePolicy,
//  rather than each reimplementing its own interpretation of "which historical names are
//  orphaned." See VehicleNicknamePolicy's "Retired-nickname guard" section for the full
//  rationale; this file is purely the SwiftData I/O VehicleNicknamePolicy deliberately stays
//  independent of.
//

import Foundation
import SwiftData

enum VehicleHistoricalNicknameLookup {
    /// Fetches every vehicleName currently on a Fuel Log, maintenance reminder, or completion
    /// record, and asks VehicleNicknamePolicy which ones are orphaned (no live vehicle owns
    /// them). Throws (rather than swallowing) on a fetch failure so callers can choose to fail
    /// closed instead of silently skipping the check.
    static func orphanedHistoricalNicknameKeys(
        modelContext: ModelContext,
        amongLiveNicknames liveNicknames: [String]
    ) throws -> Set<String> {
        let fuelLogNames = try modelContext.fetch(FetchDescriptor<FuelLogEntry>()).map(\.vehicleName)
        let reminderNames = try modelContext.fetch(FetchDescriptor<MaintenanceReminder>()).map(\.vehicleName)
        let completionNames = try modelContext.fetch(FetchDescriptor<ReminderCompletionRecord>()).map(\.vehicleName)
        return VehicleNicknamePolicy.orphanedHistoricalNicknameKeys(
            historicalVehicleNames: fuelLogNames + reminderNames + completionNames,
            amongLiveNicknames: liveNicknames
        )
    }

    /// The authoritative-boundary form of `orphanedHistoricalNicknameKeys(modelContext:amongLiveNicknames:)`
    /// — a fetch failure here must fail the save closed, never silently allow it, so this is a
    /// `Result`, not an optional a caller could casually coalesce into "nothing reserved."
    static func orphanedHistoricalNicknameKeysResult(
        modelContext: ModelContext,
        amongLiveNicknames liveNicknames: [String]
    ) -> Result<Set<String>, Error> {
        Result { try orphanedHistoricalNicknameKeys(modelContext: modelContext, amongLiveNicknames: liveNicknames) }
    }
}
