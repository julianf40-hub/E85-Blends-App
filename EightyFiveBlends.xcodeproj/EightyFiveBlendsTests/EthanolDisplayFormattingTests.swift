//
//  EthanolDisplayFormattingTests.swift
//  EightyFiveBlendsTests
//
//  2.4.0 Stations readability pass — Double.e85EthanolLabelText (StationsView.swift) is the one
//  formatter that turns a raw community-reported ethanol percentage into the E-notation shown
//  across Stations (the Classic card's ETHANOL column, the Pro map's card, and the out-of-range
//  confirmation's dynamically-interpolated title/message/button — see
//  EthanolRangeConfirmationOverlay.swift and StationsView's own call site building its
//  title/message strings). Widened from `private` to module-visible specifically so this pure
//  formatting logic could get direct test coverage; no formatting behavior changed.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct EthanolDisplayFormattingTests {
    @Test(
        "Whole-number percentages format without a trailing .0",
        arguments: [
            (0.0, "E0"),
            (45.0, "E45"),
            (50.0, "E50"),
            (51.0, "E51"),
            (55.0, "E55"),
            (75.0, "E75"),
            (78.0, "E78"),
            (83.0, "E83"),
            (90.0, "E90"),
            (100.0, "E100"),
        ]
    )
    func e85EthanolLabelText_wholeNumbers(_ pair: (Double, String)) {
        #expect(pair.0.e85EthanolLabelText == pair.1)
    }

    @Test(
        "Genuinely fractional percentages keep one decimal place",
        arguments: [
            (72.5, "E72.5"),
            (75.5, "E75.5"),
            (83.7, "E83.7"),
        ]
    )
    func e85EthanolLabelText_fractionalValues(_ pair: (Double, String)) {
        #expect(pair.0.e85EthanolLabelText == pair.1)
    }

    @Test("Formatting matches CommunityEthanolValidation's own one-decimal-place rounding")
    func e85EthanolLabelText_matchesValidationNormalization() {
        // A value with more precision than the server accepts still displays consistently with
        // how CommunityEthanolValidation.parseValidPercentage would have normalized it on
        // submission — never a display value that looks like it came from unrounded input.
        #expect(75.549.e85EthanolLabelText == "E75.5")
        #expect(83.749.e85EthanolLabelText == "E83.7")
    }
}
