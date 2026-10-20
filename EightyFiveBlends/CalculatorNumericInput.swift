//
//  CalculatorNumericInput.swift
//  EightyFiveBlends
//
//  Parsing for the Calculator's numeric text fields (tank size, fuel level, ethanol
//  percentages, octane). An empty tank, E0 gasoline, and a 0% current ethanol reading are
//  all legitimate values a user can type — but a blank field or a typo (e.g. "2o" instead
//  of "20") is not the same thing as a deliberate zero. Returning nil for the former and
//  the exact parsed value (including zero) for the latter lets callers tell "nothing valid
//  entered yet" apart from "the user really means zero," instead of collapsing both into 0.
//

import Foundation

enum CalculatorNumericInput {
    static func parse(_ rawText: String) -> Double? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}
