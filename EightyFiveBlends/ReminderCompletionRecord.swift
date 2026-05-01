//
//  ReminderCompletionRecord.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation
import SwiftData

@Model
final class ReminderCompletionRecord {
    var reminderTitle: String
    var vehicleName: String
    var category: String
    var completedAt: Date
    var completedMileage: Int?
    var notes: String?
    var createdAt: Date

    init(
        reminderTitle: String = "",
        vehicleName: String = "",
        category: String = "",
        completedAt: Date = .now,
        completedMileage: Int? = nil,
        notes: String? = nil,
        createdAt: Date = .now
    ) {
        self.reminderTitle = reminderTitle
        self.vehicleName = vehicleName
        self.category = category
        self.completedAt = completedAt
        self.completedMileage = completedMileage
        self.notes = notes
        self.createdAt = createdAt
    }
}
