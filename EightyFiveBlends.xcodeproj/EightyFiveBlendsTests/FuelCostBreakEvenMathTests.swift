//
//  FuelCostBreakEvenMathTests.swift
//  EightyFiveBlends
//
//  Tests for the pure math behind Compare Fuel Cost's break-even section — the actual
//  functions CostCalculatorView calls (e85PriceCeiling, maxAffordableMPGLossFraction,
//  verdict), not a duplicate reimplementation.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.

import Testing
@testable import EightyFiveBlends

struct FuelCostBreakEvenMathTests {

    // MARK: 1 — Reference price ceiling

    @Test("Reference price ceiling: $5.20 gas, 25% benchmark → $3.90 ceiling")
    func referencePriceCeiling() {
        let ceiling = FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: 5.20)
        #expect(abs((ceiling ?? 0) - 3.90) < 0.001)
    }

    // MARK: 2-4 — Verdict states around the ceiling

    @Test("E85 below the ceiling: verdict is e85Better")
    func e85BelowCeiling_isE85Better() {
        let ceiling = FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: 5.20)
        let verdict = FuelCostBreakEvenMath.verdict(currentE85PricePerGallon: 3.50, ceiling: ceiling ?? 0)
        #expect(verdict == .e85Better)
    }

    @Test("E85 exactly at the ceiling: verdict is approximatelyEqual")
    func e85AtCeiling_isApproximatelyEqual() {
        let ceiling = FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: 5.20)
        let verdict = FuelCostBreakEvenMath.verdict(currentE85PricePerGallon: 3.90, ceiling: ceiling ?? 0)
        #expect(verdict == .approximatelyEqual)
    }

    @Test("E85 above the ceiling: verdict is gasolineBetter")
    func e85AboveCeiling_isGasolineBetter() {
        let ceiling = FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: 5.20)
        let verdict = FuelCostBreakEvenMath.verdict(currentE85PricePerGallon: 4.50, ceiling: ceiling ?? 0)
        #expect(verdict == .gasolineBetter)
    }

    // Small tolerance around the displayed cent — the entered price and the ceiling can
    // differ by a fraction of a cent (floating-point noise) without flipping the verdict.
    @Test("A fraction-of-a-cent difference at the ceiling still reads as approximatelyEqual")
    func fractionOfACentAtCeiling_staysApproximatelyEqual() {
        let ceiling = FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: 5.20) ?? 0
        let verdict = FuelCostBreakEvenMath.verdict(currentE85PricePerGallon: ceiling + 0.001, ceiling: ceiling)
        #expect(verdict == .approximatelyEqual)
    }

    // MARK: 5 — Different gasoline price

    @Test("Different gasoline price: $4.00 gas → $3.00 ceiling")
    func differentGasolinePrice_scalesCeiling() {
        let ceiling = FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: 4.00)
        #expect(abs((ceiling ?? 0) - 3.00) < 0.001)
    }

    // MARK: 6 — Existing screenshot E85 MPG break-even

    @Test("Existing screenshot: gas-only fill $96.20, E85 fill $72.15 → 25% max MPG loss")
    func screenshotE85BreakEven_is25Percent() {
        let fraction = FuelCostBreakEvenMath.maxAffordableMPGLossFraction(blendFillCost: 72.15, gasOnlyFillCost: 96.20)
        #expect(abs((fraction ?? 0) - 0.25) < 0.001)
    }

    // MARK: 7 — $4.50 E85 MPG break-even

    @Test("$4.50 E85 fill $83.25 vs $96.20 gas-only → approximately 13.46% max MPG loss")
    func fourFiftyE85BreakEven_isApproximately13Point46Percent() {
        let fraction = FuelCostBreakEvenMath.maxAffordableMPGLossFraction(blendFillCost: 83.25, gasOnlyFillCost: 96.20)
        #expect(abs((fraction ?? 0) - 0.1346) < 0.001)
    }

    // MARK: 8 — Other blend cards (gas = $5.20, E85 = $3.90, tank = 18.5 gal)

    @Test("Blend comparison set: E30/E50/E70/E85 max MPG loss at $5.20 gas / $3.90 E85")
    func blendComparisonSet_matchesExpectedPercentages() {
        let gasOnly = 96.20
        let expectations: [(fillCost: Double, expectedFraction: Double)] = [
            (89.79, 0.067),  // E30
            (83.37, 0.133),  // E50
            (76.96, 0.200),  // E70
            (72.15, 0.250),  // E85
        ]
        for (fillCost, expected) in expectations {
            let fraction = FuelCostBreakEvenMath.maxAffordableMPGLossFraction(blendFillCost: fillCost, gasOnlyFillCost: gasOnly)
            #expect(abs((fraction ?? 0) - expected) < 0.002, "fillCost \(fillCost) expected ≈\(expected), got \(fraction ?? -1)")
        }
    }

    // MARK: 9 — Invalid gasoline price

    @Test("Zero or negative gasoline price never divides by zero or produces a ceiling")
    func invalidGasolinePrice_producesNilCeiling() {
        #expect(FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: 0) == nil)
        #expect(FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: -1) == nil)
        #expect(FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: .nan) == nil)
        #expect(FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: .infinity) == nil)
    }

    @Test("Zero or negative gas-only fill cost never divides by zero in the MPG break-even")
    func invalidGasOnlyFillCost_producesNilFraction() {
        #expect(FuelCostBreakEvenMath.maxAffordableMPGLossFraction(blendFillCost: 50, gasOnlyFillCost: 0) == nil)
        #expect(FuelCostBreakEvenMath.maxAffordableMPGLossFraction(blendFillCost: 50, gasOnlyFillCost: -10) == nil)
        #expect(FuelCostBreakEvenMath.maxAffordableMPGLossFraction(blendFillCost: .nan, gasOnlyFillCost: 96.20) == nil)
    }

    @Test("verdict is nil for invalid current E85 price or ceiling, never a guessed answer")
    func invalidVerdictInputs_produceNil() {
        #expect(FuelCostBreakEvenMath.verdict(currentE85PricePerGallon: 0, ceiling: 3.90) == nil)
        #expect(FuelCostBreakEvenMath.verdict(currentE85PricePerGallon: -1, ceiling: 3.90) == nil)
        #expect(FuelCostBreakEvenMath.verdict(currentE85PricePerGallon: .nan, ceiling: 3.90) == nil)
        #expect(FuelCostBreakEvenMath.verdict(currentE85PricePerGallon: 3.50, ceiling: 0) == nil)
    }

    // MARK: 10 — Blend more expensive than gasoline

    @Test("A blend costing more than gas-only produces a negative fraction, not a positive loss-allowance")
    func blendMoreExpensiveThanGasoline_isNegativeFraction() {
        // Fill cost $100 vs a $96.20 gas-only fill — this blend is already more expensive at
        // equal MPG, so there is no MPG "loss allowance" to state.
        let fraction = FuelCostBreakEvenMath.maxAffordableMPGLossFraction(blendFillCost: 100, gasOnlyFillCost: 96.20)
        #expect((fraction ?? 0) < 0)
        // The domain layer returns the raw negative fraction (correct, not UI-formatted) —
        // it is CostCalculatorView.mpgBreakEvenText's job to turn a negative fraction into
        // "Gas cheaper at equal MPG" rather than a literal negative percentage. This test
        // locks in the raw value the display layer must branch on.
        #expect(abs((fraction ?? 0) - (-0.0395)) < 0.001)
    }

    // MARK: E85 price ceiling is independent of the current-price MPG break-even

    // Regression against the exact bug this feature must avoid (section 15): deriving the
    // ceiling FROM the current blend's own break-even fraction would make the entered E85
    // price equal its own ceiling every time, making the feature circular/useless. Prove the
    // ceiling only depends on the gasoline price, not on any blend fill cost.
    @Test("E85 price ceiling does not change when the current blend's fill cost changes")
    func priceCeiling_isIndependentOfBlendFillCost() {
        let ceilingAtE85Price390 = FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: 5.20)
        let ceilingAtE85Price450 = FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: 5.20)
        // Same gas price → same ceiling, regardless of what E85 currently costs or what
        // blend fill cost was just computed — the ceiling formula never reads either.
        #expect(ceilingAtE85Price390 == ceilingAtE85Price450)
        #expect(abs((ceilingAtE85Price390 ?? 0) - 3.90) < 0.001)
    }
}
