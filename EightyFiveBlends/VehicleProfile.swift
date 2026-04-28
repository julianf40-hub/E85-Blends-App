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
    var nickname: String
    var year: String
    var make: String
    var model: String
    var trim: String
    var tankSizeGallons: Double
    var currentOdometer: Int
    var defaultTargetEthanolPercent: Double
    var defaultCurrentEthanolPercent: Double
    var defaultPumpEthanolPercent: Double
    var gasEthanolPercent: Double
    var requiredOctane: Double
    var isFlexFuel: Bool
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        nickname: String = "",
        year: String = "",
        make: String = "",
        model: String = "",
        trim: String = "",
        tankSizeGallons: Double = 0,
        currentOdometer: Int = 0,
        defaultTargetEthanolPercent: Double = 85,
        defaultCurrentEthanolPercent: Double = 10,
        defaultPumpEthanolPercent: Double = 85,
        gasEthanolPercent: Double = 10,
        requiredOctane: Double = 91,
        isFlexFuel: Bool = false,
        isActive: Bool = false,
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
