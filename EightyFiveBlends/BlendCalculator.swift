//
//  BlendCalculator.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation

struct BlendCalculator {
    struct Input {
        let tankSizeGallons: Double
        let currentFuelLevelPercent: Double
        let currentFuelEthanolPercent: Double
        let targetEthanolPercent: Double
        let e85EthanolPercent: Double
        let gasEthanolPercent: Double
        let e85Octane: Double
        let gasOctane: Double
        /// Partial fill: fill only to this level rather than 100%. Nil = fill to full.
        /// Must be >= currentFuelLevelPercent when set.
        var targetFuelLevelPercent: Double? = nil
    }

    struct Result {
        let e85Gallons: Double
        let gasGallons: Double
        let totalGallonsToAdd: Double
        let finalEthanolPercent: Double
        let estimatedOctane: Double
        let blendLabel: String
        let warningMessage: String?
    }

    private static let epsilon = 0.0001

    static func calculate(input: Input) -> Result {
        let numericInputs = [
            input.tankSizeGallons,
            input.currentFuelLevelPercent,
            input.currentFuelEthanolPercent,
            input.targetEthanolPercent,
            input.e85EthanolPercent,
            input.gasEthanolPercent,
            input.e85Octane,
            input.gasOctane,
        ]

        guard numericInputs.allSatisfy(\.isFinite) else {
            return warningResult(input: input, message: "Enter valid numeric values before calculating a blend.")
        }

        guard input.tankSizeGallons > 0 else {
            return warningResult(input: input, message: "Enter a tank size greater than 0 gallons.")
        }

        guard (0...100).contains(input.currentFuelLevelPercent) else {
            return warningResult(input: input, message: "Current fuel level must be between 0% and 100%.")
        }

        let ethanolPercents = [
            input.currentFuelEthanolPercent,
            input.targetEthanolPercent,
            input.e85EthanolPercent,
            input.gasEthanolPercent,
        ]

        guard ethanolPercents.allSatisfy({ (0...100).contains($0) }) else {
            return warningResult(input: input, message: "Ethanol percentages must stay between 0% and 100%.")
        }

        guard input.e85Octane >= 0, input.gasOctane >= 0 else {
            return warningResult(input: input, message: "Octane values must be 0 or higher.")
        }

        let currentFuelGallons = input.tankSizeGallons * input.currentFuelLevelPercent / 100

        // Partial fill: resolve the target volume. Nil means fill to the full tank.
        if let tPercent = input.targetFuelLevelPercent,
           tPercent < input.currentFuelLevelPercent - epsilon {
            return warningResult(input: input, message: "Target fill level cannot be lower than the current fuel level.")
        }

        let targetFillPercent = input.targetFuelLevelPercent ?? 100.0
        let targetGallons = input.tankSizeGallons * targetFillPercent / 100.0
        // gallons available to add (equals spaceToFill when targetFillPercent = 100)
        let spaceToFill = targetGallons - currentFuelGallons

        guard spaceToFill >= -epsilon else {
            return warningResult(input: input, message: "Current fuel level cannot exceed the tank size.")
        }

        let currentFuelEthanol = input.currentFuelEthanolPercent / 100
        let targetEthanol = input.targetEthanolPercent / 100
        let e85Ethanol = input.e85EthanolPercent / 100
        let gasEthanol = input.gasEthanolPercent / 100

        if abs(spaceToFill) <= epsilon {
            let currentBlend = rounded(currentFuelEthanol * 100, places: 1)
            let blendLabel = label(for: currentBlend)

            if abs(currentBlend - input.targetEthanolPercent) <= 0.1 {
                return Result(
                    e85Gallons: 0,
                    gasGallons: 0,
                    totalGallonsToAdd: 0,
                    finalEthanolPercent: currentBlend,
                    estimatedOctane: 0,
                    blendLabel: blendLabel,
                    warningMessage: nil
                )
            }

            return warningResult(
                input: input,
                finalEthanolPercent: currentBlend,
                message: "The tank is already full, so the target blend cannot be adjusted without removing fuel."
            )
        }

        let denominator = e85Ethanol - gasEthanol
        // Solve for E85 over the partial (or full) target volume
        let numerator = (targetGallons * targetEthanol) - (currentFuelGallons * currentFuelEthanol) - (spaceToFill * gasEthanol)

        guard abs(denominator) > epsilon else {
            return warningResult(
                input: input,
                message: "The selected fuel ethanol values are too similar to solve a blend."
            )
        }

        var e85Gallons = numerator / denominator
        var gasGallons = spaceToFill - e85Gallons

        if e85Gallons < 0, abs(e85Gallons) <= epsilon {
            e85Gallons = 0
        }

        if gasGallons < 0, abs(gasGallons) <= epsilon {
            gasGallons = 0
        }

        if e85Gallons - spaceToFill > epsilon || gasGallons - spaceToFill > epsilon || e85Gallons < 0 || gasGallons < 0 {
            return warningResult(
                input: input,
                message: "That target blend cannot be reached with the current fuel in the tank and the selected fuel properties."
            )
        }

        let totalGallonsToAdd = e85Gallons + gasGallons
        // finalEthanolPercent is over targetGallons so it reflects the partial-fill volume
        let finalEthanolPercent = rounded(
            (
                (currentFuelGallons * currentFuelEthanol) +
                (e85Gallons * e85Ethanol) +
                (gasGallons * gasEthanol)
            ) / targetGallons * 100,
            places: 1
        )

        let estimatedOctane: Double
        if totalGallonsToAdd > epsilon {
            estimatedOctane = rounded(
                ((e85Gallons * input.e85Octane) + (gasGallons * input.gasOctane)) / totalGallonsToAdd,
                places: 1
            )
        } else {
            estimatedOctane = 0
        }

        let outputs = [e85Gallons, gasGallons, totalGallonsToAdd, finalEthanolPercent, estimatedOctane]
        guard outputs.allSatisfy(\.isFinite) else {
            return warningResult(input: input, message: "The current inputs produced an invalid estimate. Review the values and try again.")
        }

        return Result(
            e85Gallons: rounded(e85Gallons, places: 2),
            gasGallons: rounded(gasGallons, places: 2),
            totalGallonsToAdd: rounded(totalGallonsToAdd, places: 2),
            finalEthanolPercent: finalEthanolPercent,
            estimatedOctane: estimatedOctane,
            blendLabel: label(for: input.targetEthanolPercent),
            warningMessage: nil
        )
    }

    private static func warningResult(
        input: Input,
        finalEthanolPercent: Double? = nil,
        message: String
    ) -> Result {
        let blendPercent = finalEthanolPercent ?? rounded(input.targetEthanolPercent, places: 1)

        return Result(
            e85Gallons: 0,
            gasGallons: 0,
            totalGallonsToAdd: 0,
            finalEthanolPercent: blendPercent,
            estimatedOctane: 0,
            blendLabel: label(for: input.targetEthanolPercent),
            warningMessage: message
        )
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (value * factor).rounded() / factor
    }

    private static func label(for percent: Double) -> String {
        "E\(Int(percent.rounded()))"
    }
}
