//
//  FuelStation.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation
import SwiftData

@Model
final class FuelStation {
    var name: String
    var address: String
    var city: String
    var state: String
    var zipCode: String
    var latitude: Double?
    var longitude: Double?
    var lastKnownE85Price: Double
    var lastUpdated: Date
    var notes: String
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String = "",
        address: String = "",
        city: String = "",
        state: String = "",
        zipCode: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil,
        lastKnownE85Price: Double = 0,
        lastUpdated: Date = .now,
        notes: String = "",
        isFavorite: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.name = name
        self.address = address
        self.city = city
        self.state = state
        self.zipCode = zipCode
        self.latitude = latitude
        self.longitude = longitude
        self.lastKnownE85Price = lastKnownE85Price
        self.lastUpdated = lastUpdated
        self.notes = notes
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
