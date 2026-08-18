//
//  PreferredTargetResolutionTests.swift
//  EightyFiveBlendsTests
//
//  Tests for FuelPreferenceResolution.PreferredTargetResolution — the 85Blends 2.3.0 Garage
//  simplification's Preferred Ethanol Target precedence, shared by CalculatorView, AtThePumpView,
//  FuelLogStore, TripPlannerView, and GarageView's own summary card. Directly verifies production
//  behavior, not a duplicate reimplementation.
//
//  Note: like every other file in this directory, this is not currently wired into a test target
//  in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a test target
//  is added. Written to compile and pass once one exists.
//

import Testing
@testable import EightyFiveBlends

struct PreferredTargetResolutionTests {

    // MARK: - Legacy-semantics vehicle (calculatorPreferenceSemanticsVersion == 0)

    @Test("A legacy vehicle's stored defaultTargetEthanolPercent is always the effective preference")
    func legacyVehicle_usesStoredLegacyTarget() {
        let vehicle = VehicleProfile(defaultTargetEthanolPercent: 45)
        let result = PreferredTargetResolution.resolve(vehicle: vehicle, appPreferredTarget: 60)
        #expect(result == 45)
    }

    @Test("A legacy vehicle's target is honored even when a preferredEthanolTargetPercent happens to be set")
    func legacyVehicle_ignoresPreferredEthanolTargetPercent() {
        // Not a reachable real-world state via the app's own save path (legacy vehicles never
        // have this field populated until they're saved through Edit Vehicle, which also bumps
        // the semantics version) — but the precedence rule itself must hold defensively.
        let vehicle = VehicleProfile(defaultTargetEthanolPercent: 45, preferredEthanolTargetPercent: 70)
        #expect(PreferredTargetResolution.resolve(vehicle: vehicle, appPreferredTarget: 60) == 45)
    }

    // MARK: - New-semantics vehicle (calculatorPreferenceSemanticsVersion >= 1)

    @Test("A new-semantics vehicle with a set Preferred Ethanol Target resolves to it")
    func newSemanticsVehicle_withTarget_resolvesToTarget() {
        let vehicle = VehicleProfile(preferredEthanolTargetPercent: 60, calculatorPreferenceSemanticsVersion: 1)
        #expect(PreferredTargetResolution.resolve(vehicle: vehicle, appPreferredTarget: 40) == 60)
    }

    @Test("A new-semantics vehicle with no Preferred Ethanol Target falls back to the app-level preference")
    func newSemanticsVehicle_noTarget_fallsBackToAppPreference() {
        let vehicle = VehicleProfile(calculatorPreferenceSemanticsVersion: 1)
        #expect(vehicle.preferredEthanolTargetPercent == nil)
        #expect(PreferredTargetResolution.resolve(vehicle: vehicle, appPreferredTarget: 40) == 40)
    }

    @Test("Explicit E0 is a legitimate configured Preferred Ethanol Target and is NOT interpreted as nil/unset")
    func newSemanticsVehicle_explicitZeroTarget_isHonored() {
        let vehicle = VehicleProfile(preferredEthanolTargetPercent: 0, calculatorPreferenceSemanticsVersion: 1)
        // Must resolve to 0, not fall through to the app preference (40) or E30.
        #expect(PreferredTargetResolution.resolve(vehicle: vehicle, appPreferredTarget: 40) == 0)
    }

    @Test("An out-of-range Preferred Ethanol Target is treated as invalid and falls back to the app preference")
    func newSemanticsVehicle_outOfRangeTarget_fallsBack() {
        let tooHigh = VehicleProfile(preferredEthanolTargetPercent: 150, calculatorPreferenceSemanticsVersion: 1)
        let negative = VehicleProfile(preferredEthanolTargetPercent: -5, calculatorPreferenceSemanticsVersion: 1)
        #expect(PreferredTargetResolution.resolve(vehicle: tooHigh, appPreferredTarget: 40) == 40)
        #expect(PreferredTargetResolution.resolve(vehicle: negative, appPreferredTarget: 40) == 40)
    }

    @Test("A non-finite Preferred Ethanol Target is treated as invalid and falls back to the app preference")
    func newSemanticsVehicle_nonFiniteTarget_fallsBack() {
        let vehicle = VehicleProfile(preferredEthanolTargetPercent: .nan, calculatorPreferenceSemanticsVersion: 1)
        #expect(PreferredTargetResolution.resolve(vehicle: vehicle, appPreferredTarget: 40) == 40)
    }

    // MARK: - No vehicle selected

    @Test("No vehicle selected resolves to the app-level preferred target")
    func noVehicle_resolvesToAppPreference() {
        #expect(PreferredTargetResolution.resolve(vehicle: nil, appPreferredTarget: 55) == 55)
    }

    @Test("No vehicle selected and no valid app preference falls back to E30")
    func noVehicle_invalidAppPreference_fallsBackToE30() {
        #expect(PreferredTargetResolution.resolve(vehicle: nil, appPreferredTarget: .nan) == 30)
        #expect(PreferredTargetResolution.resolve(vehicle: nil, appPreferredTarget: -1) == 30)
        #expect(PreferredTargetResolution.resolve(vehicle: nil, appPreferredTarget: 200) == 30)
    }

    @Test("A new-semantics vehicle with no target and an invalid app preference falls all the way back to E30")
    func newSemanticsVehicle_noTargetAndInvalidAppPreference_fallsBackToE30() {
        let vehicle = VehicleProfile(calculatorPreferenceSemanticsVersion: 1)
        #expect(PreferredTargetResolution.resolve(vehicle: vehicle, appPreferredTarget: .nan) == 30)
    }

    // MARK: - AppPreferredTargetBlend parsing

    @Test("AppPreferredTargetBlend parses a recognized raw value")
    func appPreferredTargetBlend_parsesRecognizedRawValue() {
        #expect(AppPreferredTargetBlend.percent(fromRawValue: "E50") == 50)
    }

    @Test("AppPreferredTargetBlend falls back to E30 for an unrecognized/corrupt raw value")
    func appPreferredTargetBlend_unrecognizedRawValue_fallsBackToE30() {
        #expect(AppPreferredTargetBlend.percent(fromRawValue: "garbage") == 30)
        #expect(AppPreferredTargetBlend.percent(fromRawValue: "") == 30)
    }
}
