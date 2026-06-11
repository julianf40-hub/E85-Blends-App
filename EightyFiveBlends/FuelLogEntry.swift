//
//  FuelLogEntry.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation
import SwiftData

@Model
final class FuelLogEntry {
    var vehicleName: String
    var date: Date
    var stationName: String
    var odometer: Int
    var targetBlendPercent: Double
    var finalBlendPercent: Double
    var gallonsAdded: Double
    var e85Gallons: Double
    var gasGallons: Double
    var e85PricePerGallon: Double
    var gasPricePerGallon: Double
    var totalCost: Double
    var mpg: Double
    var notes: String

    init(
        vehicleName: String = "",
        date: Date = .now,
        stationName: String = "",
        odometer: Int = 0,
        targetBlendPercent: Double = 30,
        finalBlendPercent: Double = 0,
        gallonsAdded: Double = 0,
        e85Gallons: Double = 0,
        gasGallons: Double = 0,
        e85PricePerGallon: Double = 0,
        gasPricePerGallon: Double = 0,
        totalCost: Double = 0,
        mpg: Double = 0,
        notes: String = ""
    ) {
        self.vehicleName = vehicleName
        self.date = date
        self.stationName = stationName
        self.odometer = odometer
        self.targetBlendPercent = targetBlendPercent
        self.finalBlendPercent = finalBlendPercent
        self.gallonsAdded = gallonsAdded
        self.e85Gallons = e85Gallons
        self.gasGallons = gasGallons
        self.e85PricePerGallon = e85PricePerGallon
        self.gasPricePerGallon = gasPricePerGallon
        self.totalCost = totalCost
        self.mpg = mpg
        self.notes = notes
    }
}
