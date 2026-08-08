//
//  FuelPriceLookup.swift
//  EightyFiveBlends
//
//  Pure lookup behind Compare Fuel Cost's price auto-populate: the most recent valid price for a
//  given vehicle, extracted from an already-fetched, already-sorted-newest-first fuel log array.
//  Mirrors the exact idiom CalculatorView.lastLoggedBlendForActiveVehicle already uses
//  (fuelLogEntries.first(where:) over a @Query(sort: \FuelLogEntry.date, order: .reverse)) rather
//  than introducing a second way to find "the current vehicle's most recent relevant entry."
//  Read-only: never mutates the entries passed to it. See
//  EightyFiveBlendsTests/FuelPriceLookupTests.swift.
//

import Foundation

enum FuelPriceLookup {
    /// The most recent valid price for `vehicleName`, scanning `entries` in the order given.
    /// Callers are expected to pass entries already sorted newest-first — the first entry that
    /// both belongs to the vehicle and has a valid price wins, exactly like
    /// CalculatorView.lastLoggedBlendForActiveVehicle's own `.first(where:)`.
    ///
    /// "Valid" reuses StationDataValidation.isValidPrice — finite, greater than zero, and within
    /// a plausible per-gallon ceiling — the same bar station price entry already holds prices to,
    /// so a corrupted or placeholder 0 in a fuel log entry is never surfaced as a real price.
    static func mostRecentValidPrice(
        in entries: [FuelLogEntry],
        vehicleName: String,
        price: (FuelLogEntry) -> Double
    ) -> Double? {
        entries
            .first { entry in
                entry.vehicleName == vehicleName && StationDataValidation.isValidPrice(price(entry))
            }
            .map(price)
    }
}
