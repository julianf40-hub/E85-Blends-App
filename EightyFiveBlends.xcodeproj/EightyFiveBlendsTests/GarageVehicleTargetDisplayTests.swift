//
//  GarageVehicleTargetDisplayTests.swift
//  EightyFiveBlendsTests
//
//  Tests for GarageVehicleTargetDisplay — the on-device Build 80 hotfix for Garage showing "E30"
//  on a brand-new vehicle whose Preferred Ethanol Target was genuinely never set. This answers a
//  different question than FuelPreferenceResolution.PreferredTargetResolution ("what is
//  configured on this vehicle?" vs. "what should Calculator use right now?"), so a nil
//  preference on a current-semantics vehicle must resolve to nil here — never falling through to
//  an app-level preference or E30 the way Calculator correctly does for the same vehicle.
//
//  Note: like every other file in this directory, this is not currently wired into a test target
//  in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a test target
//  is added. Written to compile and pass once one exists.
//
//  Does not duplicate or weaken PreferredTargetResolutionTests.swift — that resolver and its
//  tests are unchanged by this hotfix.

import Testing
@testable import EightyFiveBlends

struct GarageVehicleTargetDisplayTests {

    // MARK: - Legacy-semantics vehicle (calculatorPreferenceSemanticsVersion == 0)

    @Test("A legacy vehicle with a stored target of E30 displays E30")
    func legacyVehicle_e30_displaysE30() {
        let vehicle = VehicleProfile(defaultTargetEthanolPercent: 30)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) == 30)
    }

    @Test("A legacy vehicle with a stored target of E50 displays E50")
    func legacyVehicle_e50_displaysE50() {
        let vehicle = VehicleProfile(defaultTargetEthanolPercent: 50)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) == 50)
    }

    @Test("A legacy vehicle's target is never nil — it is always considered configured")
    func legacyVehicle_isNeverNil() {
        // Even the model's own bare default (30) counts as the vehicle's real legacy
        // preference — legacy semantics never has a "not set" state.
        let vehicle = VehicleProfile()
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) != nil)
    }

    // MARK: - Current-semantics vehicle with a configured preference

    @Test("A current-semantics vehicle with preferred E30 displays E30")
    func currentSemantics_preferredE30_displaysE30() {
        let vehicle = VehicleProfile(preferredEthanolTargetPercent: 30, calculatorPreferenceSemanticsVersion: 1)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) == 30)
    }

    @Test("A current-semantics vehicle with preferred E50 displays E50")
    func currentSemantics_preferredE50_displaysE50() {
        let vehicle = VehicleProfile(preferredEthanolTargetPercent: 50, calculatorPreferenceSemanticsVersion: 1)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) == 50)
    }

    @Test("A current-semantics vehicle with an explicit E0 preference displays E0, not \"Not set\"")
    func currentSemantics_explicitE0_displaysZero() {
        let vehicle = VehicleProfile(preferredEthanolTargetPercent: 0, calculatorPreferenceSemanticsVersion: 1)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) == 0)
    }

    // MARK: - Current-semantics vehicle with no / invalid configured preference — must show "Not set"

    @Test("A current-semantics vehicle with a nil preference resolves to nil (Garage shows \"Not set\") — this is the exact Build 80 bug")
    func currentSemantics_nilPreference_resolvesToNil() {
        let vehicle = VehicleProfile(calculatorPreferenceSemanticsVersion: 1)
        #expect(vehicle.preferredEthanolTargetPercent == nil)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) == nil)
    }

    @Test("A current-semantics vehicle with a negative stored preference resolves to nil, not malformed data")
    func currentSemantics_negativePreference_resolvesToNil() {
        let vehicle = VehicleProfile(preferredEthanolTargetPercent: -5, calculatorPreferenceSemanticsVersion: 1)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) == nil)
    }

    @Test("A current-semantics vehicle with a stored preference over 100 resolves to nil, not malformed data")
    func currentSemantics_overOneHundredPreference_resolvesToNil() {
        let vehicle = VehicleProfile(preferredEthanolTargetPercent: 150, calculatorPreferenceSemanticsVersion: 1)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) == nil)
    }

    @Test("A current-semantics vehicle with a NaN or infinite stored preference resolves to nil")
    func currentSemantics_nonFinitePreference_resolvesToNil() {
        let nanVehicle = VehicleProfile(preferredEthanolTargetPercent: .nan, calculatorPreferenceSemanticsVersion: 1)
        let infVehicle = VehicleProfile(preferredEthanolTargetPercent: .infinity, calculatorPreferenceSemanticsVersion: 1)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: nanVehicle) == nil)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: infVehicle) == nil)
    }

    // MARK: - The critical semantic separation from Calculator's resolution

    @Test("A current-semantics vehicle with a nil preference does NOT fall through to the app-level/E30 preference the way Calculator correctly does")
    func currentSemantics_nilPreference_doesNotFallThroughToAppLevelDefault() {
        let vehicle = VehicleProfile(calculatorPreferenceSemanticsVersion: 1)

        // Contrast: Calculator's own resolver DOES fall through to an app-level preference (E30
        // here) for the exact same vehicle — that is correct Calculator behavior and is
        // untouched by this hotfix.
        let calculatorEffectiveTarget = PreferredTargetResolution.resolve(vehicle: vehicle, appPreferredTarget: 30)
        #expect(calculatorEffectiveTarget == 30)

        // Garage must NOT mirror that fallback — it must report nil so the UI shows "Not set",
        // never silently displaying the Calculator fallback value as if it were configured.
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) == nil)
        #expect(GarageVehicleTargetDisplay.targetPercent(for: vehicle) != calculatorEffectiveTarget)
    }
}
