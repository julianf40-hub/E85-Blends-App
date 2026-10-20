//
//  CalculatorResultPresentationTests.swift
//  EightyFiveBlendsTests
//
//  Regression coverage for the Codex P2 finding on PR #136: BlendResultCard and
//  PumpInstructionsSection used to render a warning result's zero gallons and blend label
//  as if they were a real recommendation. CalculatorResultPresentation.displayValue(_:for:)
//  is the exact function both views call to decide what string to show for every value —
//  these tests verify that decision directly (not just that BlendCalculator reports zero
//  gallons for a warning result), which is as close to "the actual presentation decision"
//  as a unit test can get without a SwiftUI snapshot/rendering harness. They do not verify
//  that BlendResultCard or PumpInstructionsSection actually render this string in the
//  simulator — that still requires a visual check.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct CalculatorResultPresentationTests {

    private func validResult() -> BlendCalculator.Result {
        BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 50,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        ))
    }

    private func blankFieldWarningResult() -> BlendCalculator.Result {
        BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("15.5") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("") ?? .nan,
            currentFuelEthanolPercent: CalculatorNumericInput.parse("20") ?? .nan,
            targetEthanolPercent: CalculatorNumericInput.parse("50") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("82") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("91") ?? .nan
        ))
    }

    private func outOfRangeWarningResult() -> BlendCalculator.Result {
        BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: 15,
            currentFuelLevelPercent: 150, // out of range
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 50,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        ))
    }

    private func alreadyFullTankWarningResult() -> BlendCalculator.Result {
        // Tank already full at the target blend's own percent — triggers the "already full"
        // warning path rather than the NaN/invalid-input path.
        BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 100,
            currentFuelEthanolPercent: 50,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        ))
    }

    private func unreachableBlendWarningResult() -> BlendCalculator.Result {
        // Target far above what the pump fuel can achieve, with no room to special-case it
        // as "pump E85 only" guidance.
        BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 90,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 85,
            e85EthanolPercent: 70,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        ))
    }

    private func e85OnlyGuidanceResult() -> BlendCalculator.Result {
        BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 10,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 85,
            e85EthanolPercent: 82,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        ))
    }

    // MARK: - The presentation decision itself

    @Test("A valid result is never neutralized")
    func validResult_isNotNeutralized() {
        #expect(CalculatorResultPresentation.isNeutralized(for: validResult()) == false)
        #expect(CalculatorResultPresentation.displayValue("4.50", for: validResult()) == "4.50")
    }

    @Test("A blank-field (invalid input) warning result is neutralized")
    func blankFieldWarning_isNeutralized() {
        let result = blankFieldWarningResult()
        #expect(result.warningMessage != nil)
        #expect(CalculatorResultPresentation.isNeutralized(for: result))
        #expect(CalculatorResultPresentation.displayValue("0.00", for: result) == CalculatorResultPresentation.neutralizedValue)
    }

    @Test("An out-of-range value warning result is neutralized")
    func outOfRangeWarning_isNeutralized() {
        let result = outOfRangeWarningResult()
        #expect(result.warningMessage != nil)
        #expect(CalculatorResultPresentation.isNeutralized(for: result))
    }

    @Test("An already-full-tank warning result is neutralized")
    func alreadyFullTankWarning_isNeutralized() {
        let result = alreadyFullTankWarningResult()
        #expect(result.warningMessage != nil)
        #expect(CalculatorResultPresentation.isNeutralized(for: result))
    }

    @Test("An unreachable-blend warning result is neutralized")
    func unreachableBlendWarning_isNeutralized() {
        let result = unreachableBlendWarningResult()
        #expect(result.warningMessage != nil)
        #expect(CalculatorResultPresentation.isNeutralized(for: result))
    }

    @Test("Valid E85-only guidance is never neutralized")
    func e85OnlyGuidance_isNotNeutralized() {
        let result = e85OnlyGuidanceResult()
        #expect(result.warningMessage == nil)
        #expect(result.guidanceMessage != nil)
        #expect(CalculatorResultPresentation.isNeutralized(for: result) == false)
    }

    // MARK: - The exact compound strings PumpInstructionsSection assembles

    @Test("PumpInstructionsSection's Step 3 string is fully neutralized for a warning result")
    func step3String_isNeutralized_forWarningResult() {
        let result = blankFieldWarningResult()
        let step3 = "\(CalculatorResultPresentation.displayValue(result.blendLabel, for: result)) at roughly \(CalculatorResultPresentation.displayValue(String(format: "%.1f", result.estimatedOctane), for: result)) octane with \(CalculatorResultPresentation.displayValue(String(format: "%.2f", result.totalGallonsToAdd), for: result)) gallons added."
        #expect(step3 == "— at roughly — octane with — gallons added.")
    }

    @Test("PumpInstructionsSection's Step 3 string shows real values for a valid result")
    func step3String_showsRealValues_forValidResult() {
        let result = validResult()
        let step3 = "\(CalculatorResultPresentation.displayValue(result.blendLabel, for: result)) at roughly \(CalculatorResultPresentation.displayValue(String(format: "%.1f", result.estimatedOctane), for: result)) octane with \(CalculatorResultPresentation.displayValue(String(format: "%.2f", result.totalGallonsToAdd), for: result)) gallons added."
        #expect(step3.contains("—") == false)
        #expect(step3 == "\(result.blendLabel) at roughly \(String(format: "%.1f", result.estimatedOctane)) octane with \(String(format: "%.2f", result.totalGallonsToAdd)) gallons added.")
    }

    // MARK: - Legitimate zero values are presented as real results, not neutralized

    @Test("An explicit zero fuel level (empty tank) presents real values, not neutralized")
    func explicitZeroFuelLevel_presentsRealValues() {
        let result = BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("18") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("0") ?? .nan,
            currentFuelEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            targetEthanolPercent: CalculatorNumericInput.parse("50") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("85") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("91") ?? .nan
        ))
        #expect(result.warningMessage == nil)
        #expect(CalculatorResultPresentation.isNeutralized(for: result) == false)
        #expect(CalculatorResultPresentation.displayValue(String(format: "%.2f", result.totalGallonsToAdd), for: result) != CalculatorResultPresentation.neutralizedValue)
    }

    @Test("Explicit E0 gasoline presents real values, not neutralized")
    func explicitE0Gasoline_presentsRealValues() {
        let result = BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("18") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("25") ?? .nan,
            currentFuelEthanolPercent: CalculatorNumericInput.parse("0") ?? .nan,
            targetEthanolPercent: CalculatorNumericInput.parse("30") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("85") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("0") ?? .nan,
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("87") ?? .nan
        ))
        #expect(result.warningMessage == nil)
        #expect(CalculatorResultPresentation.isNeutralized(for: result) == false)
    }

    @Test("A partial fill presents real values, not neutralized")
    func partialFill_presentsRealValues() {
        let result = BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91,
            targetFuelLevelPercent: 50
        ))
        #expect(result.warningMessage == nil)
        #expect(CalculatorResultPresentation.isNeutralized(for: result) == false)
    }

    // MARK: - Fill-up logging protection still holds alongside the presentation fix

    @Test("A neutralized (warning) result still produces a zero-gallon, unloggable draft")
    func neutralizedResult_stillUnloggable() {
        let result = blankFieldWarningResult()
        let draft = FuelLogStore.prefillDraft(from: result, vehicle: nil)
        #expect(CalculatorResultPresentation.isNeutralized(for: result))
        #expect(draft.computedGallonsAdded == 0)
    }
}
