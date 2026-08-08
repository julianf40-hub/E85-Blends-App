//
//  BlendCostMathTests.swift
//  EightyFiveBlends
//
//  Tests for the pure gallons/cost math behind Compare Fuel Cost. This is the actual function
//  CostCalculatorView calls for every blend it shows (BlendCostMath.result) — not a duplicate
//  reimplementation — so passing tests here directly verify production behavior, including the
//  E30/E50/E70/E85 comparison set and the "total cost = gas gallons × gas price + E85 gallons ×
//  E85 price" formula.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.

import Testing
@testable import EightyFiveBlends

struct BlendCostMathTests {

    // MARK: E30/E50/E70/E85 calculations use shared blend math

    @Test("E50 with an 85% E85 / 10% gas baseline splits gallons by ethanol-content fraction")
    func result_e50_splitsGallonsByFraction() {
        // fraction = (50 - 10) / (85 - 10) = 40/75 ≈ 0.5333
        let result = BlendCostMath.result(
            totalGallons: 15,
            targetEthanolPercent: 50,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85PricePerGallon: 2.89,
            gasPricePerGallon: 3.49
        )
        let expectedFraction = (50.0 - 10.0) / (85.0 - 10.0)
        #expect(result != nil)
        #expect(abs((result?.e85Gallons ?? 0) - 15 * expectedFraction) < 0.0001)
        #expect(abs((result?.gasGallons ?? 0) - 15 * (1 - expectedFraction)) < 0.0001)
    }

    @Test("E30, E50, E70, and E85 all resolve for a typical 85/10 ethanol baseline")
    func result_e30E50E70E85_allResolve() {
        for target in [30.0, 50.0, 70.0, 85.0] {
            let result = BlendCostMath.result(
                totalGallons: 15,
                targetEthanolPercent: target,
                e85EthanolPercent: 85,
                gasEthanolPercent: 10,
                e85PricePerGallon: 2.89,
                gasPricePerGallon: 3.49
            )
            #expect(result != nil, "E\(Int(target)) should resolve for an 85/10 baseline")
            #expect(result?.ethanolPercent == target)
        }
    }

    @Test("E85 target with an 85% E85 fuel resolves to (approximately) all-E85 gallons")
    func result_e85Target_isAllE85() {
        let result = BlendCostMath.result(
            totalGallons: 15,
            targetEthanolPercent: 85,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85PricePerGallon: 2.89,
            gasPricePerGallon: 3.49
        )
        #expect(abs((result?.e85Gallons ?? 0) - 15) < 0.0001)
        #expect(abs((result?.gasGallons ?? 0) - 0) < 0.0001)
    }

    // MARK: total cost = gas gallons × gas price + E85 gallons × E85 price

    @Test("Total cost is exactly gasGallons × gasPrice + e85Gallons × e85Price")
    func result_totalCost_matchesFormula() {
        let result = BlendCostMath.result(
            totalGallons: 15,
            targetEthanolPercent: 50,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85PricePerGallon: 2.89,
            gasPricePerGallon: 3.49
        )
        guard let result else {
            Issue.record("Expected a result for E50 on an 85/10 baseline")
            return
        }
        let expected = result.gasGallons * 3.49 + result.e85Gallons * 2.89
        #expect(abs(result.totalCost - expected) < 0.0001)
    }

    @Test("A gasoline-only fill (0% target) costs totalGallons × gasPrice")
    func result_gasolineOnly_costsGallonsTimesGasPrice() {
        let result = BlendCostMath.result(
            totalGallons: 15,
            targetEthanolPercent: 10, // equals gasEthanolPercent — pure gasoline
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85PricePerGallon: 2.89,
            gasPricePerGallon: 3.49
        )
        #expect(result != nil)
        #expect(abs((result?.totalCost ?? 0) - 15 * 3.49) < 0.0001)
    }

    // MARK: Unreachable targets return nil rather than a nonsense split

    @Test("A target below the gasoline's own ethanol content is unreachable")
    func result_targetBelowGasEthanol_isNil() {
        let result = BlendCostMath.result(
            totalGallons: 15,
            targetEthanolPercent: 5,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85PricePerGallon: 2.89,
            gasPricePerGallon: 3.49
        )
        #expect(result == nil)
    }

    @Test("A target above the E85 fuel's own ethanol content is unreachable")
    func result_targetAboveE85Ethanol_isNil() {
        let result = BlendCostMath.result(
            totalGallons: 15,
            targetEthanolPercent: 90,
            e85EthanolPercent: 82, // this vehicle's recorded E85 pump fuel is only 82% ethanol
            gasEthanolPercent: 10,
            e85PricePerGallon: 2.89,
            gasPricePerGallon: 3.49
        )
        #expect(result == nil)
    }

    @Test("e85EthanolPercent <= gasEthanolPercent is always unreachable, regardless of target")
    func result_noEthanolDelta_isNil() {
        let result = BlendCostMath.result(
            totalGallons: 15,
            targetEthanolPercent: 50,
            e85EthanolPercent: 10,
            gasEthanolPercent: 10,
            e85PricePerGallon: 2.89,
            gasPricePerGallon: 3.49
        )
        #expect(result == nil)
    }
}
