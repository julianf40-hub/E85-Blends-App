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
    // Inline defaults on every non-optional attribute let the CloudKit-backed SwiftData
    // container validate. completedMileage/notes stay optional. Values match the init
    // defaults, so existing completion-history data migrates without loss.
    var reminderTitle: String = ""
    var vehicleName: String = ""
    var category: String = ""
    var completedAt: Date = Date.now
    var completedMileage: Int?
    var notes: String?
    var createdAt: Date = Date.now

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
