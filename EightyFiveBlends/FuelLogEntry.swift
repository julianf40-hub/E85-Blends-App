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
    // Inline defaults on every (non-optional) attribute are required for the CloudKit-backed
    // SwiftData container to validate its schema. Values match the init defaults, so the
    // stored shape is unchanged and existing fuel-log data migrates without loss.
    var vehicleName: String = ""
    var date: Date = Date.now
    var stationName: String = ""
    var odometer: Int = 0
    var targetBlendPercent: Double = 30
    var finalBlendPercent: Double = 0
    var gallonsAdded: Double = 0
    var e85Gallons: Double = 0
    var gasGallons: Double = 0
    var e85PricePerGallon: Double = 0
    var gasPricePerGallon: Double = 0
    var totalCost: Double = 0
    var mpg: Double = 0
    var notes: String = ""

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
