//
//  FuelAnalyticsEngineTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure fuel analytics engine: totals, mileage-dependent metrics, filtering,
//  trends, and empty/partial-data handling.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct FuelAnalyticsEngineTests {

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ isoString: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = utcCalendar()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: isoString)!
    }

    // MARK: - Empty state

    @Test("An empty fuel log produces zero totals and nil averages, never fabricated numbers")
    func emptyLog_producesNilAveragesNotFabricatedZeros() {
        let entries: [FuelLogEntry] = []
        #expect(FuelAnalyticsEngine.totalSpending(entries) == 0)
        #expect(FuelAnalyticsEngine.totalGallons(entries) == 0)
        #expect(FuelAnalyticsEngine.fillUpCount(entries) == 0)
        #expect(FuelAnalyticsEngine.averagePricePerGallon(entries) == nil)
        #expect(FuelAnalyticsEngine.averageEthanolContent(entries) == nil)
        #expect(FuelAnalyticsEngine.averageGallonsPerFillUp(entries) == nil)
        #expect(FuelAnalyticsEngine.totalMilesDriven(entries) == 0)
        #expect(FuelAnalyticsEngine.costPerMile(entries) == nil)
        #expect(FuelAnalyticsEngine.averageLoggedMPG(entries) == nil)
        #expect(FuelAnalyticsEngine.trends(entries, groupedBy: .month).isEmpty)
    }

    // MARK: - Basic totals

    @Test("Totals and averages are computed correctly across several entries")
    func basicTotals_computeCorrectly() {
        let entries = [
            FuelLogEntry(vehicleName: "Civic", finalBlendPercent: 30, gallonsAdded: 10, totalCost: 30),
            FuelLogEntry(vehicleName: "Civic", finalBlendPercent: 50, gallonsAdded: 8, totalCost: 40),
        ]

        #expect(FuelAnalyticsEngine.totalSpending(entries) == 70)
        #expect(FuelAnalyticsEngine.totalGallons(entries) == 18)
        #expect(FuelAnalyticsEngine.fillUpCount(entries) == 2)
        #expect(abs(FuelAnalyticsEngine.averagePricePerGallon(entries)! - (70.0 / 18.0)) < 0.0001)
        #expect(FuelAnalyticsEngine.averageEthanolContent(entries) == 40)
        #expect(FuelAnalyticsEngine.averageGallonsPerFillUp(entries) == 9)
    }

    @Test("Average price per gallon is nil when total gallons is zero despite having entries")
    func averagePricePerGallon_zeroGallons_isNil() {
        let entries = [FuelLogEntry(vehicleName: "Civic", gallonsAdded: 0, totalCost: 0)]
        #expect(FuelAnalyticsEngine.averagePricePerGallon(entries) == nil)
    }

    // MARK: - Mileage-dependent metrics

    @Test("Cost per mile is computed from the odometer spread when mileage data exists")
    func costPerMile_withValidMileage_computesCorrectly() {
        let entries = [
            FuelLogEntry(vehicleName: "Civic", odometer: 1000, totalCost: 30),
            FuelLogEntry(vehicleName: "Civic", odometer: 1300, totalCost: 40),
        ]
        #expect(FuelAnalyticsEngine.totalMilesDriven(entries) == 300)
        #expect(abs(FuelAnalyticsEngine.costPerMile(entries)! - (70.0 / 300.0)) < 0.0001)
    }

    @Test("Cost per mile is nil, not fabricated, when there's only a single odometer reading")
    func costPerMile_singleEntry_isNil() {
        let entries = [FuelLogEntry(vehicleName: "Civic", odometer: 1000, totalCost: 30)]
        #expect(FuelAnalyticsEngine.totalMilesDriven(entries) == 0)
        #expect(FuelAnalyticsEngine.costPerMile(entries) == nil)
    }

    @Test("Cost per mile is nil when all odometer readings for a vehicle are identical")
    func costPerMile_noOdometerSpread_isNil() {
        let entries = [
            FuelLogEntry(vehicleName: "Civic", odometer: 1000, totalCost: 30),
            FuelLogEntry(vehicleName: "Civic", odometer: 1000, totalCost: 30),
        ]
        #expect(FuelAnalyticsEngine.costPerMile(entries) == nil)
    }

    @Test("Mileage totals across two vehicles are summed independently, not cross-contaminated")
    func totalMilesDriven_multipleVehicles_summedIndependently() {
        let entries = [
            FuelLogEntry(vehicleName: "Civic", odometer: 1000, totalCost: 10),
            FuelLogEntry(vehicleName: "Civic", odometer: 1200, totalCost: 10),
            FuelLogEntry(vehicleName: "Truck", odometer: 50000, totalCost: 10),
            FuelLogEntry(vehicleName: "Truck", odometer: 50500, totalCost: 10),
        ]
        #expect(FuelAnalyticsEngine.totalMilesDriven(entries) == 700)
    }

    @Test("Average logged MPG ignores entries with no usable MPG value rather than averaging in zeros")
    func averageLoggedMPG_ignoresZeroEntries() {
        let entries = [
            FuelLogEntry(vehicleName: "Civic", mpg: 0),
            FuelLogEntry(vehicleName: "Civic", mpg: 30),
            FuelLogEntry(vehicleName: "Civic", mpg: 32),
        ]
        #expect(FuelAnalyticsEngine.averageLoggedMPG(entries) == 31)
    }

    @Test("Average logged MPG is nil when no entry has a usable MPG value")
    func averageLoggedMPG_allZero_isNil() {
        let entries = [
            FuelLogEntry(vehicleName: "Civic", mpg: 0),
            FuelLogEntry(vehicleName: "Civic", mpg: 0),
        ]
        #expect(FuelAnalyticsEngine.averageLoggedMPG(entries) == nil)
    }

    // MARK: - Filtering

    @Test("Filtering by vehicle returns only that vehicle's entries")
    func entriesForVehicle_filtersCorrectly() {
        let entries = [
            FuelLogEntry(vehicleName: "Civic", totalCost: 10),
            FuelLogEntry(vehicleName: "Truck", totalCost: 20),
            FuelLogEntry(vehicleName: "Civic", totalCost: 15),
        ]
        let civicOnly = FuelAnalyticsEngine.entries(entries, forVehicle: "Civic")
        #expect(civicOnly.count == 2)
        #expect(FuelAnalyticsEngine.totalSpending(civicOnly) == 25)
    }

    @Test("Filtering by date range excludes entries outside the range")
    func entriesInRange_filtersCorrectly() {
        let inRange = FuelLogEntry(vehicleName: "Civic", date: date("2026-06-15 00:00:00"), totalCost: 10)
        let beforeRange = FuelLogEntry(vehicleName: "Civic", date: date("2026-01-01 00:00:00"), totalCost: 20)
        let afterRange = FuelLogEntry(vehicleName: "Civic", date: date("2026-12-31 00:00:00"), totalCost: 30)
        let entries = [inRange, beforeRange, afterRange]

        let range = date("2026-06-01 00:00:00")...date("2026-06-30 00:00:00")
        let filtered = FuelAnalyticsEngine.entries(entries, in: range)
        #expect(filtered.count == 1)
        #expect(FuelAnalyticsEngine.totalSpending(filtered) == 10)
    }

    // MARK: - Trends

    @Test("Trends grouped by month bucket entries into the correct calendar months")
    func trends_groupedByMonth_bucketsCorrectly() {
        let entries = [
            FuelLogEntry(vehicleName: "Civic", date: date("2026-01-05 00:00:00"), finalBlendPercent: 20, gallonsAdded: 10, totalCost: 30),
            FuelLogEntry(vehicleName: "Civic", date: date("2026-01-20 00:00:00"), finalBlendPercent: 40, gallonsAdded: 5, totalCost: 20),
            FuelLogEntry(vehicleName: "Civic", date: date("2026-02-10 00:00:00"), finalBlendPercent: 30, gallonsAdded: 8, totalCost: 25),
        ]

        let monthly = FuelAnalyticsEngine.trends(entries, groupedBy: .month, calendar: utcCalendar())
        #expect(monthly.count == 2)

        let january = monthly[0]
        #expect(january.fillUpCount == 2)
        #expect(january.totalSpending == 50)
        #expect(january.totalGallons == 15)
        #expect(january.averageEthanolContent == 30)

        let february = monthly[1]
        #expect(february.fillUpCount == 1)
        #expect(february.totalSpending == 25)
    }

    @Test("Trends grouped by week separate entries in different calendar weeks")
    func trends_groupedByWeek_bucketsCorrectly() {
        let entries = [
            FuelLogEntry(vehicleName: "Civic", date: date("2026-01-05 00:00:00"), gallonsAdded: 10, totalCost: 30),
            FuelLogEntry(vehicleName: "Civic", date: date("2026-01-19 00:00:00"), gallonsAdded: 5, totalCost: 20),
        ]

        let weekly = FuelAnalyticsEngine.trends(entries, groupedBy: .week, calendar: utcCalendar())
        #expect(weekly.count == 2)
    }

    @Test("Trends are sorted chronologically regardless of input order")
    func trends_sortedChronologically() {
        let entries = [
            FuelLogEntry(vehicleName: "Civic", date: date("2026-03-10 00:00:00"), totalCost: 10),
            FuelLogEntry(vehicleName: "Civic", date: date("2026-01-10 00:00:00"), totalCost: 10),
            FuelLogEntry(vehicleName: "Civic", date: date("2026-02-10 00:00:00"), totalCost: 10),
        ]

        let monthly = FuelAnalyticsEngine.trends(entries, groupedBy: .month, calendar: utcCalendar())
        #expect(monthly.count == 3)
        #expect(monthly[0].periodStart < monthly[1].periodStart)
        #expect(monthly[1].periodStart < monthly[2].periodStart)
    }
}
