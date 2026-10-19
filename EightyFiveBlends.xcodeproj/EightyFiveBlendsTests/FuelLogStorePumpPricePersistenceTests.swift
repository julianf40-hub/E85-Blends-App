//
//  FuelLogStorePumpPricePersistenceTests.swift
//  EightyFiveBlendsTests
//
//  Regression coverage for the 2.4.1 release-audit finding: prices the user typed into
//  At The Pump's Budget section were discarded when logging a fill-up —
//  FuelLogStore.prefillDraft(from:vehicle:) hardcoded both prices to 0, and
//  CalculatorView.pumpModeFuelLogDraft(from:) only ever had a stale cached station price
//  (never the user's own input) to fall back on for E85, and nothing at all for gas.
//
//  These tests exercise FuelLogStore.prefillDraft directly — the pure, testable function
//  both call sites now funnel through — rather than the full SwiftData persistence path,
//  matching this codebase's existing convention of not standing up a live ModelContext in
//  unit tests (see ReminderCompletionUndoTests). The gallons/ethanol math comes from the
//  real BlendCalculator so scenarios stay realistic.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct FuelLogStorePumpPricePersistenceTests {

    private func mixedBlendResult() -> BlendCalculator.Result {
        BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: 15,
            currentFuelLevelPercent: 20,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 100,
            gasOctane: 91
        ))
    }

    private func gasOnlyResult() -> BlendCalculator.Result {
        BlendCalculator.gasOnlyFill(input: BlendCalculator.Input(
            tankSizeGallons: 15,
            currentFuelLevelPercent: 20,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 10,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 100,
            gasOctane: 91
        ))
    }

    private func partialFillMixedBlendResult() -> BlendCalculator.Result {
        BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: 15,
            currentFuelLevelPercent: 40,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 30,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 100,
            gasOctane: 91,
            targetFuelLevelPercent: 70
        ))
    }

    // MARK: - The reported defect: entered prices must not become 0

    @Test("A mixed E85/gas fill-up preserves both user-entered prices instead of zeroing them")
    func mixedFillUp_preservesBothEnteredPrices() {
        let result = mixedBlendResult()
        #expect(result.e85Gallons > 0)
        #expect(result.gasGallons > 0)

        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: 2.49,
            enteredGasPricePerGallon: 4.19,
            stationE85PricePerGallon: nil
        )

        #expect(draft.e85PricePerGallon == 2.49)
        #expect(draft.gasPricePerGallon == 4.19)

        let expectedCost = (result.e85Gallons * 2.49) + (result.gasGallons * 4.19)
        #expect(abs(draft.computedTotalCost - expectedCost) < 0.0001)
    }

    @Test("An E85-only fill-up preserves the entered E85 price without requiring a gas price")
    func e85OnlyFillUp_preservesEnteredE85Price() {
        let result = BlendCalculator.calculate(input: BlendCalculator.Input(
            tankSizeGallons: 15,
            currentFuelLevelPercent: 10,
            currentFuelEthanolPercent: 10,
            targetEthanolPercent: 85,
            e85EthanolPercent: 85,
            gasEthanolPercent: 10,
            e85Octane: 100,
            gasOctane: 91
        ))
        #expect(result.gasGallons == 0)

        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: 2.49,
            enteredGasPricePerGallon: nil,
            stationE85PricePerGallon: nil
        )

        #expect(draft.e85PricePerGallon == 2.49)
        #expect(draft.gasPricePerGallon == 0)
    }

    @Test("A gasoline-only fill-up preserves the entered gas price — previously always lost")
    func gasOnlyFillUp_preservesEnteredGasPrice() {
        let result = gasOnlyResult()
        #expect(result.e85Gallons == 0)
        #expect(result.gasGallons > 0)

        // Before the fix, nothing ever wrote a gas price into the pump-mode draft — this
        // is the scenario the audit's "gas price always 0" finding describes exactly.
        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: nil,
            enteredGasPricePerGallon: 3.99,
            stationE85PricePerGallon: nil
        )

        #expect(draft.gasPricePerGallon == 3.99)
        #expect(draft.e85PricePerGallon == 0)
    }

    @Test("A partial fill preserves entered prices and keeps the correct partial-fill gallons")
    func partialFill_preservesEnteredPricesAndGallons() {
        let fullFill = mixedBlendResult()
        let partial = partialFillMixedBlendResult()

        // Sanity: the partial fill really is adding less than a full fill would, so this
        // scenario is distinct from the full-fill test above.
        #expect(partial.totalGallonsToAdd < fullFill.totalGallonsToAdd)

        let draft = FuelLogStore.prefillDraft(
            from: partial,
            vehicle: nil,
            enteredE85PricePerGallon: 2.49,
            enteredGasPricePerGallon: 4.19,
            stationE85PricePerGallon: nil
        )

        #expect(draft.e85PricePerGallon == 2.49)
        #expect(draft.gasPricePerGallon == 4.19)
        #expect(draft.e85Gallons == partial.e85Gallons)
        #expect(draft.gasGallons == partial.gasGallons)
    }

    // MARK: - A user-entered price must win over a stale cached station price

    @Test("An entered E85 price overrides a stale cached station price rather than being discarded")
    func enteredPrice_overridesStaleStationPrice() {
        let result = mixedBlendResult()

        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: 2.49,
            enteredGasPricePerGallon: nil,
            stationE85PricePerGallon: 2.19 // stale cached price from a previously saved station
        )

        #expect(draft.e85PricePerGallon == 2.49)
    }

    // MARK: - Pre-existing fallback behavior must be unchanged (not a regression)

    @Test("With no entered price, a matched station's cached E85 price is still used as before")
    func noEnteredPrice_fallsBackToStationPrice() {
        let result = mixedBlendResult()

        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: nil,
            enteredGasPricePerGallon: nil,
            stationE85PricePerGallon: 2.19
        )

        #expect(draft.e85PricePerGallon == 2.19)
        #expect(draft.gasPricePerGallon == 0)
    }

    @Test("With no entered price and no station match, prices default to 0 exactly as before")
    func noEnteredPriceNoStationMatch_defaultsToZero() {
        let result = mixedBlendResult()

        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: nil,
            enteredGasPricePerGallon: nil,
            stationE85PricePerGallon: nil
        )

        #expect(draft.e85PricePerGallon == 0)
        #expect(draft.gasPricePerGallon == 0)
    }

    @Test("A saved vehicle's name and odometer still prefill correctly alongside an entered price")
    func savedVehicle_prefillsAlongsideEnteredPrice() {
        let vehicle = VehicleProfile(nickname: "Civic", currentOdometer: 42_000)
        let result = mixedBlendResult()

        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: vehicle,
            enteredE85PricePerGallon: 2.49,
            enteredGasPricePerGallon: 4.19,
            stationE85PricePerGallon: nil
        )

        #expect(draft.vehicleName == "Civic")
        #expect(draft.odometer == 42_000)
        #expect(draft.e85PricePerGallon == 2.49)
        #expect(draft.gasPricePerGallon == 4.19)
    }

    // MARK: - Invalid / missing input must never fabricate a price

    @Test("A non-numeric entered price string parses to nil and is never silently treated as a real price")
    func invalidPriceInput_isTreatedAsNotEntered() {
        // Mirrors AtThePumpView's own parsing: FuelPriceInput.parsePositiveAmount("abc") is
        // nil, so the computed PumpModeFillUpPrices.e85PricePerGallon must be nil here, not
        // some fabricated value.
        #expect(FuelPriceInput.parsePositiveAmount("abc") == nil)

        let result = mixedBlendResult()
        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: nil, // what AtThePumpView computes for an unparsable string
            enteredGasPricePerGallon: nil,
            stationE85PricePerGallon: nil
        )

        #expect(draft.e85PricePerGallon == 0)
        #expect(draft.gasPricePerGallon == 0)
    }

    @Test("An explicitly entered price of 0 is treated as not-entered, matching the app's existing 0-means-no-price-data convention")
    func explicitZeroEntered_isTreatedAsNotEntered() {
        // AtThePumpView.enteredPumpFillUpPrices only treats a POSITIVE parsed value as
        // "entered" — an explicit "0" collapses to nil before it ever reaches prefillDraft,
        // the same convention FuelLogView already uses to filter "no price data" entries.
        let result = mixedBlendResult()

        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: nil, // what AtThePumpView computes for "0"
            enteredGasPricePerGallon: nil,
            stationE85PricePerGallon: 2.19
        )

        // Falls back to the station price exactly as the "nothing entered" case does —
        // an explicit 0 must not block a legitimate fallback, and must not itself be saved
        // as if it were a real $0.00/gal price.
        #expect(draft.e85PricePerGallon == 2.19)
    }

    // MARK: - Comma-decimal input (e.g. a Spanish-language keyboard on a U.S. iPhone) must
    // flow through FuelPriceInput end-to-end exactly like a dot-decimal entry

    @Test("A comma-decimal entered price, parsed by FuelPriceInput, still wins over a stale cached station price")
    func commaDecimalEnteredPrice_stillOverridesStaleStationPrice() {
        let result = mixedBlendResult()

        // "2,49" is what AtThePumpView.enteredPumpFillUpPrices would compute for a
        // comma-decimal keyboard entry — feed FuelPriceInput's output straight into
        // prefillDraft the same way AtThePumpView does.
        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: FuelPriceInput.parsePositiveAmount("2,49"),
            enteredGasPricePerGallon: FuelPriceInput.parsePositiveAmount("4,199"),
            stationE85PricePerGallon: 2.19 // stale cached price from a previously saved station
        )

        #expect(draft.e85PricePerGallon == 2.49)
        #expect(draft.gasPricePerGallon == 4.199)
    }

    @Test("A comma-decimal entered price and its dot-decimal equivalent persist identically")
    func commaAndDotDecimalEnteredPrices_persistIdentically() {
        let result = mixedBlendResult()

        let commaDraft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: FuelPriceInput.parsePositiveAmount("2,49"),
            enteredGasPricePerGallon: FuelPriceInput.parsePositiveAmount("4,19"),
            stationE85PricePerGallon: nil
        )
        let dotDraft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: FuelPriceInput.parsePositiveAmount("2.49"),
            enteredGasPricePerGallon: FuelPriceInput.parsePositiveAmount("4.19"),
            stationE85PricePerGallon: nil
        )

        #expect(commaDraft.e85PricePerGallon == dotDraft.e85PricePerGallon)
        #expect(commaDraft.gasPricePerGallon == dotDraft.gasPricePerGallon)
        #expect(abs(commaDraft.computedTotalCost - dotDraft.computedTotalCost) < 0.0001)
    }

    @Test("An Arabic-Indic/Persian-digit entered price, parsed by FuelPriceInput, still wins over a stale cached station price")
    func localizedDigitEnteredPrice_stillOverridesStaleStationPrice() {
        let result = mixedBlendResult()

        // "٢٫٤٩" (Arabic-Indic) and "۴٫۱۹۹" (Extended Arabic-Indic/Persian) are what
        // AtThePumpView.enteredPumpFillUpPrices would compute for an Arabic- or
        // Persian-language decimal-pad entry.
        let draft = FuelLogStore.prefillDraft(
            from: result,
            vehicle: nil,
            enteredE85PricePerGallon: FuelPriceInput.parsePositiveAmount("٢٫٤٩"),
            enteredGasPricePerGallon: FuelPriceInput.parsePositiveAmount("۴٫۱۹۹"),
            stationE85PricePerGallon: 2.19 // stale cached price from a previously saved station
        )

        #expect(draft.e85PricePerGallon == 2.49)
        #expect(draft.gasPricePerGallon == 4.199)
    }
}
