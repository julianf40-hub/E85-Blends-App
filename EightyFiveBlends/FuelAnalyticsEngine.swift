//
//  FuelAnalyticsEngine.swift
//  EightyFiveBlends
//
//  Pure, SwiftUI-independent fuel-log analytics. Foundation for the "Advanced Fuel Analytics"
//  Pro feature (currently a placeholder shell in AdvancedAnalyticsView) — not yet wired into
//  any UI. Every metric that depends on odometer/mileage history returns nil rather than a
//  fabricated number when the underlying data is too thin to support it.
//

import Foundation

enum FuelAnalyticsEngine {

    // MARK: - Basic totals

    static func totalSpending(_ entries: [FuelLogEntry]) -> Double {
        entries.reduce(0) { $0 + $1.totalCost }
    }

    static func totalGallons(_ entries: [FuelLogEntry]) -> Double {
        entries.reduce(0) { $0 + $1.gallonsAdded }
    }

    static func fillUpCount(_ entries: [FuelLogEntry]) -> Int {
        entries.count
    }

    /// nil when there are no gallons logged yet, rather than a division-by-zero 0.
    static func averagePricePerGallon(_ entries: [FuelLogEntry]) -> Double? {
        let gallons = totalGallons(entries)
        guard gallons > 0 else { return nil }
        return totalSpending(entries) / gallons
    }

    static func averageEthanolContent(_ entries: [FuelLogEntry]) -> Double? {
        guard entries.isEmpty == false else { return nil }
        return entries.reduce(0) { $0 + $1.finalBlendPercent } / Double(entries.count)
    }

    static func averageGallonsPerFillUp(_ entries: [FuelLogEntry]) -> Double? {
        guard entries.isEmpty == false else { return nil }
        return totalGallons(entries) / Double(entries.count)
    }

    // MARK: - Mileage-dependent metrics

    /// Total miles driven across fill-ups, computed per vehicle from the spread between the
    /// lowest and highest recorded odometer reading, then summed across vehicles. A vehicle
    /// with fewer than two usable odometer readings contributes zero miles rather than a guess.
    static func totalMilesDriven(_ entries: [FuelLogEntry]) -> Int {
        let vehicleGroups = Dictionary(grouping: entries.filter { $0.odometer > 0 }, by: \.vehicleName)
        var totalMiles = 0
        for (_, vehicleEntries) in vehicleGroups {
            let odometers = vehicleEntries.map(\.odometer)
            if let maxOdo = odometers.max(), let minOdo = odometers.min(), maxOdo > minOdo {
                totalMiles += maxOdo - minOdo
            }
        }
        return totalMiles
    }

    /// Cost per mile across all fill-ups. Returned only when there's both real spending and
    /// real recorded mileage — nil (never a fabricated figure) when odometer history is too
    /// thin to establish a distance.
    static func costPerMile(_ entries: [FuelLogEntry]) -> Double? {
        let miles = totalMilesDriven(entries)
        let spending = totalSpending(entries)
        guard miles > 0, spending > 0 else { return nil }
        return spending / Double(miles)
    }

    /// Average of each entry's own logged/estimated MPG (entries with a positive `mpg` only).
    /// nil when no entry has usable MPG data, never a fabricated 0.
    static func averageLoggedMPG(_ entries: [FuelLogEntry]) -> Double? {
        let valid = entries.filter { $0.mpg > 0 }
        guard valid.isEmpty == false else { return nil }
        return valid.reduce(0) { $0 + $1.mpg } / Double(valid.count)
    }

    // MARK: - Filtering

    static func entries(_ entries: [FuelLogEntry], forVehicle vehicleName: String) -> [FuelLogEntry] {
        entries.filter { $0.vehicleName == vehicleName }
    }

    static func entries(_ entries: [FuelLogEntry], in range: ClosedRange<Date>) -> [FuelLogEntry] {
        entries.filter { range.contains($0.date) }
    }

    // MARK: - Trends

    enum TrendPeriod {
        case week
        case month
    }

    struct PeriodTotals {
        let periodStart: Date
        let totalSpending: Double
        let totalGallons: Double
        let fillUpCount: Int
        let averageEthanolContent: Double?
    }

    /// Groups entries into calendar week- or month-aligned buckets and totals each bucket.
    /// Sorted chronologically. An entry whose period start can't be resolved by the calendar
    /// is excluded rather than silently merged into the wrong bucket (should not occur for any
    /// valid `Date`, but this keeps the function total rather than force-unwrapping).
    static func trends(
        _ entries: [FuelLogEntry],
        groupedBy period: TrendPeriod,
        calendar: Calendar = .current
    ) -> [PeriodTotals] {
        let components: Set<Calendar.Component> = period == .week
            ? [.yearForWeekOfYear, .weekOfYear]
            : [.year, .month]

        let grouped = Dictionary(grouping: entries) { entry -> Date? in
            calendar.date(from: calendar.dateComponents(components, from: entry.date))
        }

        return grouped.compactMap { periodStart, periodEntries -> PeriodTotals? in
            guard let periodStart else { return nil }
            return PeriodTotals(
                periodStart: periodStart,
                totalSpending: totalSpending(periodEntries),
                totalGallons: totalGallons(periodEntries),
                fillUpCount: periodEntries.count,
                averageEthanolContent: averageEthanolContent(periodEntries)
            )
        }
        .sorted { $0.periodStart < $1.periodStart }
    }
}
