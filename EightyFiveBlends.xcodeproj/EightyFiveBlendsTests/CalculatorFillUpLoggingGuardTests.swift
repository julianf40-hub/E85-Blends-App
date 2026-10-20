//
//  CalculatorFillUpLoggingGuardTests.swift
//  EightyFiveBlendsTests
//
//  Regression coverage for a related data-integrity gap found alongside the Calculator
//  silent-zero-fallback fix: CalculatorView's "+ Log This Fill-Up" action used to call
//  FuelLogStore.prefillDraft(from: calculation, ...) unconditionally, even when
//  calculation.warningMessage was non-nil (invalid input routed to NaN, an already-full
//  tank, an unreachable blend, etc.). A warning result always carries zero gallons and an
//  untrustworthy blend percent, so logging it would silently save a misleading fill-up.
//  CalculatorView now gates that action on `hasBlendWarning` (calculation.warningMessage
//  != nil) — these tests verify the underlying invariant that gate depends on: a warning
//  result is never safe to log, and every legitimate (including zero-valued) result still
//  produces a sensible, loggable draft.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct CalculatorFillUpLoggingGuardTests {

    // MARK: - Invalid input must never produce a loggable result

    @Test("A blank field routed to NaN produces a warning result with zero gallons — never loggable")
    func blankField_producesUnloggableZeroGallonResult() {
        let input = BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("15.5") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("") ?? .nan, // cleared mid-edit
            currentFuelEthanolPercent: CalculatorNumericInput.parse("20") ?? .nan,
            targetEthanolPercent: CalculatorNumericInput.parse("50") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("82") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("91") ?? .nan
        )

        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage != nil)
        #expect(result.e85Gallons == 0)
        #expect(result.gasGallons == 0)

        let draft = FuelLogStore.prefillDraft(from: result, vehicle: nil)
        #expect(draft.e85Gallons == 0)
        #expect(draft.gasGallons == 0)
        #expect(draft.computedGallonsAdded == 0)
    }

    @Test("A typo routed to NaN produces a warning result with zero gallons — never loggable")
    func typo_producesUnloggableZeroGallonResult() {
        let input = BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("15.5") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("25") ?? .nan,
            currentFuelEthanolPercent: CalculatorNumericInput.parse("2o") ?? .nan, // typo for "20"
            targetEthanolPercent: CalculatorNumericInput.parse("50") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("82") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("91") ?? .nan
        )

        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage != nil)

        let draft = FuelLogStore.prefillDraft(from: result, vehicle: nil)
        #expect(draft.computedGallonsAdded == 0)
    }

    @Test("An unreachable-blend warning (non-input-related) also carries zero gallons — never loggable")
    func unreachableBlendWarning_alsoUnloggable() {
        // Current level above target with no partial fill specified — a pre-existing,
        // non-input-validation warning path (BlendCalculator's own "cannot exceed tank"
        // guard), confirming the gate protects against every warning source, not just NaN.
        let input = BlendCalculator.Input(
            tankSizeGallons: 15,
            currentFuelLevelPercent: 150, // out of range
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 50,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        )

        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage != nil)

        let draft = FuelLogStore.prefillDraft(from: result, vehicle: nil)
        #expect(draft.computedGallonsAdded == 0)
    }

    // MARK: - Legitimate zero values remain loggable

    @Test("An explicit zero fuel level (empty tank) still produces a loggable, non-warning draft")
    func explicitZeroFuelLevel_remainsLoggable() {
        let input = BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("18") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("0") ?? .nan, // empty tank, valid
            currentFuelEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            targetEthanolPercent: CalculatorNumericInput.parse("50") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("85") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("91") ?? .nan
        )

        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage == nil)

        let draft = FuelLogStore.prefillDraft(from: result, vehicle: nil)
        #expect(draft.computedGallonsAdded > 0)
    }

    @Test("Explicit E0 gasoline (0% gas ethanol) still produces a loggable, non-warning draft")
    func explicitE0Gasoline_remainsLoggable() {
        let input = BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("18") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("25") ?? .nan,
            currentFuelEthanolPercent: CalculatorNumericInput.parse("0") ?? .nan,
            targetEthanolPercent: CalculatorNumericInput.parse("30") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("85") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("0") ?? .nan, // E0 gasoline, valid
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("87") ?? .nan
        )

        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage == nil)

        let draft = FuelLogStore.prefillDraft(from: result, vehicle: nil)
        #expect(draft.computedGallonsAdded > 0)
    }

    @Test("A normal valid blend calculation remains loggable with matching gallons")
    func normalValidBlend_remainsLoggable() {
        let input = BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("18") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("25") ?? .nan,
            currentFuelEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            targetEthanolPercent: CalculatorNumericInput.parse("85") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("85") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("91") ?? .nan
        )

        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage == nil)

        let draft = FuelLogStore.prefillDraft(from: result, vehicle: nil)
        #expect(abs(draft.computedGallonsAdded - result.totalGallonsToAdd) < 0.001)
        #expect(draft.computedGallonsAdded > 0)
    }

    @Test("A partial fill with parsed string inputs remains loggable")
    func partialFill_remainsLoggable() {
        let input = BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("18") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("25") ?? .nan,
            currentFuelEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            targetEthanolPercent: CalculatorNumericInput.parse("30") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("85") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("91") ?? .nan,
            targetFuelLevelPercent: CalculatorNumericInput.parse("50") ?? .nan
        )

        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage == nil)

        let draft = FuelLogStore.prefillDraft(from: result, vehicle: nil)
        #expect(abs(draft.computedGallonsAdded - 4.5) < 0.01)
    }
}
