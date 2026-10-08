//
//  PriceAlertsPriceInput.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B). Turns what a person typed into the "At or Below" price
//  field into a `PriceAlertAmount`, and a `PriceAlertAmount` back into text. Pure Foundation.
//
//  WHY THIS IS NOT `Double(text)`. The backend stores a threshold as `numeric(6,3)`, and Phase 3A
//  carries money as whole thousandths of a dollar so that 3.499 stays exactly 3499. Parsing the field
//  through a Double would reintroduce the binary-floating-point drift that type exists to avoid, and
//  `Double("nan")` / `Double("1e3")` are accepted by Swift, which a price field must not.
//
//  THE RULES (each one has a test)
//    - Dollars per gallon, digits and ONE decimal mark. A leading "$" is tolerated (a paste); a comma
//      is read as the decimal mark (a decimal pad in a comma locale types it), never as a thousands
//      separator — no fuel price has one, so "1,234" is $1.234, and "1,234.5" is refused.
//    - At most THREE decimal places. A fourth is refused, never rounded away: the number a person sees
//      in the field is the number that is saved or rejected, never a quietly different one.
//    - No sign, exponent, spaces inside, letters, or non-ASCII digits. A leading minus gets its own
//      message because it is the one mistake that deserves a specific answer.
//    - Within the backend's own bounds, 1.000 through 8.000 inclusive (`PriceAlertRule.thresholdRange`,
//      the same bound `set_alert` and the database enforce). The bounds are read from that constant,
//      so this file and the server cannot drift apart.
//    - The empty field is neither valid nor an error: it is "not entered yet".
//
//  The same parser reads the "Custom" drop size of a Price Drop alert (Phase 3C), with that field's own
//  bounds (`PriceAlertPreferences.minimumChangeRange`) — see PriceAlertMinimumChangeInput.
//

import Foundation

nonisolated enum PriceAlertPriceInput {
    enum Problem: Equatable, Sendable {
        /// Not a plain decimal number (letters, symbols, two decimal marks, no digits…).
        case notANumber
        case negative
        /// A fourth fractional digit.
        case tooManyDecimals
        case belowMinimum
        case aboveMaximum
    }

    enum Result: Equatable, Sendable {
        /// Nothing entered yet (or only whitespace).
        case empty
        case valid(PriceAlertAmount)
        case invalid(Problem)
    }

    /// Whole-dollar digits beyond this are certainly above the maximum; stopping here keeps the
    /// integer arithmetic below far from overflow whatever is pasted.
    private static let maximumWholeDigits = 9

    static func parse(_ rawText: String) -> Result {
        parse(rawText, within: PriceAlertRule.thresholdRange)
    }

    /// The same rules with caller-supplied inclusive bounds (still integer thousandths).
    static func parse(_ rawText: String, within bounds: ClosedRange<PriceAlertAmount>) -> Result {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return .empty
        }
        if text.hasPrefix("-") || text.hasPrefix("\u{2212}") {
            return .invalid(.negative)
        }
        if text.hasPrefix("$") {
            text.removeFirst()
        }

        var whole = 0
        var wholeDigits = 0
        var fraction = 0
        var fractionDigits = 0
        var sawMark = false

        for scalar in text.unicodeScalars {
            if scalar == "." || scalar == "," {
                if sawMark { return .invalid(.notANumber) }
                sawMark = true
                continue
            }
            guard scalar.value >= 0x30, scalar.value <= 0x39 else {
                return .invalid(.notANumber)
            }
            let digit = Int(scalar.value - 0x30)
            if sawMark {
                fractionDigits += 1
                if fractionDigits > 3 { return .invalid(.tooManyDecimals) }
                fraction = fraction * 10 + digit
            } else {
                wholeDigits += 1
                if wholeDigits > maximumWholeDigits { return .invalid(.aboveMaximum) }
                whole = whole * 10 + digit
            }
        }
        guard wholeDigits + fractionDigits > 0 else {
            return .invalid(.notANumber)
        }
        while fractionDigits < 3 {
            fraction *= 10
            fractionDigits += 1
        }

        let amount = PriceAlertAmount(thousandths: whole * 1000 + fraction)
        if amount < bounds.lowerBound {
            return .invalid(.belowMinimum)
        }
        if amount > bounds.upperBound {
            return .invalid(.aboveMaximum)
        }
        return .valid(amount)
    }

    // MARK: - Text

    /// The digits of an amount as a person would type them: two decimals, a third only when it
    /// matters — `3.25`, `3.499`, never `3.250` and never a rounded `3.50` for 3.499.
    static func editableText(for amount: PriceAlertAmount) -> String {
        let thousandths = max(amount.thousandths, 0)
        let whole = thousandths / 1000
        let fraction = thousandths % 1000
        let hundredths = fraction / 10
        let hundredthsText = hundredths < 10 ? "0\(hundredths)" : "\(hundredths)"
        let remainder = fraction % 10
        return remainder == 0 ? "\(whole).\(hundredthsText)" : "\(whole).\(hundredthsText)\(remainder)"
    }

    /// `$3.25`, `$3.499`.
    static func displayText(for amount: PriceAlertAmount) -> String {
        "$" + editableText(for: amount)
    }

    // MARK: - Messages

    /// "$1.00" and "$8.00", from the shared bound.
    static var allowedRangeText: String {
        "\(displayText(for: PriceAlertRule.thresholdRange.lowerBound)) and \(displayText(for: PriceAlertRule.thresholdRange.upperBound))"
    }

    /// Shown under an empty field. Guidance, not an error.
    static var emptyHint: String {
        "Enter the price per gallon you're waiting for, between \(allowedRangeText)."
    }

    static func message(for problem: Problem) -> String {
        switch problem {
        case .notANumber:
            return "Enter a price using numbers, like 3.49."
        case .negative:
            return "The price can't be negative."
        case .tooManyDecimals:
            return "Use at most 3 decimal places, like 3.499."
        case .belowMinimum, .aboveMaximum:
            return "Enter a price between \(allowedRangeText)."
        }
    }
}
