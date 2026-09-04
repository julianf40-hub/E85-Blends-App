//
//  CommunityPriceValidationTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rule behind Community E85 Price Reporting's client-side price
//  bound (CommunityPriceValidation.parseValidPrice) — the actual function StationsView.
//  savePriceUpdate calls, not a duplicate reimplementation — so passing tests here directly
//  verify production behavior.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  2.3.2 public-release-readiness fix context: see CommunityPriceValidation.swift's own header
//  for why `parsedPrice > 0` (the previous rule) was insufficient — it accepted $999, $0.50, and
//  even the literal strings "nan"/"inf"/"infinity" (which Swift's Double.init?(String) parses
//  successfully). The bound below (`$1.00...$8.00`) matches production Supabase's live
//  `e85_price_reports.price` CHECK constraint and RLS WITH CHECK exactly.
//

import Testing
@testable import EightyFiveBlends

struct CommunityPriceValidationTests {

    // MARK: In-range prices are accepted

    @Test("A typical in-range price is accepted and parsed exactly")
    func parseValidPrice_typicalPrice_isAccepted() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "2.99") == 2.99)
    }

    @Test("The exact lower bound ($1.00) is accepted — the bound is inclusive")
    func parseValidPrice_exactLowerBound_isAccepted() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "1.00") == 1.00)
    }

    @Test("The exact upper bound ($8.00) is accepted — the bound is inclusive")
    func parseValidPrice_exactUpperBound_isAccepted() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "8.00") == 8.00)
    }

    @Test("Surrounding whitespace is trimmed before parsing")
    func parseValidPrice_surroundingWhitespace_isTrimmedAndAccepted() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "  3.49\n") == 3.49)
    }

    // MARK: Out-of-range prices are rejected

    @Test("A price just below the lower bound ($0.99) is rejected")
    func parseValidPrice_justBelowLowerBound_isRejected() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "0.99") == nil)
    }

    @Test("A price just above the upper bound ($8.01) is rejected")
    func parseValidPrice_justAboveUpperBound_isRejected() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "8.01") == nil)
    }

    @Test("An absurdly low price ($0.50) is rejected — the exact audit example")
    func parseValidPrice_absurdlyLow_isRejected() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "0.50") == nil)
    }

    @Test("An absurdly high price ($999) is rejected — the exact audit example")
    func parseValidPrice_absurdlyHigh_isRejected() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "999") == nil)
    }

    @Test("Zero and negative prices are rejected")
    func parseValidPrice_zeroOrNegative_isRejected() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "0") == nil)
        #expect(CommunityPriceValidation.parseValidPrice(from: "-5") == nil)
    }

    // MARK: Non-finite input is rejected (the audit's sharpest finding)

    @Test("The literal string \"nan\" — which Double.init?(String) parses successfully — is rejected, not treated as a valid price")
    func parseValidPrice_nanLiteral_isRejected() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "nan") == nil)
        #expect(CommunityPriceValidation.parseValidPrice(from: "NaN") == nil)
    }

    @Test("The literal strings \"inf\"/\"infinity\" — which Double.init?(String) parses successfully — are rejected, not treated as a valid price")
    func parseValidPrice_infinityLiteral_isRejected() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "inf") == nil)
        #expect(CommunityPriceValidation.parseValidPrice(from: "infinity") == nil)
        #expect(CommunityPriceValidation.parseValidPrice(from: "-infinity") == nil)
    }

    // MARK: Blank and malformed input is rejected

    @Test("Blank or whitespace-only input is rejected")
    func parseValidPrice_blankInput_isRejected() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "") == nil)
        #expect(CommunityPriceValidation.parseValidPrice(from: "   ") == nil)
    }

    @Test("Non-numeric input is rejected")
    func parseValidPrice_malformedInput_isRejected() {
        #expect(CommunityPriceValidation.parseValidPrice(from: "free") == nil)
        #expect(CommunityPriceValidation.parseValidPrice(from: "$2.99") == nil)
        #expect(CommunityPriceValidation.parseValidPrice(from: "2.99.9") == nil)
    }

    // MARK: The published constants match the production server bound

    @Test("minimumValidPrice and maximumValidPrice match production Supabase's live e85_price_reports.price CHECK constraint ($1.00...$8.00) — see docs/PRE_RELEASE_SUPABASE_CHECKLIST.md")
    func bounds_matchProductionServerConstraint() {
        #expect(CommunityPriceValidation.minimumValidPrice == 1.00)
        #expect(CommunityPriceValidation.maximumValidPrice == 8.00)
    }
}
