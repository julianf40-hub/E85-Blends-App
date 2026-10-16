//
//  FuelPriceInput.swift
//  EightyFiveBlends
//
//  Shared parsing for text typed into a USD-per-gallon price/budget field on
//  `.decimalPad`. 85Blends is U.S.-only — every value here is USD per U.S. gallon, never
//  a foreign currency or unit — but `.decimalPad`'s decimal key reflects the keyboard's
//  preferred *language*, not the device's region. A U.S.-region iPhone with a preferred
//  language that uses a comma decimal separator (e.g. Spanish, French, German) renders
//  "," where an English keyboard renders ".", so a fully valid "2,49" must mean the same
//  $2.49 that "2.49" means. `Double.init?(String)` only ever accepts ".", so that input
//  was silently parsed as nil and discarded — this is the one shared place that fixes it.
//

import Foundation

enum FuelPriceInput {
    /// Parses a USD amount typed into a price or budget field. Returns `nil` for empty,
    /// non-numeric, negative, non-finite, zero, or ambiguous input (anything with more
    /// than one decimal-separator character) rather than guessing at its meaning — this
    /// matches the app's existing convention that a missing price and an explicit $0.00
    /// are indistinguishable (see FuelLogView's price filtering).
    static func parsePositiveAmount(_ rawText: String) -> Double? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A price typed on .decimalPad can only ever contain digits and the keyboard's one
        // decimal key (which renders as either "." or "," depending on keyboard language) —
        // anything else means this string didn't come from that keyboard as a simple amount.
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }) else {
            return nil
        }

        // Exactly one separator, of either kind, is unambiguous: a U.S. gas price never
        // needs thousands-grouping, so a single "," or "." can only be a decimal point.
        // Two or more (e.g. "1,234.56" or "2.49,99") mixes conventions and is rejected
        // rather than guessed at.
        let separatorCount = trimmed.lazy.filter { $0 == "." || $0 == "," }.count
        guard separatorCount <= 1 else { return nil }

        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")

        guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
        return value
    }
}
