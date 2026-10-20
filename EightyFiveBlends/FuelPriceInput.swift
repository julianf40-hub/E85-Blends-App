//
//  FuelPriceInput.swift
//  EightyFiveBlends
//
//  Shared parsing for text typed into a USD-per-gallon price/budget field on
//  `.decimalPad`. 85Blends is U.S.-only — every value here is USD per U.S. gallon, never
//  a foreign currency or unit — but `.decimalPad`'s digits and decimal key reflect the
//  keyboard's preferred *language*, not the device's region. A U.S.-region iPhone with a
//  preferred language that uses a comma decimal separator (e.g. Spanish, French, German)
//  renders "," where an English keyboard renders ".", and a preferred language of Arabic
//  or Persian renders localized digits (e.g. "٢٫٤٩" or "۲٫۴۹") with the Arabic decimal
//  separator "٫" instead of plain ASCII — all of these must mean the same $2.49 that
//  "2.49" means. `Double.init?(String)` only ever accepts ASCII digits and ".", so that
//  input was silently parsed as nil and discarded — this is the one shared place that
//  fixes it for every keyboard language this app's U.S. users might have set.
//

import Foundation

enum FuelPriceInput {
    /// Decimal digit characters `.decimalPad` can render, mapped to their ASCII value —
    /// Western Arabic numerals plus the two digit sets iOS uses for Arabic and Persian
    /// keyboard languages. Deliberately an explicit allow-list rather than
    /// `Character.isNumber`, which is also true for Roman numerals, vulgar fractions, and
    /// superscript/subscript digits — none of those can come from a decimal pad, so
    /// treating them as digits would silently misparse the price.
    private static let digitValues: [Character: Character] = {
        let ascii = Array("0123456789")
        let arabicIndic = Array("٠١٢٣٤٥٦٧٨٩")
        let extendedArabicIndic = Array("۰۱۲۳۴۵۶۷۸۹")
        var map: [Character: Character] = [:]
        for index in ascii.indices {
            map[ascii[index]] = ascii[index]
            map[arabicIndic[index]] = ascii[index]
            map[extendedArabicIndic[index]] = ascii[index]
        }
        return map
    }()

    /// Decimal-point characters `.decimalPad` can render as its one decimal key. Does NOT
    /// include "٬" (Arabic thousands separator, U+066C) — a U.S. gas price never needs
    /// thousands-grouping, so that character is rejected rather than treated as a digit
    /// group boundary.
    private static let decimalSeparators: Set<Character> = [".", ",", "\u{066B}"]

    /// Parses a USD amount typed into a price or budget field. Returns `nil` for empty,
    /// non-numeric, negative, non-finite, zero, or ambiguous input (anything with more
    /// than one decimal-separator character, or any character outside the recognized
    /// digit/separator set) rather than guessing at its meaning — this matches the app's
    /// existing convention that a missing price and an explicit $0.00 are indistinguishable
    /// (see FuelLogView's price filtering).
    static func parsePositiveAmount(_ rawText: String) -> Double? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = ""
        normalized.reserveCapacity(trimmed.count)
        var separatorCount = 0

        for character in trimmed {
            if let digit = digitValues[character] {
                normalized.append(digit)
            } else if decimalSeparators.contains(character) {
                separatorCount += 1
                normalized.append(".")
            } else {
                // Anything else — a minus sign, letters, a thousands separator, a Roman
                // numeral, a fraction, a superscript — means this didn't come from the
                // keyboard as a plain amount, so don't guess at its meaning.
                return nil
            }
        }

        // Exactly one separator, of any recognized kind, is unambiguous: a U.S. gas price
        // never needs thousands-grouping, so a single separator can only be a decimal
        // point. Two or more (e.g. "1,234.56" or "2.49,99") mixes conventions and is
        // rejected rather than guessed at.
        guard separatorCount <= 1 else { return nil }

        guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
        return value
    }
}
