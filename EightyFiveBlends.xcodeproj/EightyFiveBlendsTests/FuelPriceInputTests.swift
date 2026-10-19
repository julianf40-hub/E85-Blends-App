//
//  FuelPriceInputTests.swift
//  EightyFiveBlendsTests
//
//  Regression coverage for two Codex findings on PR #133: At The Pump's price/budget
//  fields use .decimalPad, whose digits and decimal key reflect the keyboard's preferred
//  *language*, not the device's region — a U.S.-region iPhone with a non-English
//  preferred language can render "," instead of "." (e.g. Spanish), or localized Arabic-
//  Indic/Extended Arabic-Indic digits with the Arabic decimal separator "٫" instead of
//  ASCII digits and "." (e.g. Arabic or Persian). Double.init?(String) only ever accepts
//  ASCII digits and ".", so any of these parsed as nil and got silently discarded,
//  reproducing the exact price-loss bug PR #133 originally fixed, just via different
//  triggers.
//
//  All expected values are USD per U.S. gallon — 85Blends is U.S.-only, and this fix does
//  not add currencies, exchange rates, or non-U.S. units.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct FuelPriceInputTests {

    // MARK: - The reported defect: a comma decimal must not be discarded

    @Test("A normal U.S. dot-decimal price parses correctly")
    func dotDecimal_parses() {
        #expect(FuelPriceInput.parsePositiveAmount("2.49") == 2.49)
    }

    @Test("A comma-decimal price — e.g. from a Spanish-language keyboard on a U.S. iPhone — parses to the same value a dot would")
    func commaDecimal_parsesSameAsDotDecimal() {
        #expect(FuelPriceInput.parsePositiveAmount("2,49") == 2.49)
        #expect(FuelPriceInput.parsePositiveAmount("2,49") == FuelPriceInput.parsePositiveAmount("2.49"))
    }

    @Test("Three-decimal-place pricing (standard for U.S. gas stations, e.g. $3.499/gal) parses correctly for both separators")
    func threeDecimalPlaces_parsesCorrectly() {
        #expect(FuelPriceInput.parsePositiveAmount("4.199") == 4.199)
        #expect(FuelPriceInput.parsePositiveAmount("4,199") == 4.199)
    }

    // MARK: - Arabic and Persian decimal-pad input must not be discarded either

    @Test("Arabic-Indic digits with the Arabic decimal separator parse to the same value as plain ASCII")
    func arabicIndicDigits_parseSameAsASCII() {
        // "٢٫٤٩" — Arabic-Indic 2, Arabic decimal separator, Arabic-Indic 4, Arabic-Indic 9.
        #expect(FuelPriceInput.parsePositiveAmount("٢٫٤٩") == 2.49)
        #expect(FuelPriceInput.parsePositiveAmount("٢٫٤٩") == FuelPriceInput.parsePositiveAmount("2.49"))
    }

    @Test("Extended Arabic-Indic (Persian) digits with the Arabic decimal separator parse to the same value as plain ASCII")
    func persianDigits_parseSameAsASCII() {
        // "۲٫۴۹" — Extended Arabic-Indic 2, Arabic decimal separator, Extended Arabic-Indic 4, 9.
        #expect(FuelPriceInput.parsePositiveAmount("۲٫۴۹") == 2.49)
        #expect(FuelPriceInput.parsePositiveAmount("۲٫۴۹") == FuelPriceInput.parsePositiveAmount("2.49"))
    }

    @Test("Three-decimal-place pricing in Arabic-Indic and Persian digits parses correctly")
    func threeDecimalPlaces_parsesCorrectlyInLocalizedDigits() {
        #expect(FuelPriceInput.parsePositiveAmount("٤٫١٩٩") == 4.199)
        #expect(FuelPriceInput.parsePositiveAmount("۴٫۱۹۹") == 4.199)
    }

    @Test("The Arabic thousands separator is a grouping character, not a decimal point, and is rejected")
    func arabicThousandsSeparator_isRejected() {
        // U+066C ARABIC THOUSANDS SEPARATOR — a U.S. gas price never needs grouping, so
        // this must not be silently treated as a decimal point.
        #expect(FuelPriceInput.parsePositiveAmount("١\u{066C}٢٣٤") == nil)
    }

    @Test("Roman numerals, vulgar fractions, and superscript digits are never treated as decimal digits")
    func nonDecimalUnicodeNumerals_areRejected() {
        // Character.isNumber is true for all of these — the parser must use an explicit
        // digit allow-list instead, since none of these can come from a decimal pad.
        #expect(FuelPriceInput.parsePositiveAmount("Ⅷ") == nil)       // U+2167 ROMAN NUMERAL EIGHT
        #expect(FuelPriceInput.parsePositiveAmount("2.½") == nil)     // U+00BD VULGAR FRACTION ONE HALF
        #expect(FuelPriceInput.parsePositiveAmount("2.⁴⁹") == nil)    // superscript 4 and 9
    }

    // MARK: - Invalid / malformed / ambiguous input must never fabricate a price

    @Test("Empty input is not a price")
    func emptyInput_isNil() {
        #expect(FuelPriceInput.parsePositiveAmount("") == nil)
        #expect(FuelPriceInput.parsePositiveAmount("   ") == nil)
    }

    @Test("Non-numeric text is not a price")
    func invalidText_isNil() {
        #expect(FuelPriceInput.parsePositiveAmount("abc") == nil)
        #expect(FuelPriceInput.parsePositiveAmount("$2.49") == nil)
        #expect(FuelPriceInput.parsePositiveAmount("2.49/gal") == nil)
    }

    @Test("Negative input is rejected rather than saved as a negative price")
    func negativeInput_isNil() {
        #expect(FuelPriceInput.parsePositiveAmount("-2.49") == nil)
    }

    @Test("An explicit zero is treated as not-entered, matching the app's existing 0-means-no-price-data convention")
    func explicitZero_isNil() {
        #expect(FuelPriceInput.parsePositiveAmount("0") == nil)
        #expect(FuelPriceInput.parsePositiveAmount("0.00") == nil)
        #expect(FuelPriceInput.parsePositiveAmount("0,00") == nil)
    }

    @Test("Input mixing separator conventions — including the Arabic decimal separator — is ambiguous and rejected rather than guessed at")
    func ambiguousSeparators_areNil() {
        #expect(FuelPriceInput.parsePositiveAmount("1,234.56") == nil)
        #expect(FuelPriceInput.parsePositiveAmount("2.49,99") == nil)
        #expect(FuelPriceInput.parsePositiveAmount("2..49") == nil)
        #expect(FuelPriceInput.parsePositiveAmount("2,,49") == nil)
        #expect(FuelPriceInput.parsePositiveAmount("2.49\u{066B}99") == nil)
    }

    @Test("Non-finite or garbage separator-only input is rejected")
    func separatorOnlyInput_isNil() {
        #expect(FuelPriceInput.parsePositiveAmount(".") == nil)
        #expect(FuelPriceInput.parsePositiveAmount(",") == nil)
        #expect(FuelPriceInput.parsePositiveAmount("\u{066B}") == nil)
    }

    // MARK: - Station auto-fill must remain parseable by the same helper

    @Test("A station price formatted the way AtThePumpView auto-fills it (always dot-based) parses correctly")
    func stationAutoFillFormat_parsesCorrectly() {
        let autoFilledText = String(format: "%.2f", 2.19)
        #expect(autoFilledText == "2.19")
        #expect(FuelPriceInput.parsePositiveAmount(autoFilledText) == 2.19)
    }

    // MARK: - Estimated cost and budget calculations must use the same parsing

    @Test("A comma-entered E85 price and a dot-entered gas price produce the same estimated cost as if both were dot-entered")
    func estimatedCost_consistentAcrossSeparators() {
        // Mirrors AtThePumpView.estimatedFuelCost's formula using the shared parser, so a
        // mixed-separator entry (plausible: price fields share one keyboard language, but
        // nothing stops a user from switching keyboards mid-entry) costs out identically.
        let e85Gallons = 6.0
        let gasGallons = 4.0

        let commaResult = (FuelPriceInput.parsePositiveAmount("2,49") ?? 0) * e85Gallons
            + (FuelPriceInput.parsePositiveAmount("4.199") ?? 0) * gasGallons
        let dotResult = (FuelPriceInput.parsePositiveAmount("2.49") ?? 0) * e85Gallons
            + (FuelPriceInput.parsePositiveAmount("4,199") ?? 0) * gasGallons

        #expect(abs(commaResult - dotResult) < 0.0001)
        #expect(abs(commaResult - (2.49 * 6.0 + 4.199 * 4.0)) < 0.0001)
    }

    @Test("A comma-entered budget is parsed the same as a dot-entered budget for the exceeded-budget comparison")
    func budgetComparison_consistentAcrossSeparators() {
        // Mirrors AtThePumpView.budgetExceeded's comparison using the shared parser.
        let estimatedCost = 24.50

        let commaBudget = FuelPriceInput.parsePositiveAmount("20,00")
        let dotBudget = FuelPriceInput.parsePositiveAmount("20.00")

        #expect(commaBudget == dotBudget)
        #expect(commaBudget != nil && estimatedCost > commaBudget!)
    }
}
