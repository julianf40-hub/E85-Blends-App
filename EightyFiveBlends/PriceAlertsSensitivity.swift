//
//  PriceAlertsSensitivity.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 (Phase 3C) — how big a drop a Price Drop alert waits for. Pure Foundation.
//
//  THE CHOICES. 5¢, 10¢ (Recommended), 20¢, or Custom (0.01 through 2.00 dollars). They are cents-per-gallon
//  drops, not percentages: the backend stores `minimum_change` as a dollar amount, and a percentage of a
//  $3 price is not something anyone watching a pump sign thinks in.
//
//  WHAT EACH ONE MEANS. "Notify me when this station's price for the payment type I chose has fallen by at
//  least this much" — measured from the last comparable price the alert has seen (see
//  docs/PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md), so two 6¢ drops in a row add up to a 12¢ drop for a 10¢ alert.
//
//  THE DEFAULT. A NEW alert starts at 10¢ (`PriceAlertPreferences.newAlertDefaults`). An alert that already
//  exists keeps whatever it holds — including the 5¢ every alert made before this version has — and the form
//  shows it as the matching choice. Nothing rewrites an existing alert to 10¢.
//
//  MONEY IS THOUSANDTHS. Presets are 50, 100 and 200 thousandths of a dollar; a custom amount is parsed from
//  text into whole thousandths and never passes through a Double.
//

import Foundation

// MARK: - Choice

nonisolated enum PriceAlertSensitivity: String, CaseIterable, Identifiable, Hashable, Sendable {
    case fiveCents
    case tenCents
    case twentyCents
    case custom

    var id: String { rawValue }

    /// The choice the product recommends, and the one a new alert starts on.
    static let recommended: PriceAlertSensitivity = .tenCents

    /// The drop a preset stands for. `nil` for Custom, whose amount is typed.
    var presetAmount: PriceAlertAmount? {
        switch self {
        case .fiveCents: return PriceAlertAmount(thousandths: 50)
        case .tenCents: return PriceAlertAmount(thousandths: 100)
        case .twentyCents: return PriceAlertAmount(thousandths: 200)
        case .custom: return nil
        }
    }

    var isRecommended: Bool {
        self == .recommended
    }

    /// "5¢", "10¢", "20¢", "Custom".
    var title: String {
        switch self {
        case .fiveCents, .tenCents, .twentyCents:
            return presetAmount.map { PriceAlertSensitivity.displayText(for: $0) } ?? ""
        case .custom:
            return "Custom"
        }
    }

    /// The second line on the button: "Recommended" for 10¢, nothing for the others.
    var detail: String? {
        isRecommended ? "Recommended" : nil
    }

    /// For VoiceOver: "10 cents, recommended", "Custom amount".
    var spokenTitle: String {
        switch self {
        case .fiveCents, .tenCents, .twentyCents:
            let amount = presetAmount.map { PriceAlertSensitivity.spokenText(for: $0) } ?? ""
            return isRecommended ? "\(amount), recommended" : amount
        case .custom:
            return "Custom amount"
        }
    }

    /// The choice whose preset is exactly `amount`; Custom for anything else. This is how a form is seeded
    /// from an alert that already exists: a legacy 5¢ alert reads as the 5¢ choice, an odd amount as Custom.
    init(matching amount: PriceAlertAmount) {
        if let preset = Self.allCases.first(where: { $0.presetAmount == amount }) {
            self = preset
        } else {
            self = .custom
        }
    }

    // MARK: Text

    /// "10¢" for a whole number of cents below a dollar, otherwise dollars: "$1.25", "$0.015".
    static func displayText(for amount: PriceAlertAmount) -> String {
        if amount.thousandths > 0, amount.thousandths < 1_000, amount.thousandths % 10 == 0 {
            return "\(amount.thousandths / 10)¢"
        }
        return PriceAlertPriceInput.displayText(for: amount)
    }

    /// "10 cents", "1 cent", "$1.25".
    static func spokenText(for amount: PriceAlertAmount) -> String {
        if amount.thousandths > 0, amount.thousandths < 1_000, amount.thousandths % 10 == 0 {
            let cents = amount.thousandths / 10
            return cents == 1 ? "1 cent" : "\(cents) cents"
        }
        return PriceAlertPriceInput.displayText(for: amount)
    }
}

// MARK: - Custom amount

/// Reads the "Custom" drop size a person types: dollars per gallon, 0.01 through 2.00, up to three decimals,
/// by the same rules as the target price (PriceAlertPriceInput) with this field's own bounds and words.
nonisolated enum PriceAlertMinimumChangeInput {
    typealias Problem = PriceAlertPriceInput.Problem
    typealias Result = PriceAlertPriceInput.Result

    static func parse(_ rawText: String) -> Result {
        PriceAlertPriceInput.parse(rawText, within: PriceAlertPreferences.minimumChangeRange)
    }

    /// "$0.01 and $2.00", from the shared bound.
    static var allowedRangeText: String {
        let range = PriceAlertPreferences.minimumChangeRange
        return "\(PriceAlertPriceInput.displayText(for: range.lowerBound)) and \(PriceAlertPriceInput.displayText(for: range.upperBound))"
    }

    /// Shown under an empty Custom field. Guidance, not an error.
    static var emptyHint: String {
        "Enter how far the price must fall, in dollars per gallon, between \(allowedRangeText)."
    }

    static func message(for problem: Problem) -> String {
        switch problem {
        case .notANumber:
            return "Enter an amount using numbers, like 0.15."
        case .negative:
            return "The amount can't be negative."
        case .tooManyDecimals:
            return "Use at most 3 decimal places, like 0.015."
        case .belowMinimum, .aboveMaximum:
            return "Enter an amount between \(allowedRangeText)."
        }
    }
}
