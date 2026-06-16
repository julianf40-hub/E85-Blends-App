//
//  VehicleProfile.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation
import SwiftData

@Model
final class VehicleProfile {
    // Every non-optional attribute carries an inline default value. SwiftData's CloudKit
    // schema generation requires each attribute to be optional OR have a default at the
    // property declaration (init defaults are not enough), so these defaults are what let
    // the CloudKit-backed container initialize. The values mirror the init defaults exactly,
    // so the stored shape is unchanged and existing data migrates cleanly.
    var nickname: String = ""
    var year: String = ""
    var make: String = ""
    var model: String = ""
    var trim: String = ""
    var tankSizeGallons: Double = 0
    var currentOdometer: Int = 0
    var defaultTargetEthanolPercent: Double = 30
    var defaultCurrentEthanolPercent: Double = 10
    var defaultPumpEthanolPercent: Double = 85
    var gasEthanolPercent: Double = 10
    var requiredOctane: Double = 91
    var isFlexFuel: Bool = false
    var isActive: Bool = false
    @Attribute(.externalStorage)
    var vehiclePhotoData: Data?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        nickname: String = "",
        year: String = "",
        make: String = "",
        model: String = "",
        trim: String = "",
        tankSizeGallons: Double = 0,
        currentOdometer: Int = 0,
        defaultTargetEthanolPercent: Double = 30,
        defaultCurrentEthanolPercent: Double = 10,
        defaultPumpEthanolPercent: Double = 85,
        gasEthanolPercent: Double = 10,
        requiredOctane: Double = 91,
        isFlexFuel: Bool = false,
        isActive: Bool = false,
        vehiclePhotoData: Data? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.nickname = nickname
        self.year = year
        self.make = make
        self.model = model
        self.trim = trim
        self.tankSizeGallons = tankSizeGallons
        self.currentOdometer = currentOdometer
        self.defaultTargetEthanolPercent = defaultTargetEthanolPercent
        self.defaultCurrentEthanolPercent = defaultCurrentEthanolPercent
        self.defaultPumpEthanolPercent = defaultPumpEthanolPercent
        self.gasEthanolPercent = gasEthanolPercent
        self.requiredOctane = requiredOctane
        self.isFlexFuel = isFlexFuel
        self.isActive = isActive
        self.vehiclePhotoData = vehiclePhotoData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
