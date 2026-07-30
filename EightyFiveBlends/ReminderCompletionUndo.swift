//
//  ReminderCompletionUndo.swift
//  EightyFiveBlends
//
//  Pure decision logic for REM-P1-005A: safely undoing a reminder's most recent completion when
//  its history record is deleted. Kept independent of SwiftUI/SwiftData, mirroring
//  ReminderScheduling/VehicleActivation/VehicleOdometerPolicy's separation of pure rules from
//  the SwiftData-coupled views that call them.
//
//  This module never touches persistence and never sees a ReminderCompletionRecord or
//  MaintenanceReminder directly — RemindersView translates those into the plain values below,
//  which keeps the actual undo/no-undo decision provable and testable in isolation.
//

import Foundation

enum ReminderCompletionUndo {
    /// A comparable snapshot of one completion record's ordering identity, decoupled from
    /// SwiftData so "which record is latest" is a pure, testable decision.
    struct RecordSnapshot: Equatable {
        let completedAt: Date
        // Tiebreaker for identical completedAt values — the caller supplies a value that's
        // stable and unique per record (e.g. a description of its persistent identifier) so two
        // completions logged for the exact same date never produce an ambiguous "latest" choice.
        let tiebreaker: String

        init(completedAt: Date, tiebreaker: String) {
            self.completedAt = completedAt
            self.tiebreaker = tiebreaker
        }
    }

    /// The confirmation the deletion UI should show, and whether the deletion should also
    /// restore the owning reminder's prior state.
    enum DeletionClassification: Equatable {
        /// The safest, most common case: deleting the newest, undo-capable completion for its
        /// reminder. Restore the reminder from the record's captured prior state, then delete
        /// the record.
        case undoLatestCompletion
        /// Deleting a completion that is not the newest for its reminder. Remove only the
        /// history row — the current reminder schedule was set by a newer completion and must
        /// not be touched.
        case olderCompletion
        /// The newest completion for its reminder, but either it predates undo-metadata
        /// capture, or the reminder's current state no longer matches what this completion
        /// recorded (something else changed it since). Never guess — remove only the history
        /// row.
        case latestButNotUndoable
    }

    /// Sorts snapshots for the same reminder newest-first.
    static func sortedNewestFirst(_ records: [RecordSnapshot]) -> [RecordSnapshot] {
        records.sorted { lhs, rhs in
            if lhs.completedAt != rhs.completedAt {
                return lhs.completedAt > rhs.completedAt
            }
            return lhs.tiebreaker > rhs.tiebreaker
        }
    }

    /// True when `candidate` is the newest record among `allRecordsForReminder` — the only
    /// record ever eligible to trigger reminder-state undo.
    static func isLatest(_ candidate: RecordSnapshot, among allRecordsForReminder: [RecordSnapshot]) -> Bool {
        sortedNewestFirst(allRecordsForReminder).first == candidate
    }

    /// True when the reminder's current state exactly matches what this completion recorded as
    /// its result — the safety check that catches any edit or other event that changed the
    /// reminder since this completion, which would make blindly restoring `prior*` values wrong.
    /// `resultingDueMileage`/`resultingDueDate` are only checked when the corresponding tracking
    /// type is enabled, matching how completeReminder only ever touches those fields when the
    /// reminder tracks them.
    static func reminderMatchesRecordedResult(
        isCompleted: Bool,
        resultingIsCompleted: Bool,
        mileageEnabled: Bool,
        dueMileage: Int,
        resultingDueMileage: Int?,
        dateEnabled: Bool,
        dueDate: Date,
        resultingDueDate: Date?
    ) -> Bool {
        guard isCompleted == resultingIsCompleted else { return false }

        if mileageEnabled {
            guard let resultingDueMileage, resultingDueMileage == dueMileage else { return false }
        }

        if dateEnabled {
            guard let resultingDueDate, resultingDueDate == dueDate else { return false }
        }

        return true
    }

    /// The single authoritative decision: given whether the record being deleted is the latest
    /// for its reminder, whether it carries real undo metadata, and (only meaningful when both
    /// of those are true) whether the reminder's current state still matches what was recorded,
    /// decide what the deletion should do and how to describe it.
    static func classify(
        candidateIsLatest: Bool,
        candidateHasUndoMetadata: Bool,
        reminderStateMatchesRecordedResult: Bool
    ) -> DeletionClassification {
        guard candidateIsLatest else { return .olderCompletion }
        guard candidateHasUndoMetadata, reminderStateMatchesRecordedResult else { return .latestButNotUndoable }
        return .undoLatestCompletion
    }
}
