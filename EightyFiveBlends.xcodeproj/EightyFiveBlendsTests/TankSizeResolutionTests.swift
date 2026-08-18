//
//  TankSizeResolutionTests.swift
//  EightyFiveBlendsTests
//
//  Tests for FuelPreferenceResolution.TankSizeResolution — the audited AtThePumpView.swift
//  zero-tank gap (a selected vehicle with no known tank capacity used to flow straight through
//  as 0 instead of falling back to whatever Calculator already had). Also exercises
//  BlendCalculator's existing zero-tank guard directly, confirming a 0/unset tank never produces
//  a crash or a misleading blend result end to end.
//
//  Note: like every other file in this directory, this is not currently wired into a test target
//  in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a test target
//  is added. Written to compile and pass once one exists.

import Testing
@testable import EightyFiveBlends

struct TankSizeResolutionTests {

    @Test("A vehicle with a real tank size wins over the calculator's value")
    func vehicleTankSize_realValue_wins() {
        let result = TankSizeResolution.resolve(vehicleTankSizeGallons: 18, calculatorTankSizeGallons: 15.5)
        #expect(result == 18)
    }

    @Test("A vehicle with tank size 0 (unset) falls back to the calculator's value — the audited zero-tank gap")
    func vehicleTankSize_unset_fallsBackToCalculatorValue() {
        let result = TankSizeResolution.resolve(vehicleTankSizeGallons: 0, calculatorTankSizeGallons: 15.5)
        #expect(result == 15.5)
    }

    @Test("No vehicle at all falls back to the calculator's value")
    func noVehicle_fallsBackToCalculatorValue() {
        let result = TankSizeResolution.resolve(vehicleTankSizeGallons: nil, calculatorTankSizeGallons: 15.5)
        #expect(result == 15.5)
    }

    @Test("A negative or non-finite vehicle tank size falls back to the calculator's value")
    func vehicleTankSize_invalid_fallsBackToCalculatorValue() {
        #expect(TankSizeResolution.resolve(vehicleTankSizeGallons: -5, calculatorTankSizeGallons: 15.5) == 15.5)
        #expect(TankSizeResolution.resolve(vehicleTankSizeGallons: .nan, calculatorTankSizeGallons: 15.5) == 15.5)
    }

    @Test("Both vehicle and calculator tank size unset resolves to 0 — BlendCalculator must handle this safely, not crash")
    func bothUnset_resolvesToZero_andBlendCalculatorHandlesItSafely() {
        let resolved = TankSizeResolution.resolve(vehicleTankSizeGallons: 0, calculatorTankSizeGallons: 0)
        #expect(resolved == 0)

        // Confirms the end-to-end guarantee this gap fix exists for: a 0/unset tank must never
        // crash or produce a misleading blend — BlendCalculator's own guard (already covered
        // more exhaustively in BlendCalculatorTests.swift) returns a zeroed, warned result.
        let result = BlendCalculator.calculate(input: .init(
            tankSizeGallons: resolved,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        ))
        #expect(result.warningMessage != nil)
        #expect(result.totalGallonsToAdd == 0)
    }
}
