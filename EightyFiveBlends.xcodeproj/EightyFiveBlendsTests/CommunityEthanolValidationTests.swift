//
//  CommunityEthanolValidationTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rules behind Community Ethanol % Reporting's client-side bounds
//  (CommunityEthanolValidation.parseValidPercentage / .requiresConfirmation) — the actual
//  functions StationsView's ethanol-reporting flow will call, not a duplicate reimplementation,
//  so passing tests here directly verify production behavior.
//
//  Mirrors CommunityPriceValidationTests.swift's structure. See CommunityEthanolValidation.swift's
//  own header for why hard validity (0...100) and expected-range classification (51...83,
//  confirmation-only, never rejecting) are two deliberately separate concerns tested independently
//  below.
//

import Testing
@testable import EightyFiveBlends

struct CommunityEthanolValidationTests {

    // MARK: The full 0...100 bound is accepted, inclusive

    @Test("The exact lower bound (0) is accepted — the bound is inclusive")
    func parseValidPercentage_exactLowerBound_isAccepted() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "0") == 0)
    }

    @Test("The exact upper bound (100) is accepted — the bound is inclusive")
    func parseValidPercentage_exactUpperBound_isAccepted() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "100") == 100)
    }

    @Test("A typical in-range percentage is accepted and parsed exactly")
    func parseValidPercentage_typicalPercentage_isAccepted() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "78.5") == 78.5)
    }

    @Test("Surrounding whitespace is trimmed before parsing")
    func parseValidPercentage_surroundingWhitespace_isTrimmedAndAccepted() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "  78.5\n") == 78.5)
    }

    // MARK: Out-of-range values are rejected

    @Test("A value just below the lower bound (-0.1) is rejected")
    func parseValidPercentage_justBelowLowerBound_isRejected() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "-0.1") == nil)
    }

    @Test("A value just above the upper bound (100.1) is rejected")
    func parseValidPercentage_justAboveUpperBound_isRejected() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "100.1") == nil)
    }

    // MARK: Non-finite input is rejected

    @Test("The literal string \"nan\" — which Double.init?(String) parses successfully — is rejected, not treated as a valid percentage")
    func parseValidPercentage_nanLiteral_isRejected() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "nan") == nil)
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "NaN") == nil)
    }

    @Test("The literal strings \"inf\"/\"infinity\" — which Double.init?(String) parses successfully — are rejected, not treated as a valid percentage")
    func parseValidPercentage_infinityLiteral_isRejected() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "inf") == nil)
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "infinity") == nil)
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "-infinity") == nil)
    }

    // MARK: Blank and malformed input is rejected

    @Test("Blank input is rejected")
    func parseValidPercentage_blankInput_isRejected() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "") == nil)
    }

    @Test("Whitespace-only input is rejected")
    func parseValidPercentage_whitespaceOnlyInput_isRejected() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "   ") == nil)
    }

    @Test("Non-numeric input is rejected")
    func parseValidPercentage_malformedInput_isRejected() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "free") == nil)
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "83%") == nil)
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "78.5.9") == nil)
    }

    // MARK: Decimal precision is preserved, never collapsed to a whole percentage

    @Test("A value already at one decimal place is preserved exactly")
    func parseValidPercentage_oneDecimalPlace_isPreservedExactly() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "83.7") == 83.7)
    }

    @Test("A value with more than one decimal place is normalized to one decimal, not rounded to a whole percentage")
    func parseValidPercentage_extraPrecision_isNormalizedToOneDecimal() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "78.53") == 78.5)
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "78.53") != 79)
    }

    @Test("Rounding boundary just below the half step rounds down")
    func parseValidPercentage_justBelowRoundingHalfStep_roundsDown() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "67.44") == 67.4)
    }

    @Test("Rounding boundary just above the half step rounds up")
    func parseValidPercentage_justAboveRoundingHalfStep_roundsUp() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "67.46") == 67.5)
    }

    // MARK: Expected E85 range classification (51...83) — confirmation, never rejection

    @Test("51 and 83 are within the expected range and never require confirmation")
    func requiresConfirmation_expectedRangeBounds_isFalse() {
        #expect(CommunityEthanolValidation.requiresConfirmation(forPercentage: 51) == false)
        #expect(CommunityEthanolValidation.requiresConfirmation(forPercentage: 83) == false)
    }

    @Test("An ordinary in-range value does not require confirmation")
    func requiresConfirmation_ordinaryInRangeValue_isFalse() {
        #expect(CommunityEthanolValidation.requiresConfirmation(forPercentage: 70) == false)
    }

    @Test("50.9 and 83.1 are valid percentages but fall just outside the expected range, requiring confirmation")
    func requiresConfirmation_justOutsideExpectedRange_isTrue() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "50.9") == 50.9)
        #expect(CommunityEthanolValidation.requiresConfirmation(forPercentage: 50.9) == true)

        #expect(CommunityEthanolValidation.parseValidPercentage(from: "83.1") == 83.1)
        #expect(CommunityEthanolValidation.requiresConfirmation(forPercentage: 83.1) == true)
    }

    @Test("0 and 100 are valid percentages but fall far outside the expected range, requiring confirmation")
    func requiresConfirmation_hardBounds_isTrue() {
        #expect(CommunityEthanolValidation.parseValidPercentage(from: "0") == 0)
        #expect(CommunityEthanolValidation.requiresConfirmation(forPercentage: 0) == true)

        #expect(CommunityEthanolValidation.parseValidPercentage(from: "100") == 100)
        #expect(CommunityEthanolValidation.requiresConfirmation(forPercentage: 100) == true)
    }

    // MARK: The published constants match the product contract

    @Test("minimumValidPercentage and maximumValidPercentage span the full 0...100 physical range")
    func bounds_matchFullPhysicalRange() {
        #expect(CommunityEthanolValidation.minimumValidPercentage == 0)
        #expect(CommunityEthanolValidation.maximumValidPercentage == 100)
    }

    @Test("expectedRangeLowerBound and expectedRangeUpperBound match the documented E85 expected range (51...83)")
    func bounds_matchExpectedE85Range() {
        #expect(CommunityEthanolValidation.expectedRangeLowerBound == 51)
        #expect(CommunityEthanolValidation.expectedRangeUpperBound == 83)
    }
}
