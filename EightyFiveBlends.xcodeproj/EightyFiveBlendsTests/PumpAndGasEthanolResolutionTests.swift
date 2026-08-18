//
//  PumpAndGasEthanolResolutionTests.swift
//  EightyFiveBlendsTests
//
//  Tests for FuelPreferenceResolution.PumpEthanolResolution / GasEthanolResolution — Pump and Gas
//  Ethanol are app-level "remembered" preferences under 85Blends 2.3.0, never vehicle-permanent
//  properties. Shared by CalculatorView, AtThePumpView, and CostCalculatorView.
//
//  Note: like every other file in this directory, this is not currently wired into a test target
//  in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a test target
//  is added. Written to compile and pass once one exists.

import Testing
@testable import EightyFiveBlends

struct PumpAndGasEthanolResolutionTests {

    // MARK: - Pump Ethanol

    @Test("A valid remembered pump ethanol content is used as-is")
    func pumpEthanol_validRemembered_isUsed() {
        #expect(PumpEthanolResolution.resolve(remembered: 78) == 78)
    }

    @Test("No remembered pump ethanol content falls back to E85")
    func pumpEthanol_noRemembered_fallsBackToE85() {
        #expect(PumpEthanolResolution.resolve(remembered: nil) == 85)
    }

    @Test("An out-of-range or non-finite remembered pump ethanol content falls back to E85")
    func pumpEthanol_invalidRemembered_fallsBackToE85() {
        #expect(PumpEthanolResolution.resolve(remembered: -1) == 85)
        #expect(PumpEthanolResolution.resolve(remembered: 150) == 85)
        #expect(PumpEthanolResolution.resolve(remembered: .nan) == 85)
    }

    // MARK: - Gas Ethanol

    @Test("A valid remembered gas ethanol content is used as-is")
    func gasEthanol_validRemembered_isUsed() {
        #expect(GasEthanolResolution.resolve(remembered: 15) == 15)
    }

    @Test("No remembered gas ethanol content falls back to E10")
    func gasEthanol_noRemembered_fallsBackToE10() {
        #expect(GasEthanolResolution.resolve(remembered: nil) == 10)
    }

    @Test("Explicit E0 remembered gas ethanol is honored, not treated as absent")
    func gasEthanol_explicitZeroRemembered_isHonored() {
        #expect(GasEthanolResolution.resolve(remembered: 0) == 0)
    }

    @Test("An out-of-range or non-finite remembered gas ethanol content falls back to E10")
    func gasEthanol_invalidRemembered_fallsBackToE10() {
        #expect(GasEthanolResolution.resolve(remembered: -1) == 10)
        #expect(GasEthanolResolution.resolve(remembered: 150) == 10)
        #expect(GasEthanolResolution.resolve(remembered: .nan) == 10)
    }
}

/// RememberedFuelPreferenceStore reads/writes real `UserDefaults.standard` under the app's own
/// production keys, so each test saves and restores the prior value (even if never previously
/// set) to avoid leaking state into other tests or a real device/simulator's defaults.
struct RememberedFuelPreferenceStoreTests {

    @Test("A remembered pump ethanol value round-trips through the store")
    func pumpEthanol_roundTrips() {
        let key = AppPreferenceKey.lastPumpE85Content
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        RememberedFuelPreferenceStore.rememberPumpEthanolPercent(82)
        #expect(RememberedFuelPreferenceStore.rememberedPumpEthanolPercent() == 82)
    }

    @Test("A remembered pump ethanol value outside the validated range is not returned")
    func pumpEthanol_outOfRangeIsRejectedOnRead() {
        let key = AppPreferenceKey.lastPumpE85Content
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        // Store writes unconditionally (matching AtThePumpView's existing persistLastPumpSetup
        // behavior); validation happens on read, so garbage in never reaches a calculation.
        RememberedFuelPreferenceStore.rememberPumpEthanolPercent(5)
        #expect(RememberedFuelPreferenceStore.rememberedPumpEthanolPercent() == nil)
    }

    @Test("A remembered gas ethanol value round-trips through the store")
    func gasEthanol_roundTrips() {
        let key = AppPreferenceKey.rememberedGasEthanolPercent
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        RememberedFuelPreferenceStore.rememberGasEthanolPercent(12)
        #expect(RememberedFuelPreferenceStore.rememberedGasEthanolPercent() == 12)
    }

    @Test("No remembered gas ethanol value returns nil rather than a guessed default")
    func gasEthanol_absentReturnsNil() {
        let key = AppPreferenceKey.rememberedGasEthanolPercent
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(RememberedFuelPreferenceStore.rememberedGasEthanolPercent() == nil)
    }
}
