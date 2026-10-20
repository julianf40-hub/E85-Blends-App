//
//  CalculatorNumericInputTests.swift
//  EightyFiveBlendsTests
//
//  Regression coverage for the Calculator's silent-zero-fallback defect: `doubleValue(from:)`
//  used to fall back to 0 for ANY unparseable text, so a blank field or a typo (e.g. "2o"
//  instead of "20") was indistinguishable from a deliberately-entered zero. An empty tank,
//  E0 gasoline, and 0% current ethanol are all legitimate values, so the fix (CalculatorNumericInput)
//  must keep returning those as real zeroes while refusing to guess at blank/invalid text.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct CalculatorNumericInputTests {

    // MARK: - Empty numeric fields must not become zero

    @Test("An empty string is not a valid zero")
    func emptyString_isNil() {
        #expect(CalculatorNumericInput.parse("") == nil)
    }

    @Test("Whitespace-only text is not a valid zero")
    func whitespaceOnly_isNil() {
        #expect(CalculatorNumericInput.parse("   ") == nil)
    }

    // MARK: - Invalid numeric input must not become zero

    @Test("A letter-for-digit typo is rejected, not silently read as zero")
    func typo_isNil() {
        #expect(CalculatorNumericInput.parse("2o") == nil)
    }

    @Test("A bare decimal point (mid-typing) is rejected, not silently read as zero")
    func bareDecimalPoint_isNil() {
        #expect(CalculatorNumericInput.parse(".") == nil)
    }

    @Test("A bare minus sign (mid-typing) is rejected, not silently read as zero")
    func bareMinusSign_isNil() {
        #expect(CalculatorNumericInput.parse("-") == nil)
    }

    @Test("Non-finite text like \"nan\" or \"inf\" is rejected")
    func nonFiniteText_isNil() {
        #expect(CalculatorNumericInput.parse("nan") == nil)
        #expect(CalculatorNumericInput.parse("inf") == nil)
    }

    // MARK: - Legitimate zero values must be preserved

    @Test("An explicit \"0\" parses to a real zero — an empty tank is valid")
    func explicitZero_parsesToZero() {
        #expect(CalculatorNumericInput.parse("0") == 0)
    }

    @Test("An explicit \"0.0\" parses to a real zero — E0 gasoline is valid")
    func explicitZeroDecimal_parsesToZero() {
        #expect(CalculatorNumericInput.parse("0.0") == 0)
    }

    @Test("Surrounding whitespace around a real value is trimmed")
    func surroundingWhitespace_isTrimmed() {
        #expect(CalculatorNumericInput.parse("  20  ") == 20)
    }

    // MARK: - Valid normal values parse exactly

    @Test("A normal integer value parses exactly")
    func normalInteger_parsesExactly() {
        #expect(CalculatorNumericInput.parse("82") == 82)
    }

    @Test("A normal decimal value parses exactly")
    func normalDecimal_parsesExactly() {
        #expect(CalculatorNumericInput.parse("15.5") == 15.5)
    }

    // MARK: - Existing Calculator defaults still parse as expected (regression for defaults wiring)

    @Test("Calculator's known default field strings all parse to their expected values")
    func calculatorDefaults_parseAsExpected() {
        #expect(CalculatorNumericInput.parse("15.5") == 15.5) // tankSize
        #expect(CalculatorNumericInput.parse("25") == 25)     // currentLevel
        #expect(CalculatorNumericInput.parse("20") == 20)     // currentFuelEthanol
        #expect(CalculatorNumericInput.parse("50") == 50)     // targetFuelEthanol
        #expect(CalculatorNumericInput.parse("82") == 82)     // e85Ethanol
        #expect(CalculatorNumericInput.parse("105") == 105)   // e85Octane
        #expect(CalculatorNumericInput.parse("10") == 10)     // gasEthanol
        #expect(CalculatorNumericInput.parse("91") == 91)     // gasOctane
    }

    // MARK: - Integration: feeding parsed values into BlendCalculator mirrors the real fix

    @Test("Blank input routed as NaN produces a validation warning, not a misleading blend")
    func blankInput_throughBlendCalculator_producesWarning() {
        let input = BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("15.5") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("") ?? .nan, // user cleared the field
            currentFuelEthanolPercent: CalculatorNumericInput.parse("20") ?? .nan,
            targetEthanolPercent: CalculatorNumericInput.parse("50") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("82") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("91") ?? .nan
        )

        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage == "Enter valid numeric values before calculating a blend.")
        #expect(result.totalGallonsToAdd == 0)
    }

    @Test("A typo routed as NaN produces a validation warning, not a misleading blend")
    func invalidInput_throughBlendCalculator_producesWarning() {
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
        #expect(result.warningMessage == "Enter valid numeric values before calculating a blend.")
    }

    @Test("Explicit zero fuel level (empty tank) still produces a valid, non-warning fill calculation")
    func explicitZeroFuelLevel_stillCalculatesNormally() {
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
        #expect(abs(result.totalGallonsToAdd - 18.0) < 0.01)
    }

    @Test("Explicit E0 gasoline (0% gas ethanol) still produces a valid, non-warning blend calculation")
    func explicitE0Gasoline_stillCalculatesNormally() {
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
        #expect(result.totalGallonsToAdd > 0)
    }

    @Test("A normal E85-target blend calculation with parsed string inputs matches the direct-double result")
    func e85BlendCalculation_withParsedStrings_matchesDirectDoubles() {
        let parsedInput = BlendCalculator.Input(
            tankSizeGallons: CalculatorNumericInput.parse("18") ?? .nan,
            currentFuelLevelPercent: CalculatorNumericInput.parse("25") ?? .nan,
            currentFuelEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            targetEthanolPercent: CalculatorNumericInput.parse("85") ?? .nan,
            e85EthanolPercent: CalculatorNumericInput.parse("85") ?? .nan,
            gasEthanolPercent: CalculatorNumericInput.parse("10") ?? .nan,
            e85Octane: CalculatorNumericInput.parse("105") ?? .nan,
            gasOctane: CalculatorNumericInput.parse("91") ?? .nan
        )
        let directInput = BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 85,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        )

        let parsedResult = BlendCalculator.calculate(input: parsedInput)
        let directResult = BlendCalculator.calculate(input: directInput)
        #expect(parsedResult.warningMessage == nil)
        #expect(parsedResult.totalGallonsToAdd == directResult.totalGallonsToAdd)
        #expect(parsedResult.finalEthanolPercent == directResult.finalEthanolPercent)
    }

    @Test("A partial fill with parsed string inputs still resolves correctly")
    func partialFill_withParsedStrings_resolvesCorrectly() {
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
        #expect(abs(result.totalGallonsToAdd - 4.5) < 0.01)
    }
}
