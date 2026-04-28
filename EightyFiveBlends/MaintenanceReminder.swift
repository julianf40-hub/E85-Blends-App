//
//  MaintenanceReminder.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation
import SwiftData

@Model
final class MaintenanceReminder {
    var vehicleName: String
    var title: String
    var category: String
    var mileageEnabled: Bool
    var dueMileage: Int
    var repeatMileageInterval: Int
    var dateEnabled: Bool
    var dueDate: Date
    var repeatDateIntervalDays: Int
    var notes: String
    var isCompleted: Bool
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        vehicleName: String = "",
        title: String = "",
        category: String = "",
        mileageEnabled: Bool = false,
        dueMileage: Int = 0,
        repeatMileageInterval: Int = 0,
        dateEnabled: Bool = false,
        dueDate: Date = .now,
        repeatDateIntervalDays: Int = 0,
        notes: String = "",
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.vehicleName = vehicleName
        self.title = title
        self.category = category
        self.mileageEnabled = mileageEnabled
        self.dueMileage = dueMileage
        self.repeatMileageInterval = repeatMileageInterval
        self.dateEnabled = dateEnabled
        self.dueDate = dueDate
        self.repeatDateIntervalDays = repeatDateIntervalDays
        self.notes = notes
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
