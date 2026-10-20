//
//  CalculatorResultPresentation.swift
//  EightyFiveBlends
//
//  The single place BlendResultCard and PumpInstructionsSection ask "is this result safe to
//  show as a real recommendation?" A warning result (invalid input routed to NaN, an
//  already-full tank, an unreachable blend, etc.) always carries zero gallons and an
//  untrustworthy blend label — displaying those as real numbers would present an invalid
//  calculation as a usable fueling recommendation. Neutralizing the value in place (rather
//  than hiding the card/section) keeps the surrounding layout's structure and height
//  constant, so this never causes a layout jump while the user is still mid-edit.
//

import Foundation

enum CalculatorResultPresentation {
    static let neutralizedValue = "—"

    static func isNeutralized(for result: BlendCalculator.Result) -> Bool {
        result.warningMessage != nil
    }

    static func displayValue(_ value: String, for result: BlendCalculator.Result) -> String {
        isNeutralized(for: result) ? neutralizedValue : value
    }
}
