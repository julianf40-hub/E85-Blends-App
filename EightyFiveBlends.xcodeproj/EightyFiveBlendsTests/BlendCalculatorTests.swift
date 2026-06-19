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
}
