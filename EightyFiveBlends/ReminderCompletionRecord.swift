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

    // MARK: - Undo metadata (2.2.2+)
    //
    // Captured atomically, in RemindersView.completeReminder, before the completion mutates the
    // reminder — never derived or guessed after the fact. `reminderIdentifier` is the
    // authoritative signal that this record has real undo metadata: it defaults to "" (matching
    // MaintenanceReminder.reminderIdentifier's own empty-string "no stable identity" default),
    // so every completion record that predates this field loads with an empty identifier and is
    // correctly treated as a legacy, non-undoable record — see
    // ReminderCompletionUndo.hasUndoMetadata. The individual prior/resulting fields only carry
    // meaning once that gate is true; do not read them first.
    //
    // priorDueMileage/priorDueDate/resultingDueMileage/resultingDueDate are always populated
    // (never nil) for an undo-capable record — dueMileage/dueDate always hold a concrete value
    // on MaintenanceReminder regardless of whether mileage/date tracking is enabled, so they're
    // captured unconditionally. They are nil only for legacy records (reminderIdentifier is
    // empty). priorCompletedAt/priorCompletedMileage are nil when this was the reminder's
    // first-ever completion, which is a real, meaningful "no prior completion" state, not a gap.
    var reminderIdentifier: String = ""
    var priorDueMileage: Int?
    var priorDueDate: Date?
    var priorIsCompleted: Bool = false
    var priorCompletedAt: Date?
    var priorCompletedMileage: Int?
    var resultingDueMileage: Int?
    var resultingDueDate: Date?
    var resultingIsCompleted: Bool = false

    init(
        reminderTitle: String = "",
        vehicleName: String = "",
        category: String = "",
        completedAt: Date = .now,
        completedMileage: Int? = nil,
        notes: String? = nil,
        createdAt: Date = .now,
        reminderIdentifier: String = "",
        priorDueMileage: Int? = nil,
        priorDueDate: Date? = nil,
        priorIsCompleted: Bool = false,
        priorCompletedAt: Date? = nil,
        priorCompletedMileage: Int? = nil,
        resultingDueMileage: Int? = nil,
        resultingDueDate: Date? = nil,
        resultingIsCompleted: Bool = false
    ) {
        self.reminderTitle = reminderTitle
        self.vehicleName = vehicleName
        self.category = category
        self.completedAt = completedAt
        self.completedMileage = completedMileage
        self.notes = notes
        self.createdAt = createdAt
        self.reminderIdentifier = reminderIdentifier
        self.priorDueMileage = priorDueMileage
        self.priorDueDate = priorDueDate
        self.priorIsCompleted = priorIsCompleted
        self.priorCompletedAt = priorCompletedAt
        self.priorCompletedMileage = priorCompletedMileage
        self.resultingDueMileage = resultingDueMileage
        self.resultingDueDate = resultingDueDate
        self.resultingIsCompleted = resultingIsCompleted
    }
}

extension ReminderCompletionRecord {
    /// True only when this record was created by the current completeReminder pipeline and
    /// carries real prior/resulting state. Legacy records (created before this field existed)
    /// load with an empty reminderIdentifier and must never be treated as undo-capable.
    var hasUndoMetadata: Bool {
        reminderIdentifier.isEmpty == false
    }
}
