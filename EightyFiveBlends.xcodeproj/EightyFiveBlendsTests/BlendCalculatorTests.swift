//
//  BlendCalculatorTests.swift
//  EightyFiveBlendsTests
//
//  Tests for BlendCalculator partial fill and regression cases.
//

import Testing
@testable import EightyFiveBlends

struct BlendCalculatorTests {

    // Shared base parameters used across tests
    private func baseInput(
        tankSize: Double = 18,
        currentLevel: Double,
        targetLevel: Double? = nil,
        targetEthanol: Double = 30
    ) -> BlendCalculator.Input {
        BlendCalculator.Input(
            tankSizeGallons: tankSize,
            currentFuelLevelPercent: currentLevel,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: targetEthanol,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91,
            targetFuelLevelPercent: targetLevel
        )
    }

    // MARK: - Chip gallons accuracy (mirrors Current chip 1/4 → 25% → 4.5 gal)

    @Test("Quarter chip (25%) equals 4.5 gallons on an 18-gallon tank")
    func chip_quarter_gallonsAccuracy() {
        // 18 gal * 25% = 4.5 gal current; target 50% = 9.0 gal; to add = 4.5 gal
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 25, targetLevel: 50))
        #expect(result.warningMessage == nil)
        #expect(abs(result.totalGallonsToAdd - 4.5) < 0.01)
    }

    @Test("Half chip (50%) equals 9.0 gallons on an 18-gallon tank")
    func chip_half_gallonsAccuracy() {
        // 18 gal * 50% = 9.0 gal; filling from empty to half = 9.0 gal to add
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 0, targetLevel: 50))
        #expect(result.warningMessage == nil)
        #expect(abs(result.totalGallonsToAdd - 9.0) < 0.01)
    }

    // MARK: - Target chip disabled below current (calculator rejects target < current)

    @Test("Target chip below current level is rejected by the calculator")
    func targetChip_belowCurrent_isRejected() {
        // Simulates selecting target 1/4 chip (25%) when current is 1/2 (50%)
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 50, targetLevel: 25))
        #expect(result.warningMessage != nil)
        #expect(result.totalGallonsToAdd == 0)
    }

    // MARK: - Auto-raise: raising current above target clamps target to current

    @Test("Raising current above target produces zero-fill result (mirrors auto-raise behavior)")
    func raisingCurrentAboveTarget_yieldsZeroFill() {
        // UI clamps target to current when current is raised above target.
        // Test the resulting same-level state at the calculator layer.
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 75, targetLevel: 75))
        #expect(result.totalGallonsToAdd == 0)
    }

    // MARK: - Case 1: 18 gal, 25% → 50%, gallonsToAdd = 4.5

    @Test("Partial fill 25%→50% adds exactly 4.5 gallons")
    func partialFill_25to50_gallonsToAdd() {
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 25, targetLevel: 50))
        #expect(result.warningMessage == nil)
        #expect(abs(result.totalGallonsToAdd - 4.5) < 0.01)
    }

    // MARK: - Case 2: 18 gal, 50% → 100%, gallonsToAdd = 9.0

    @Test("Partial fill 50%→100% adds exactly 9.0 gallons")
    func partialFill_50to100_gallonsToAdd() {
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 50, targetLevel: 100))
        #expect(result.warningMessage == nil)
        #expect(abs(result.totalGallonsToAdd - 9.0) < 0.01)
    }

    // MARK: - Case 3: Target equals current → gallonsToAdd = 0

    @Test("Current equals target shows zero gallons to add (zero-fill state, blocks calculation)")
    func partialFill_targetEqualsCurrentLevel_zeroGallons() {
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 50, targetLevel: 50))
        #expect(result.totalGallonsToAdd == 0)
        // Calculator returns a warning for this case (same-level / "already full")
        // which the UI uses to disable the Log button
        #expect(result.warningMessage != nil)
    }

    // MARK: - Case 4: Partial Fill OFF — results identical to production

    @Test("Partial Fill OFF: nil targetFuelLevelPercent matches full-fill calculation exactly")
    func partialFillOff_matchesFullFillBehavior() {
        let standard = BlendCalculator.calculate(input: baseInput(currentLevel: 25))
        let withFull  = BlendCalculator.calculate(input: baseInput(currentLevel: 25, targetLevel: 100))

        #expect(standard.e85Gallons          == withFull.e85Gallons)
        #expect(standard.gasGallons          == withFull.gasGallons)
        #expect(standard.totalGallonsToAdd   == withFull.totalGallonsToAdd)
        #expect(standard.finalEthanolPercent == withFull.finalEthanolPercent)
        #expect(standard.warningMessage      == withFull.warningMessage)
    }

    // MARK: - Case 5: Budget check — estimated cost exceeds limit

    @Test("Estimated cost at given prices exceeds a tight budget")
    func partialFill_budgetExceededLogic() {
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 25, targetLevel: 50))
        #expect(result.warningMessage == nil)
        #expect(result.totalGallonsToAdd > 0)

        let e85Price  = 3.50
        let gasPrice  = 4.00
        let budget    = 5.00
        let estimated = result.e85Gallons * e85Price + result.gasGallons * gasPrice

        #expect(estimated > budget)
    }

    // MARK: - Guard: target below current is rejected

    @Test("Target level below current level produces a warning")
    func partialFill_targetBelowCurrent_warning() {
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 75, targetLevel: 25))
        #expect(result.warningMessage != nil)
        #expect(result.totalGallonsToAdd == 0)
    }

    // MARK: - Blend accuracy

    @Test("Final ethanol percent is accurate over partial fill volume")
    func partialFill_finalEthanolAccuracy() {
        // 18 gal, 25%→50%, target E30 → finalEthanolPercent ≈ 30%
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 25, targetLevel: 50))
        #expect(result.warningMessage == nil)
        #expect(abs(result.finalEthanolPercent - 30.0) < 0.2)
    }

    // MARK: - Pure E85 / highest blend special case

    @Test("Empty tank, target equals pump E85 content → clean E85-only result")
    func e85Only_emptyTank_targetEqualsPumpContent() {
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 0, targetEthanol: 85))
        #expect(result.warningMessage == nil)
        #expect(abs(result.e85Gallons - 18.0) < 0.01)
        #expect(result.gasGallons == 0)
        #expect(abs(result.finalEthanolPercent - 85.0) < 0.2)
    }

    @Test("Partial tank of lower blend, target set to pump E85 content → pump E85 only guidance")
    func e85Only_partialTankLowerBlend_targetHighest() {
        // 18 gal, 25% of E10 in the tank, target E85 from an E85 pump. Mathematically
        // unreachable as a blend, but the correct real-world answer is "pump E85 only".
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 25, targetEthanol: 85))
        #expect(result.warningMessage == nil)
        #expect(result.guidanceMessage != nil)
        #expect(abs(result.e85Gallons - 13.5) < 0.01)
        #expect(result.gasGallons == 0)
        // (4.5 * 10 + 13.5 * 85) / 18 = 66.25
        #expect(abs(result.finalEthanolPercent - 66.3) < 0.2)
        #expect(result.finalEthanolPercent <= 85.0)
    }

    @Test("Target slightly above pump E85 content is handled gracefully")
    func e85Only_targetSlightlyAbovePumpContent() {
        // Target E85 chip while pump fuel tests at E82 — everyday case, must not error.
        let input = BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 85,
            e85EthanolPercent: 82,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        )
        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage == nil)
        #expect(result.guidanceMessage != nil)
        #expect(result.gasGallons == 0)
        #expect(result.e85Gallons > 0)
    }

    @Test("Target far above pump fuel content still warns as unreachable")
    func e85Only_targetFarAbovePumpContent_warns() {
        // Pump fuel is E70 but target is E85 — must not pretend E85 is reachable.
        let input = BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 85,
            e85EthanolPercent: 70,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        )
        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage != nil)
        #expect(result.guidanceMessage == nil)
        #expect(result.e85Gallons == 0)
        #expect(result.totalGallonsToAdd == 0)
        // Warning should state what IS achievable rather than a bare error.
        #expect(result.warningMessage?.contains("E85 only") == true)
    }

    @Test("Unreachable target below pump fuel keeps the generic warning")
    func e85Only_unreachableTargetBelowPumpContent_keepsWarning() {
        // Nearly full tank of E10, target E60: not a "highest blend" ask, still impossible.
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 95, targetEthanol: 60))
        #expect(result.warningMessage != nil)
        #expect(result.guidanceMessage == nil)
    }

    @Test("E85-only special case does not regress normal blend math")
    func e85Only_normalBlendUnaffected() {
        // Standard reachable E30 target must still produce a mixed fill with no guidance.
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 25))
        #expect(result.warningMessage == nil)
        #expect(result.guidanceMessage == nil)
        #expect(result.e85Gallons > 0)
        #expect(result.gasGallons > 0)
    }

    @Test("E85-only guidance result preserves the requested target for the fuel log")
    func e85Only_preservesRequestedTarget() {
        // Target E85, achieved ~E66: blendLabel shows the outcome, but the requested
        // target must survive for fuel-log prefill.
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 25, targetEthanol: 85))
        #expect(result.guidanceMessage != nil)
        #expect(result.requestedTargetEthanolPercent == 85)
        #expect(result.blendLabel != "E85")
    }

    // MARK: - Gas-only fill projection (Pump Fuel = 91)

    @Test("Gas-only fill projects the final blend instead of solving for a target")
    func gasOnly_projectsFinalBlend() {
        // 18 gal tank, half full of E50, topped off with E10 gas:
        // (9 * 0.50 + 9 * 0.10) / 18 = 30% final.
        let input = BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 50,
            currentFuelEthanolPercent: 50,
            targetEthanolPercent: 50, // ignored by gasOnlyFill
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        )
        let result = BlendCalculator.gasOnlyFill(input: input)
        #expect(result.warningMessage == nil)
        #expect(result.e85Gallons == 0)
        #expect(abs(result.gasGallons - 9.0) < 0.01)
        #expect(abs(result.finalEthanolPercent - 30.0) < 0.1)
        #expect(abs(result.estimatedOctane - 91.0) < 0.1)
    }

    @Test("Gas-only fill with a full tank returns a quiet zero result")
    func gasOnly_fullTank_zeroResult() {
        let result = BlendCalculator.gasOnlyFill(input: baseInput(currentLevel: 100))
        #expect(result.warningMessage == nil)
        #expect(result.totalGallonsToAdd == 0)
        #expect(result.gasGallons == 0)
    }

    @Test("Gas-only partial fill respects the target level")
    func gasOnly_partialFill() {
        // 18 gal, 25% of E85 in tank, gas E10, fill to 50%:
        // (4.5 * 0.85 + 4.5 * 0.10) / 9 = 47.5% final over the partial volume.
        let input = BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 85,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91,
            targetFuelLevelPercent: 50
        )
        let result = BlendCalculator.gasOnlyFill(input: input)
        #expect(result.warningMessage == nil)
        #expect(abs(result.gasGallons - 4.5) < 0.01)
        #expect(abs(result.finalEthanolPercent - 47.5) < 0.1)
    }

    @Test("E85-only result values are finite and non-negative")
    func e85Only_noNaNOrNegatives() {
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 2, targetEthanol: 85))
        #expect(result.e85Gallons.isFinite && result.e85Gallons >= 0)
        #expect(result.gasGallons.isFinite && result.gasGallons >= 0)
        #expect(result.totalGallonsToAdd.isFinite && result.totalGallonsToAdd >= 0)
        #expect(result.finalEthanolPercent.isFinite)
        #expect(result.estimatedOctane.isFinite && result.estimatedOctane >= 0)
    }

    // MARK: - Current ethanol equals target ethanol

    @Test("Current ethanol content equal to target ethanol content tops off with gas only, no warning")
    func currentEthanol_equalsTargetEthanol_producesGasOnlyTopOff() {
        // 18 gal tank, 25% of E10 in the tank, target E10 (same as current and same as pump
        // gas) — the correct answer is "top off with gas, no E85 needed."
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 25, targetEthanol: 10))
        #expect(result.warningMessage == nil)
        #expect(result.e85Gallons == 0)
        #expect(abs(result.gasGallons - 13.5) < 0.01)
        #expect(abs(result.finalEthanolPercent - 10.0) < 0.1)
    }

    // MARK: - Current fuel level at zero (ordinary target, not the E85-only special case)

    @Test("Empty tank with an ordinary reachable target fills the whole tank at that blend")
    func emptyTank_ordinaryTarget_fillsFullTankAtBlend() {
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 0, targetEthanol: 30))
        #expect(result.warningMessage == nil)
        #expect(result.guidanceMessage == nil)
        #expect(abs(result.totalGallonsToAdd - 18.0) < 0.01)
        #expect(abs(result.finalEthanolPercent - 30.0) < 0.2)
    }

    // MARK: - Nearly full tank

    @Test("Nearly full tank with too little room to reach a lower target warns instead of computing an impossible fill")
    func nearlyFullTank_insufficientRoom_warns() {
        // 18 gal tank at 98% (only 0.36 gal of headroom) can't add enough E85 to move a
        // deeply diluted tank down to a lower target blend.
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 98, targetEthanol: 30))
        #expect(result.warningMessage != nil)
        #expect(result.totalGallonsToAdd == 0)
    }

    @Test("Nearly full tank with a reachable target computes a small precise fill using the remaining space")
    func nearlyFullTank_reachableTarget_computesSmallFill() {
        let input = BlendCalculator.Input(
            tankSizeGallons: 20,
            currentFuelLevelPercent: 95,
            currentFuelEthanolPercent: 28,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        )
        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage == nil)
        #expect(abs(result.totalGallonsToAdd - 1.0) < 0.01)
        #expect(abs(result.finalEthanolPercent - 30.0) < 0.2)
    }

    // MARK: - Requested target mathematically unreachable (generic, non-E85 special case)

    @Test("Diluting below both the current fuel and pump gas ethanol content is rejected as unreachable")
    func dilutingBelowBothSources_isRejectedAsUnreachable() {
        // Nearly full tank of E10, target E5: no amount of this pump's fuel (E10 or E85) can
        // dilute the tank lower than the lowest-ethanol fuel already available.
        let input = BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 90,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 5,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        )
        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage != nil)
        #expect(result.guidanceMessage == nil)
        #expect(result.e85Gallons == 0)
        #expect(result.totalGallonsToAdd == 0)
    }

    // MARK: - Invalid tank capacities and percentages

    @Test("Zero or negative tank size is rejected")
    func invalidTankSize_zeroOrNegative_isRejected() {
        for tankSize in [0.0, -10.0] {
            let result = BlendCalculator.calculate(input: baseInput(tankSize: tankSize, currentLevel: 25))
            #expect(result.warningMessage != nil)
            #expect(result.totalGallonsToAdd == 0)
        }
    }

    @Test("Current fuel level outside 0 to 100 percent is rejected")
    func invalidCurrentFuelLevel_outOfRange_isRejected() {
        for level in [-5.0, 150.0] {
            let result = BlendCalculator.calculate(input: baseInput(currentLevel: level))
            #expect(result.warningMessage != nil)
            #expect(result.totalGallonsToAdd == 0)
        }
    }

    @Test("Ethanol percentage outside 0 to 100 is rejected")
    func invalidEthanolPercent_outOfRange_isRejected() {
        for target in [-10.0, 150.0] {
            let result = BlendCalculator.calculate(input: baseInput(currentLevel: 25, targetEthanol: target))
            #expect(result.warningMessage != nil)
            #expect(result.totalGallonsToAdd == 0)
        }
    }

    @Test("Negative octane values are rejected")
    func invalidOctane_negative_isRejected() {
        let input = BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: -5,
            gasOctane: 91
        )
        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage != nil)
        #expect(result.totalGallonsToAdd == 0)
    }

    @Test("Target fill level above 100 percent is rejected instead of overfilling past tank capacity")
    func targetFillLevelAbove100_isRejected() {
        let result = BlendCalculator.calculate(input: baseInput(currentLevel: 25, targetLevel: 150))
        #expect(result.warningMessage != nil)
        #expect(result.totalGallonsToAdd == 0)
    }

    @Test("Gas-only fill also rejects a target level above 100 percent")
    func gasOnly_targetFillLevelAbove100_isRejected() {
        let input = BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91,
            targetFuelLevelPercent: 120
        )
        let result = BlendCalculator.gasOnlyFill(input: input)
        #expect(result.warningMessage != nil)
        #expect(result.totalGallonsToAdd == 0)
    }

    // MARK: - NaN and infinity protection

    @Test("NaN and infinite inputs degrade gracefully instead of propagating invalid numbers")
    func nanAndInfiniteInputs_degradeGracefully() {
        let invalidTankSizes: [Double] = [.nan, .infinity, -.infinity]
        for tankSize in invalidTankSizes {
            let result = BlendCalculator.calculate(input: baseInput(tankSize: tankSize, currentLevel: 25))
            #expect(result.warningMessage != nil)
            #expect(result.e85Gallons.isFinite)
            #expect(result.gasGallons.isFinite)
            #expect(result.totalGallonsToAdd == 0)
        }

        let nanTargetInput = BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: .nan,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91
        )
        let nanTargetResult = BlendCalculator.calculate(input: nanTargetInput)
        #expect(nanTargetResult.warningMessage != nil)
        #expect(nanTargetResult.finalEthanolPercent.isFinite)
        // Regression guard: a NaN target used to reach `Int(percent.rounded())` in the
        // display-label helper and crash the app outright instead of showing a warning.
        #expect(nanTargetResult.blendLabel == "E--")

        let infiniteOctaneInput = BlendCalculator.Input(
            tankSizeGallons: 18,
            currentFuelLevelPercent: 25,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: .infinity,
            gasOctane: 91
        )
        let infiniteOctaneResult = BlendCalculator.calculate(input: infiniteOctaneInput)
        #expect(infiniteOctaneResult.warningMessage != nil)
        #expect(infiniteOctaneResult.estimatedOctane.isFinite)
    }

    // MARK: - Floating point rounding near display boundaries

    @Test("Target ethanol exactly at a half-percent boundary rounds the display label away from zero")
    func labelRounding_halfPercentBoundary_roundsAwayFromZero() {
        // 100 gal tank (so percent == gallons), empty, target exactly 84.5% with pump fuel at
        // E95/E80 — a clean, reachable blend that keeps the target's raw 84.5 as the label.
        let input = BlendCalculator.Input(
            tankSizeGallons: 100,
            currentFuelLevelPercent: 0,
            currentFuelEthanolPercent: 0,
            targetEthanolPercent: 84.5,
            e85EthanolPercent: 95,
            gasEthanolPercent: 80,
            e85Octane: 105,
            gasOctane: 91
        )
        let result = BlendCalculator.calculate(input: input)
        #expect(result.warningMessage == nil)
        #expect(result.blendLabel == "E85")
        #expect(abs(result.finalEthanolPercent - 84.5) < 0.01)
    }

    @Test("Gallons rounding at an exact eighth-gallon boundary rounds away from zero to two decimal places")
    func gallonsRounding_eighthGallonBoundary_roundsAwayFromZero() {
        // tankSize = 100 makes percent == gallons. 24.125 - 20 = 4.125 gal exactly
        // (both operands are exactly representable in binary floating point), so rounding
        // to 2 places must resolve the trailing half-cent (412.5 -> 413) the same way every time.
        let input = BlendCalculator.Input(
            tankSizeGallons: 100,
            currentFuelLevelPercent: 20,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 105,
            gasOctane: 91,
            targetFuelLevelPercent: 24.125
        )
        let result = BlendCalculator.gasOnlyFill(input: input)
        #expect(result.warningMessage == nil)
        #expect(abs(result.gasGallons - 4.13) < 0.001)
        #expect(abs(result.totalGallonsToAdd - 4.13) < 0.001)
    }
}
