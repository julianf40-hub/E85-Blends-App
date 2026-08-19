//
//  FuelCostBreakEvenMath.swift
//  EightyFiveBlends
//
//  Pure math behind Compare Fuel Cost's break-even section (CostCalculatorView): given
//  today's entered fuel prices, how much MPG a blend can lose before gasoline becomes
//  cheaper per mile, and — the headline question — how high can the E85 pump price go
//  before E85 stops being worth it at all. Independent of SwiftUI so it's directly
//  unit-testable, mirroring BlendCostMath's separation of pure rules from the view that
//  calls them. See EightyFiveBlendsTests/FuelCostBreakEvenMathTests.swift.
//
//  Deliberately two distinct calculations — do not conflate them:
//   - maxAffordableMPGLossFraction: CURRENT-PRICE break-even for a specific blend's already-
//     computed fill cost (BlendCostMath.Result.totalCost) vs. a gas-only fill. Changes
//     whenever prices, tank size, or the selected blend change.
//   - e85PriceCeiling: the highest E85 PUMP PRICE at which E85 is still estimated to tie
//     gasoline on cost-per-mile, using e85MPGLossBenchmark. Depends only on the gasoline
//     price and the benchmark — never derived from a blend's current break-even fraction,
//     which would make the ceiling equal to whatever price was just entered and defeat the
//     point of the feature.
//

import Foundation

enum FuelCostBreakEvenMath {

    /// Benchmark E85 MPG loss used to estimate the E85 price ceiling — NOT a measurement of
    /// any specific vehicle's actual fuel economy. E85 typically returns lower MPG than
    /// gasoline because it holds less energy per gallon; this flat benchmark stands in for
    /// that expected loss. FuelLogEntry currently records a single per-fill `mpg` value with
    /// no blend-segmented history to build a personalized ratio from, so this benchmark is
    /// the only reliable input available today. The UI must state this assumption plainly
    /// (e.g. "Based on a 25% E85 MPG-loss benchmark") rather than presenting it as measured
    /// data. A future version could substitute an observed per-vehicle ratio here without
    /// changing any call site below.
    static let e85MPGLossBenchmark: Double = 0.25

    /// 1 - e85MPGLossBenchmark. Kept as its own name because it's what the ceiling formula
    /// actually multiplies by; e85MPGLossBenchmark is the number the UI states to the user.
    static var e85EfficiencyRatio: Double { 1 - e85MPGLossBenchmark }

    /// The highest E85 pump price at which E85 is still estimated to tie gasoline on
    /// cost-per-mile, using e85MPGLossBenchmark. `nil` for a non-finite/non-positive gasoline
    /// price — never produces a bogus ceiling from bad input.
    static func e85PriceCeiling(gasolinePricePerGallon: Double) -> Double? {
        guard gasolinePricePerGallon.isFinite, gasolinePricePerGallon > 0 else { return nil }
        let ceiling = gasolinePricePerGallon * e85EfficiencyRatio
        guard ceiling.isFinite, ceiling > 0 else { return nil }
        return ceiling
    }

    /// Fraction (not percent) of MPG a blend could lose, at TODAY's entered fill costs,
    /// before gasoline becomes cheaper per mile for the same tank volume:
    /// `1 - (blendFillCost / gasOnlyFillCost)`. Negative when the blend's fill already costs
    /// more than gas-only at equal MPG — callers must not display that as a literal
    /// "-X% MPG loss" allowance (see CostCalculatorView's mpgBreakEvenText, which handles
    /// that state separately). `nil` for invalid inputs (never divides by zero).
    static func maxAffordableMPGLossFraction(blendFillCost: Double, gasOnlyFillCost: Double) -> Double? {
        guard blendFillCost.isFinite, blendFillCost >= 0,
              gasOnlyFillCost.isFinite, gasOnlyFillCost > 0
        else { return nil }

        let fraction = 1 - (blendFillCost / gasOnlyFillCost)
        guard fraction.isFinite else { return nil }
        return fraction
    }

    /// Whether E85, at its current entered price, or gasoline is the better cost-per-mile
    /// value right now — using e85PriceCeiling as the threshold. Distinct from a blend's own
    /// maxAffordableMPGLossFraction: this is always about the E85 pump price specifically,
    /// regardless of which blend is currently selected for the cost comparison above it.
    enum Verdict: Equatable {
        case e85Better
        case approximatelyEqual
        case gasolineBetter
    }

    /// Dollar tolerance around the ceiling within which the two are treated as tied, so
    /// floating-point noise never produces a spurious "wins by a fraction of a cent" verdict
    /// when the entered price and the ceiling round to the same displayed cent. Comparisons
    /// always use raw, unrounded values — this tolerance exists specifically so a displayed
    /// tie (e.g. $3.90 vs. a $3.8999999… ceiling) can never render as one side "winning."
    static let priceTolerance: Double = 0.005

    /// `nil` for invalid inputs (mirrors e85PriceCeiling's own guards) — never guesses a
    /// verdict from bad data.
    static func verdict(currentE85PricePerGallon: Double, ceiling: Double) -> Verdict? {
        guard currentE85PricePerGallon.isFinite, currentE85PricePerGallon > 0,
              ceiling.isFinite, ceiling > 0
        else { return nil }

        if currentE85PricePerGallon < ceiling - priceTolerance { return .e85Better }
        if currentE85PricePerGallon > ceiling + priceTolerance { return .gasolineBetter }
        return .approximatelyEqual
    }
}
