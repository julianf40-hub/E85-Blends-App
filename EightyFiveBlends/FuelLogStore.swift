//
//  FuelLogStore.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation
import SwiftData

enum FuelLogStoreError: LocalizedError {
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed:
            return "Couldn’t save this fill-up. Please try again."
        }
    }
}

@MainActor
enum FuelLogStore {
    static func save(
        draft: FuelLogDraft,
        editing entry: FuelLogEntry?,
        entries: [FuelLogEntry],
        activeVehicle: VehicleProfile?,
        modelContext: ModelContext
    ) throws -> FuelLogSaveOutcome {
        var draft = draft
        draft.normalizeForSave()

        let gallonsAdded = round(draft.computedGallonsAdded, places: 2)
        let totalCost = round(draft.computedTotalCost, places: 2)
        let mpg = calculateMPG(for: draft, gallonsAdded: gallonsAdded, editing: entry, entries: entries)

        if let entry {
            entry.date = draft.date
            entry.vehicleName = draft.vehicleName
            entry.stationName = draft.stationName
            entry.odometer = draft.odometer
            entry.targetBlendPercent = draft.targetBlendPercent
            entry.finalBlendPercent = draft.finalBlendPercent
            entry.gallonsAdded = gallonsAdded
            entry.e85Gallons = draft.e85Gallons
            entry.gasGallons = draft.gasGallons
            entry.e85PricePerGallon = draft.e85PricePerGallon
            entry.gasPricePerGallon = draft.gasPricePerGallon
            entry.totalCost = totalCost
            entry.mpg = mpg
            entry.notes = draft.notes
        } else {
            let newEntry = FuelLogEntry(
                vehicleName: draft.vehicleName,
                date: draft.date,
                stationName: draft.stationName,
                odometer: draft.odometer,
                targetBlendPercent: draft.targetBlendPercent,
                finalBlendPercent: draft.finalBlendPercent,
                gallonsAdded: gallonsAdded,
                e85Gallons: draft.e85Gallons,
                gasGallons: draft.gasGallons,
                e85PricePerGallon: draft.e85PricePerGallon,
                gasPricePerGallon: draft.gasPricePerGallon,
                totalCost: totalCost,
                mpg: mpg,
                notes: draft.notes
            )
            modelContext.insert(newEntry)
        }

        if let activeVehicle,
           activeVehicle.nickname == draft.vehicleName,
           draft.odometer > activeVehicle.currentOdometer {
            activeVehicle.currentOdometer = draft.odometer
            activeVehicle.updatedAt = .now
        }

        let linkedStation = updateStationIfNeeded(from: draft, modelContext: modelContext)
        do {
            try modelContext.save()
        } catch {
            AppHaptics.warning()
            throw FuelLogStoreError.saveFailed
        }

        AppHaptics.success()

        return FuelLogSaveOutcome(
            stationName: draft.stationName.trimmingCharacters(in: .whitespacesAndNewlines),
            e85PricePerGallon: round(draft.e85PricePerGallon, places: 2),
            e85Gallons: round(draft.e85Gallons, places: 2),
            fillUpDate: draft.date,
            linkedStation: linkedStation
        )
    }

    static func prefillDraft(from result: BlendCalculator.Result, vehicle: VehicleProfile?) -> FuelLogDraft {
        // Guidance (E85-only) results carry the achieved blend in blendLabel; prefer
        // the explicitly requested target when the calculator provides one.
        let targetBlendPercent = result.requestedTargetEthanolPercent
            ?? Double(result.blendLabel.dropFirst())
            ?? result.finalEthanolPercent

        return FuelLogDraft(
            date: .now,
            vehicleName: vehicle?.nickname ?? "",
            stationName: "",
            odometer: vehicle?.currentOdometer ?? 0,
            targetBlendPercent: targetBlendPercent,
            finalBlendPercent: result.finalEthanolPercent,
            e85Gallons: result.e85Gallons,
            gasGallons: result.gasGallons,
            e85PricePerGallon: 0,
            gasPricePerGallon: 0,
            mpg: 0,
            notes: ""
        )
    }

    static func prefillDraft(from vehicle: VehicleProfile?) -> FuelLogDraft {
        return FuelLogDraft(
            date: .now,
            vehicleName: vehicle?.nickname ?? "",
            stationName: "",
            odometer: vehicle?.currentOdometer ?? 0,
            targetBlendPercent: vehicle?.defaultTargetEthanolPercent ?? 30,
            finalBlendPercent: vehicle?.defaultTargetEthanolPercent ?? 30,
            e85Gallons: 0,
            gasGallons: 0,
            e85PricePerGallon: 0,
            gasPricePerGallon: 0,
            mpg: 0,
            notes: ""
        )
    }

    private static func calculateMPG(
        for draft: FuelLogDraft,
        gallonsAdded: Double,
        editing entry: FuelLogEntry?,
        entries: [FuelLogEntry]
    ) -> Double {
        guard gallonsAdded > 0 else { return 0 }

        let previousEntry = entries
            .filter {
                $0.vehicleName == draft.vehicleName &&
                $0.persistentModelID != entry?.persistentModelID &&
                $0.odometer < draft.odometer
            }
            .sorted {
                if $0.odometer == $1.odometer {
                    return $0.date > $1.date
                }
                return $0.odometer > $1.odometer
            }
            .first

        guard let previousEntry else {
            return 0
        }

        let milesDriven = draft.odometer - previousEntry.odometer
        guard milesDriven > 0 else { return 0 }

        return round(Double(milesDriven) / gallonsAdded, places: 1)
    }

    private static func round(_ value: Double, places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (value * factor).rounded() / factor
    }

    private static func updateStationIfNeeded(from draft: FuelLogDraft, modelContext: ModelContext) -> FuelStation? {
        let trimmedName = draft.stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, StationDataValidation.isValidPrice(draft.e85PricePerGallon) else { return nil }

        let price = round(draft.e85PricePerGallon, places: 2)

        // Fast path: exact case-sensitive predicate match — avoids a full table scan.
        var exactDescriptor = FetchDescriptor<FuelStation>(
            predicate: #Predicate { $0.name == trimmedName }
        )
        exactDescriptor.fetchLimit = 1
        if let station = (try? modelContext.fetch(exactDescriptor))?.first {
            station.lastKnownE85Price = price
            station.lastUpdated = .now
            station.updatedAt = .now
            return station
        }

        // Slow path: case/whitespace-insensitive in-memory scan for stations saved with
        // different casing or stray whitespace.
        let allStations = (try? modelContext.fetch(FetchDescriptor<FuelStation>())) ?? []
        if let station = allStations.first(where: { StationDataValidation.isDuplicateName($0.name, trimmedName) }) {
            station.lastKnownE85Price = price
            station.lastUpdated = .now
            station.updatedAt = .now
            return station
        }

        let station = FuelStation(
            name: trimmedName,
            lastKnownE85Price: price,
            lastUpdated: .now,
            createdAt: .now,
            updatedAt: .now
        )
        modelContext.insert(station)
        return station
    }
}

struct FuelLogSaveOutcome {
    let stationName: String
    let e85PricePerGallon: Double
    let e85Gallons: Double
    let fillUpDate: Date
    let linkedStation: FuelStation?

    var shouldOfferCommunityPriceReport: Bool {
        stationName.isEmpty == false && e85PricePerGallon > 0 && e85Gallons > 0
    }
}
