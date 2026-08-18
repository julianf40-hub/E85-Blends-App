//
//  CurrentEthanolEndToEndTests.swift
//  EightyFiveBlendsTests
//
//  Chains VehicleFuelLogIdentityResolution -> LatestValidFuelLogBlend -> CurrentEthanolResolution
//  exactly as CalculatorView.lastLoggedBlendForActiveVehicle does, to directly verify the
//  corrective pass's required end-to-end scenarios without needing SwiftUI/live SwiftData
//  infrastructure — every piece here is a pure function or an in-memory model construction.
//
//  Note: like every other file in this directory, this is not currently wired into a test target
//  in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a test target
//  is added. Written to compile and pass once one exists.

import Testing
@testable import EightyFiveBlends

struct CurrentEthanolEndToEndTests {

    /// Mirrors CalculatorView.lastLoggedBlendForActiveVehicle exactly, so a passing test here is
    /// a direct statement about that production code path (not a duplicate reimplementation of
    /// its own logic — the two pieces it chains are the same ones CalculatorView calls).
    private func currentEthanol(activeVehicle: VehicleProfile, allVehicles: [VehicleProfile], entries: [FuelLogEntry]) -> Double {
        let latestLoggedBlendPercent: Double?
        if let safeName = VehicleFuelLogIdentityResolution.safeFuelLogVehicleName(for: activeVehicle, among: allVehicles) {
            latestLoggedBlendPercent = LatestValidFuelLogBlend.resolve(entries: entries, vehicleName: safeName)
        } else {
            latestLoggedBlendPercent = nil
        }
        return CurrentEthanolResolution.resolve(latestLoggedBlendPercent: latestLoggedBlendPercent)
    }

    @Test("A unique vehicle with a valid latest log resolves to that log's blend")
    func uniqueVehicle_validLog_resolvesToLoggedBlend() {
        let truck = VehicleProfile(nickname: "Truck")
        let entries = [FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 40)]
        #expect(currentEthanol(activeVehicle: truck, allVehicles: [truck], entries: entries) == 40)
    }

    @Test("A unique vehicle with an explicit E0 latest log resolves to 0, not E10")
    func uniqueVehicle_explicitZeroLog_resolvesToZero() {
        let truck = VehicleProfile(nickname: "Truck")
        let entries = [FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 0)]
        #expect(currentEthanol(activeVehicle: truck, allVehicles: [truck], entries: entries) == 0)
    }

    @Test("No log at all for the vehicle falls back to E10")
    func noLog_fallsBackToE10() {
        let truck = VehicleProfile(nickname: "Truck")
        #expect(currentEthanol(activeVehicle: truck, allVehicles: [truck], entries: []) == 10)
    }

    @Test("A blank-nickname vehicle, even with fuel logs recorded under a blank name, falls back to E10")
    func blankNickname_fallsBackToE10_evenWithMatchingBlankNameLogs() {
        let unnamed = VehicleProfile(nickname: "")
        // Entries recorded under the same blank name that a naive match WOULD find — the safety
        // rule must refuse this regardless, since a blank name is never a trustworthy identifier.
        let entries = [FuelLogEntry(vehicleName: "", finalBlendPercent: 55)]
        #expect(currentEthanol(activeVehicle: unnamed, allVehicles: [unnamed], entries: entries) == 10)
    }

    @Test("A duplicate nickname, even with matching fuel log history, falls back to E10")
    func duplicateNickname_fallsBackToE10_evenWithMatchingHistory() {
        let truck1 = VehicleProfile(nickname: "Truck")
        let truck2 = VehicleProfile(nickname: "Truck")
        // History that WOULD match "Truck" — must not be trusted, since it's ambiguous which of
        // the two vehicles named "Truck" it actually belongs to.
        let entries = [FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 60)]
        #expect(currentEthanol(activeVehicle: truck1, allVehicles: [truck1, truck2], entries: entries) == 10)
        #expect(currentEthanol(activeVehicle: truck2, allVehicles: [truck1, truck2], entries: entries) == 10)
    }

    @Test("Switching from Vehicle A to Vehicle B cannot cause A's latest blend to resolve for B")
    func switchingVehicles_doesNotLeakBetweenVehicles() {
        let truck = VehicleProfile(nickname: "Truck")
        let sedan = VehicleProfile(nickname: "Sedan")
        let allVehicles = [truck, sedan]
        let entries = [
            FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 70), // newest overall, belongs to Truck
            FuelLogEntry(vehicleName: "Sedan", finalBlendPercent: 20),
        ]

        // While Truck is active:
        #expect(currentEthanol(activeVehicle: truck, allVehicles: allVehicles, entries: entries) == 70)
        // After switching to Sedan — Sedan's own (older, lower) blend, never Truck's 70:
        #expect(currentEthanol(activeVehicle: sedan, allVehicles: allVehicles, entries: entries) == 20)
    }

    @Test("Switching to a vehicle with no history of its own falls back to E10, not the previous vehicle's blend")
    func switchingToVehicleWithNoHistory_fallsBackToE10_notPreviousVehiclesBlend() {
        let truck = VehicleProfile(nickname: "Truck")
        let newCar = VehicleProfile(nickname: "New Car")
        let entries = [FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 70)]

        #expect(currentEthanol(activeVehicle: truck, allVehicles: [truck, newCar], entries: entries) == 70)
        #expect(currentEthanol(activeVehicle: newCar, allVehicles: [truck, newCar], entries: entries) == 10)
    }
}
