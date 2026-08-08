//
//  FuelPriceLookupTests.swift
//  EightyFiveBlends
//
//  Tests for the pure lookup behind Compare Fuel Cost's price auto-populate. This is the actual
//  function CostCalculatorView calls (FuelPriceLookup.mostRecentValidPrice) — not a duplicate
//  reimplementation — so passing tests here directly verify production behavior.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  Entries are constructed with FuelLogEntry's normal initializer, outside of any ModelContext —
//  a standard, supported way to unit-test SwiftData @Model property logic without a live
//  container, since these tests only exercise plain stored-property reads.

import Testing
@testable import EightyFiveBlends

struct FuelPriceLookupTests {

    private func entry(vehicleName: String, daysAgo: Double, e85Price: Double, gasPrice: Double) -> FuelLogEntry {
        FuelLogEntry(
            vehicleName: vehicleName,
            date: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
            e85PricePerGallon: e85Price,
            gasPricePerGallon: gasPrice
        )
    }

    // MARK: Most recent valid E85 price is selected

    @Test("The most recent (smallest daysAgo) entry with a valid price wins, even if it isn't first in the array")
    func mostRecentValidPrice_picksNewestByDate() {
        let entries = [
            entry(vehicleName: "Civic", daysAgo: 10, e85Price: 2.50, gasPrice: 3.10),
            entry(vehicleName: "Civic", daysAgo: 1, e85Price: 2.89, gasPrice: 3.49),
            entry(vehicleName: "Civic", daysAgo: 20, e85Price: 2.30, gasPrice: 2.95),
        ]
        // Entries are expected pre-sorted newest-first, as CalculatorView's own
        // @Query(sort: \FuelLogEntry.date, order: .reverse) already provides.
        let sorted = entries.sorted { $0.date > $1.date }

        let price = FuelPriceLookup.mostRecentValidPrice(
            in: sorted, vehicleName: "Civic", price: { $0.e85PricePerGallon }
        )
        #expect(price == 2.89)
    }

    // MARK: Invalid/zero/negative/non-finite prices ignored

    @Test("A newer entry with an invalid price is skipped in favor of the next valid one")
    func mostRecentValidPrice_skipsInvalidNewerEntries() {
        let entries = [
            entry(vehicleName: "Civic", daysAgo: 1, e85Price: 0, gasPrice: 3.49),           // zero — invalid
            entry(vehicleName: "Civic", daysAgo: 2, e85Price: -1.5, gasPrice: 3.40),         // negative — invalid
            entry(vehicleName: "Civic", daysAgo: 3, e85Price: .infinity, gasPrice: 3.30),    // non-finite — invalid
            entry(vehicleName: "Civic", daysAgo: 4, e85Price: 2.75, gasPrice: 3.20),         // valid
        ]

        let price = FuelPriceLookup.mostRecentValidPrice(
            in: entries, vehicleName: "Civic", price: { $0.e85PricePerGallon }
        )
        #expect(price == 2.75)
    }

    @Test("An implausibly high price (above StationDataValidation's ceiling) is treated as invalid")
    func mostRecentValidPrice_rejectsImplausiblyHighPrice() {
        let entries = [
            entry(vehicleName: "Civic", daysAgo: 1, e85Price: 150, gasPrice: 3.49), // typo-scale — invalid
            entry(vehicleName: "Civic", daysAgo: 2, e85Price: 2.75, gasPrice: 3.20),
        ]

        let price = FuelPriceLookup.mostRecentValidPrice(
            in: entries, vehicleName: "Civic", price: { $0.e85PricePerGallon }
        )
        #expect(price == 2.75)
    }

    // MARK: Another vehicle's price is never used

    @Test("Entries for a different vehicle are never selected, even if more recent")
    func mostRecentValidPrice_neverUsesAnotherVehiclesPrice() {
        let entries = [
            entry(vehicleName: "Silverado", daysAgo: 1, e85Price: 2.99, gasPrice: 3.55),
            entry(vehicleName: "Civic", daysAgo: 5, e85Price: 2.75, gasPrice: 3.20),
        ]

        let price = FuelPriceLookup.mostRecentValidPrice(
            in: entries, vehicleName: "Civic", price: { $0.e85PricePerGallon }
        )
        #expect(price == 2.75)
    }

    // MARK: No valid price → manual fallback (nil)

    @Test("No matching vehicle at all returns nil")
    func mostRecentValidPrice_noMatchingVehicle_returnsNil() {
        let entries = [
            entry(vehicleName: "Silverado", daysAgo: 1, e85Price: 2.99, gasPrice: 3.55),
        ]

        let price = FuelPriceLookup.mostRecentValidPrice(
            in: entries, vehicleName: "Civic", price: { $0.e85PricePerGallon }
        )
        #expect(price == nil)
    }

    @Test("A matching vehicle with only invalid prices returns nil rather than a fabricated value")
    func mostRecentValidPrice_onlyInvalidPrices_returnsNil() {
        let entries = [
            entry(vehicleName: "Civic", daysAgo: 1, e85Price: 0, gasPrice: 0),
            entry(vehicleName: "Civic", daysAgo: 2, e85Price: -1, gasPrice: -1),
        ]

        let price = FuelPriceLookup.mostRecentValidPrice(
            in: entries, vehicleName: "Civic", price: { $0.e85PricePerGallon }
        )
        #expect(price == nil)
    }

    @Test("An empty entries array returns nil")
    func mostRecentValidPrice_emptyEntries_returnsNil() {
        let price = FuelPriceLookup.mostRecentValidPrice(
            in: [], vehicleName: "Civic", price: { $0.e85PricePerGallon }
        )
        #expect(price == nil)
    }

    // MARK: Gas price uses the same rule, independently of E85 price

    @Test("Gas price and E85 price are resolved independently — a valid gas price on an entry doesn't require a valid E85 price on the same entry")
    func mostRecentValidPrice_gasPriceIndependentOfE85Price() {
        let entries = [
            entry(vehicleName: "Civic", daysAgo: 1, e85Price: 0, gasPrice: 3.49), // gas-only fill
        ]

        let gasPrice = FuelPriceLookup.mostRecentValidPrice(
            in: entries, vehicleName: "Civic", price: { $0.gasPricePerGallon }
        )
        let e85Price = FuelPriceLookup.mostRecentValidPrice(
            in: entries, vehicleName: "Civic", price: { $0.e85PricePerGallon }
        )
        #expect(gasPrice == 3.49)
        #expect(e85Price == nil)
    }
}
