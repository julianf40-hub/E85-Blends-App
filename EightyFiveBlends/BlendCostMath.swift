//
//  BlendCostMath.swift
//  EightyFiveBlends
//
//  Pure gallons/cost math behind Compare Fuel Cost (CostCalculatorView): given a total fill
//  amount and current fuel prices, how many gallons of E85 and gasoline a target ethanol-content
//  blend needs, and what the fill costs. This is the one trusted implementation CostCalculatorView
//  calls for every blend it shows — kept independent of SwiftUI so it's directly unit-testable,
//  mirroring AppExperienceNavigation/ReminderScheduling's separation of pure rules from the views
//  that call them. See EightyFiveBlendsTests/BlendCostMathTests.swift.
//
//  Deliberately independent of BlendCalculator.swift: that engine answers "how much E85 do I add
//  to a tank that's already partially full to reach a target blend" (a top-off, given a current
//  fuel level and its own ethanol content). This answers a different question — "filling N total
//  gallons, what's the E85/gas split and cost to land on a target ethanol percentage" — the
//  question Compare Fuel Cost actually needs. Both share the same underlying ethanol-content
//  fraction, just applied to a different starting state.
//

import Foundation

enum BlendCostMath {
    struct Result: Equatable {
        let ethanolPercent: Double
        let e85Gallons: Double
        let gasGallons: Double
        let totalCost: Double
    }

    /// `nil` when `targetEthanolPercent` cannot be reached by blending `gasEthanolPercent` fuel
    /// with `e85EthanolPercent` fuel — the target is below the gasoline's own ethanol content,
    /// above the E85's ethanol content, or `e85EthanolPercent <= gasEthanolPercent` entirely.
    static func result(
        totalGallons: Double,
        targetEthanolPercent: Double,
        e85EthanolPercent: Double,
        gasEthanolPercent: Double,
        e85PricePerGallon: Double,
        gasPricePerGallon: Double
    ) -> Result? {
        let delta = e85EthanolPercent - gasEthanolPercent
        guard delta > 0 else { return nil }

        let fraction = (targetEthanolPercent - gasEthanolPercent) / delta
        guard fraction >= 0, fraction <= 1 else { return nil }

        let e85Gallons = totalGallons * fraction
        let gasGallons = totalGallons * (1 - fraction)
        let totalCost = e85Gallons * e85PricePerGallon + gasGallons * gasPricePerGallon

        return Result(
            ethanolPercent: targetEthanolPercent,
            e85Gallons: e85Gallons,
            gasGallons: gasGallons,
            totalCost: totalCost
        )
    }
}
