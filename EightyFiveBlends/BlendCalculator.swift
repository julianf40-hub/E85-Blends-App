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
        /// Non-error guidance for valid special-case results (e.g. "pump E85 only" when
        /// the user targets the highest available blend). Nil for ordinary results.
        var guidanceMessage: String? = nil
    }

    private static let epsilon = 0.0001

    /// Float-safety tolerance for comparing ethanol percentages (in percentage points).
    private static let ethanolPercentTolerance = 0.001

    /// How far above the pump's E85 ethanol content a target may sit and still be treated
    /// as a valid "pump E85 only" fill instead of an unreachable blend. Covers the everyday
    /// case of targeting E85 while the pump's E85 actually tests at ~E80–E83. A target far
    /// above the pump fuel (e.g. E85 target on E70 pump fuel) still warns as unreachable.
    private static let e85OnlyGraceEthanolPoints = 5.0

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
                message: "Your tank is already full, so the blend can't change until you burn some fuel. You're at about \(blendLabel) now."
            )
        }

        // Highest-blend special case: the most ethanol we can possibly end up with is
        // filling all remaining space with the pump's E85. If the target is at that
        // ceiling or above it, the general solver would demand more E85 than fits and
        // report an unreachable blend — but "pump E85 only" is a perfectly valid,
        // real-world answer as long as the target isn't far above the pump fuel itself.
        if e85Ethanol > gasEthanol + epsilon {
            let maxAchievableEthanol = ((currentFuelGallons * currentFuelEthanol) + (spaceToFill * e85Ethanol)) / targetGallons
            let targetVsPumpFuelPoints = input.targetEthanolPercent - input.e85EthanolPercent

            // Only special-case targets at or above the pump fuel's own ethanol content
            // ("give me the highest blend"). Unreachable targets *below* the pump fuel
            // (e.g. E60 target on a nearly full E10 tank) keep the generic warning below.
            if targetEthanol - maxAchievableEthanol > epsilon,
               targetVsPumpFuelPoints >= -ethanolPercentTolerance {
                let maxAchievablePercent = rounded(maxAchievableEthanol * 100, places: 1)
                let maxAchievableLabel = label(for: maxAchievablePercent)

                guard targetVsPumpFuelPoints <= e85OnlyGraceEthanolPoints + ethanolPercentTolerance else {
                    // Target far above the pump fuel (e.g. E85 target on E70 pump fuel):
                    // keep this an honest unreachable warning, but say what IS possible.
                    // The achievable number is shown as a small range so it doesn't
                    // imply more precision than pump fuel and gauges really have.
                    let rangeLow = label(for: max(0, maxAchievablePercent - 2))
                    let rangeHigh = label(for: min(100, maxAchievablePercent + 2))
                    return warningResult(
                        input: input,
                        finalEthanolPercent: maxAchievablePercent,
                        message: "\(label(for: input.targetEthanolPercent)) is not possible with this pump's \(label(for: input.e85EthanolPercent)) fuel. The highest blend you can reach today is about \(rangeLow)–\(rangeHigh). Pump E85 only to get as close as possible."
                    )
                }

                let e85OnlyGallons = rounded(spaceToFill, places: 2)

                return Result(
                    e85Gallons: e85OnlyGallons,
                    gasGallons: 0,
                    totalGallonsToAdd: e85OnlyGallons,
                    finalEthanolPercent: maxAchievablePercent,
                    estimatedOctane: rounded(input.e85Octane, places: 1),
                    blendLabel: maxAchievableLabel,
                    warningMessage: nil,
                    guidanceMessage: String(
                        format: "Pump E85 only — add %.2f gallons of E85 and no gas. This gives you the highest blend available from this pump (about %@).",
                        e85OnlyGallons,
                        maxAchievableLabel
                    )
                )
            }
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
                message: "This blend is not possible with the fuel already in your tank and this pump's fuel. Try a different target blend."
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

    /// Projects a fill using regular pump gas only (no E85) — used when the user says
    /// they're pumping premium/regular At the Pump. Unlike `calculate(input:)`, this
    /// does not solve for the target blend; it reports where a gas-only fill lands.
    static func gasOnlyFill(input: Input) -> Result {
        let numericInputs = [
            input.tankSizeGallons,
            input.currentFuelLevelPercent,
            input.currentFuelEthanolPercent,
            input.gasEthanolPercent,
            input.gasOctane,
        ]

        guard numericInputs.allSatisfy(\.isFinite) else {
            return warningResult(input: input, message: "Enter valid numeric values before calculating a blend.")
        }

        guard input.tankSizeGallons > 0 else {
            return warningResult(input: input, message: "Enter a tank size greater than 0 gallons.")
        }

        guard (0...100).contains(input.currentFuelLevelPercent),
              (0...100).contains(input.currentFuelEthanolPercent),
              (0...100).contains(input.gasEthanolPercent) else {
            return warningResult(input: input, message: "Fuel levels and ethanol percentages must stay between 0% and 100%.")
        }

        if let tPercent = input.targetFuelLevelPercent,
           tPercent < input.currentFuelLevelPercent - epsilon {
            return warningResult(input: input, message: "Target fill level cannot be lower than the current fuel level.")
        }

        let currentFuelGallons = input.tankSizeGallons * input.currentFuelLevelPercent / 100
        let targetFillPercent = input.targetFuelLevelPercent ?? 100.0
        let targetGallons = input.tankSizeGallons * targetFillPercent / 100.0
        let spaceToFill = targetGallons - currentFuelGallons
        let currentBlend = rounded(input.currentFuelEthanolPercent, places: 1)

        guard spaceToFill > epsilon, targetGallons > epsilon else {
            // Nothing to add — the view's "tank is full / raise your target" states own
            // the messaging here, so return a quiet zero result at the current blend.
            return Result(
                e85Gallons: 0,
                gasGallons: 0,
                totalGallonsToAdd: 0,
                finalEthanolPercent: currentBlend,
                estimatedOctane: 0,
                blendLabel: label(for: currentBlend),
                warningMessage: nil
            )
        }

        let finalEthanolPercent = rounded(
            ((currentFuelGallons * input.currentFuelEthanolPercent / 100)
                + (spaceToFill * input.gasEthanolPercent / 100)) / targetGallons * 100,
            places: 1
        )

        guard finalEthanolPercent.isFinite else {
            return warningResult(input: input, message: "The current inputs produced an invalid estimate. Review the values and try again.")
        }

        return Result(
            e85Gallons: 0,
            gasGallons: rounded(spaceToFill, places: 2),
            totalGallonsToAdd: rounded(spaceToFill, places: 2),
            finalEthanolPercent: finalEthanolPercent,
            estimatedOctane: rounded(input.gasOctane, places: 1),
            blendLabel: label(for: finalEthanolPercent),
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
