//
//  SavedTripStore.swift
//  EightyFiveBlends
//
//  Local persistence for Pro-only saved routes. Stored as JSON in UserDefaults.
//  No CloudKit for this first version.
//  TODO: Add CloudKit / cross-device sync in a future version.
//

import Foundation

struct SavedTrip: Codable, Identifiable {
    let id: UUID
    let originText: String
    let destinationText: String
    let selectedVehicleName: String
    let tankSizeGallons: Double
    let estimatedMPG: Double
    let targetBlendPercent: Double
    let currentFuelLevelPercent: Double
    let targetArrivalReservePercent: Double
    let fuelBackupModeRaw: String      // "gasBackupAllowed" | "e85Required"
    let totalDistanceMiles: Double
    let estimatedDriveTimeSeconds: Double
    let estimatedFuelNeededGallons: Double
    let estimatedStopsCount: Int
    let routeRiskRaw: String           // "low" | "medium" | "high"
    let routeOutcomeRaw: String
    let savedDate: Date
    let recommendedStopNames: [String]

    var fuelBackupMode: FuelBackupMode {
        fuelBackupModeRaw == "gasBackupAllowed" ? .gasBackupAllowed : .e85Required
    }

    var routeRisk: TripPlan.RouteRisk? {
        switch routeRiskRaw {
        case "low":    return .low
        case "medium": return .medium
        case "high":   return .high
        default:       return nil
        }
    }
}

@Observable
final class SavedTripStore {
    static let shared = SavedTripStore()

    private static let defaultsKey = "savedTrips_v1"

    private(set) var trips: [SavedTrip] = []

    private init() { load() }

    /// True when the origin / destination / settings combo is not yet in the saved list.
    func canSave(
        origin: String,
        destination: String,
        tankSizeGallons: Double,
        estimatedMPG: Double,
        targetBlendPercent: Double,
        targetArrivalReservePercent: Double,
        fuelBackupMode: FuelBackupMode
    ) -> Bool {
        let fp = fingerprint(
            origin: origin, destination: destination,
            tankSizeGallons: tankSizeGallons, estimatedMPG: estimatedMPG,
            targetBlendPercent: targetBlendPercent,
            targetArrivalReservePercent: targetArrivalReservePercent,
            fuelBackupMode: fuelBackupMode
        )
        return trips.contains { tripFingerprint($0) == fp } == false
    }

    func save(_ trip: SavedTrip) {
        guard canSave(
            origin: trip.originText, destination: trip.destinationText,
            tankSizeGallons: trip.tankSizeGallons, estimatedMPG: trip.estimatedMPG,
            targetBlendPercent: trip.targetBlendPercent,
            targetArrivalReservePercent: trip.targetArrivalReservePercent,
            fuelBackupMode: trip.fuelBackupMode
        ) else { return }
        trips.insert(trip, at: 0)
        persist()
    }

    func delete(_ trip: SavedTrip) {
        trips.removeAll { $0.id == trip.id }
        persist()
    }

    // MARK: - Private

    private func tripFingerprint(_ trip: SavedTrip) -> String {
        fingerprint(
            origin: trip.originText, destination: trip.destinationText,
            tankSizeGallons: trip.tankSizeGallons, estimatedMPG: trip.estimatedMPG,
            targetBlendPercent: trip.targetBlendPercent,
            targetArrivalReservePercent: trip.targetArrivalReservePercent,
            fuelBackupMode: trip.fuelBackupMode
        )
    }

    private func fingerprint(
        origin: String, destination: String,
        tankSizeGallons: Double, estimatedMPG: Double,
        targetBlendPercent: Double, targetArrivalReservePercent: Double,
        fuelBackupMode: FuelBackupMode
    ) -> String {
        let o = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let d = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let backup = fuelBackupMode == .gasBackupAllowed ? "gas" : "e85"
        return "\(o)|\(d)|\(Int(tankSizeGallons.rounded()))|\(Int(estimatedMPG.rounded()))|\(Int(targetBlendPercent.rounded()))|\(Int(targetArrivalReservePercent.rounded()))|\(backup)"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(trips) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedTrip].self, from: data) else { return }
        trips = decoded
    }
}
