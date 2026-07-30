//
//  ReminderCompletionUndoTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rules behind REM-P1-005A: whether deleting a
//  ReminderCompletionRecord should undo its reminder's completion, and what confirmation
//  copy/behavior that implies. These functions (ReminderCompletionUndo.isLatest,
//  reminderMatchesRecordedResult, classify) are exactly what RemindersView.
//  beginCompletionRecordDeletion calls — not a duplicate reimplementation — so passing tests
//  here directly verify production behavior for the parts of this feature that are pure.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  Honest coverage gaps — these require a live SwiftData ModelContext (an in-memory
//  ModelContainer, or better, real device testing) and cannot be proven by a pure unit test:
//   - Scenarios 1/2/3 (restoring dueMileage/dueDate/completedAt/completedMileage, and deleting
//     only the selected record): the actual field assignments happen in RemindersView.
//     confirmCompletionRecordDeletion against live MaintenanceReminder/ReminderCompletionRecord
//     SwiftData objects. This file proves the *decision* (classify returns .undoLatestCompletion)
//     is correct for the right inputs; it cannot prove the *mutation* that follows is applied
//     correctly, since that's SwiftData orchestration, not a pure function.
//   - Scenario 7 (duplicate titles/vehicle names): owningReminder(for:)/completionRecords(for:)
//     resolve records to reminders using live @Query arrays, which can't be constructed here.
//     What IS proven here is the safety property that actually protects this scenario: classify
//     never returns .undoLatestCompletion when candidateHasUndoMetadata is false — see
//     classify_neverUndoesWithoutMetadata_regardlessOfOtherInputs below — which is what stops an
//     ambiguous legacy match from ever triggering an automatic undo, independent of how (im)
//     precisely a duplicate-titled reminder's records get matched.
//   - Scenario 9 (odometer never lowered by undo): a static code fact, not a decision this
//     module makes — confirmCompletionRecordDeletion's restoration branch never writes
//     VehicleProfile.currentOdometer at all, verified directly by reading that function, not by
//     a test.
//   - Scenario 10 (legacy records without the new fields load safely): requires either a real
//     pre-migration SQLite store or a SwiftData integration test; the mechanism (every new field
//     has an inline default, per MaintenanceReminder.reminderIdentifier = "" and
//     ReminderCompletionRecord's nine new fields) is a model-declaration fact, not a pure-logic
//     one.

import Foundation
import Testing
@testable import EightyFiveBlends

struct ReminderCompletionUndoTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(secondsAgo: TimeInterval, tiebreaker: String = "a") -> ReminderCompletionUndo.RecordSnapshot {
        ReminderCompletionUndo.RecordSnapshot(completedAt: now.addingTimeInterval(-secondsAgo), tiebreaker: tiebreaker)
    }

    // MARK: - sortedNewestFirst / isLatest

    @Test("Records sort newest completedAt first")
    func sortedNewestFirst_ordersByCompletedAtDescending() {
        let oldest = snapshot(secondsAgo: 200)
        let middle = snapshot(secondsAgo: 100)
        let newest = snapshot(secondsAgo: 0)
        let sorted = ReminderCompletionUndo.sortedNewestFirst([middle, oldest, newest])
        #expect(sorted == [newest, middle, oldest])
    }

    @Test("The single newest record is identified as latest among several (Scenario 5: multiple completions)")
    func isLatest_multipleCompletions_identifiesNewest() {
        let completion1 = snapshot(secondsAgo: 200, tiebreaker: "completion-1")
        let completion2 = snapshot(secondsAgo: 100, tiebreaker: "completion-2")
        let completion3 = snapshot(secondsAgo: 0, tiebreaker: "completion-3")
        let all = [completion1, completion2, completion3]

        #expect(ReminderCompletionUndo.isLatest(completion3, among: all))
        #expect(ReminderCompletionUndo.isLatest(completion2, among: all) == false)
        #expect(ReminderCompletionUndo.isLatest(completion1, among: all) == false)
    }

    @Test("An older record is never latest when a newer one exists (Scenario 4: older completion deletion)")
    func isLatest_olderRecord_isNeverLatest() {
        let older = snapshot(secondsAgo: 500)
        let newer = snapshot(secondsAgo: 0)
        #expect(ReminderCompletionUndo.isLatest(older, among: [older, newer]) == false)
    }

    @Test("Identical completedAt values are resolved deterministically by the tiebreaker (Scenario 8)")
    func isLatest_identicalTimestamps_usesTiebreakerDeterministically() {
        let recordA = snapshot(secondsAgo: 0, tiebreaker: "aaa-earlier-insert")
        let recordB = snapshot(secondsAgo: 0, tiebreaker: "zzz-later-insert")

        // The higher tiebreaker wins — deterministic and consistent regardless of input order.
        #expect(ReminderCompletionUndo.isLatest(recordB, among: [recordA, recordB]))
        #expect(ReminderCompletionUndo.isLatest(recordB, among: [recordB, recordA]))
        #expect(ReminderCompletionUndo.isLatest(recordA, among: [recordA, recordB]) == false)
    }

    // MARK: - reminderMatchesRecordedResult

    @Test("Reminder state matching its recorded result is confirmed for a mileage+date reminder")
    func reminderMatchesRecordedResult_exactMatch_isTrue() {
        let result = ReminderCompletionUndo.reminderMatchesRecordedResult(
            isCompleted: false,
            resultingIsCompleted: false,
            mileageEnabled: true,
            dueMileage: 179023,
            resultingDueMileage: 179023,
            dateEnabled: false,
            dueDate: now,
            resultingDueDate: nil
        )
        #expect(result)
    }

    @Test("A reminder whose due mileage has diverged from the recorded result does not match")
    func reminderMatchesRecordedResult_divergedDueMileage_isFalse() {
        let result = ReminderCompletionUndo.reminderMatchesRecordedResult(
            isCompleted: false,
            resultingIsCompleted: false,
            mileageEnabled: true,
            dueMileage: 180000, // manually edited since the completion that produced 179023
            resultingDueMileage: 179023,
            dateEnabled: false,
            dueDate: now,
            resultingDueDate: nil
        )
        #expect(result == false)
    }

    @Test("A reminder whose isCompleted has diverged from the recorded result does not match")
    func reminderMatchesRecordedResult_divergedIsCompleted_isFalse() {
        let result = ReminderCompletionUndo.reminderMatchesRecordedResult(
            isCompleted: true,
            resultingIsCompleted: false,
            mileageEnabled: false,
            dueMileage: 0,
            resultingDueMileage: nil,
            dateEnabled: false,
            dueDate: now,
            resultingDueDate: nil
        )
        #expect(result == false)
    }

    @Test("Due-date divergence is ignored when date tracking is disabled")
    func reminderMatchesRecordedResult_dateDivergenceIgnoredWhenDisabled() {
        let result = ReminderCompletionUndo.reminderMatchesRecordedResult(
            isCompleted: false,
            resultingIsCompleted: false,
            mileageEnabled: true,
            dueMileage: 179023,
            resultingDueMileage: 179023,
            dateEnabled: false,
            dueDate: now.addingTimeInterval(999_999), // wildly different, but not tracked
            resultingDueDate: now
        )
        #expect(result)
    }

    @Test("A missing resulting value for an enabled tracking type does not match (legacy-style nil)")
    func reminderMatchesRecordedResult_missingResultingValueForEnabledType_isFalse() {
        let result = ReminderCompletionUndo.reminderMatchesRecordedResult(
            isCompleted: false,
            resultingIsCompleted: false,
            mileageEnabled: true,
            dueMileage: 179023,
            resultingDueMileage: nil,
            dateEnabled: false,
            dueDate: now,
            resultingDueDate: nil
        )
        #expect(result == false)
    }

    // MARK: - classify

    @Test("Latest, undo-capable, matching-state record classifies as undoLatestCompletion (Scenarios 1/3)")
    func classify_latestUndoCapableMatching_isUndoLatestCompletion() {
        let classification = ReminderCompletionUndo.classify(
            candidateIsLatest: true,
            candidateHasUndoMetadata: true,
            reminderStateMatchesRecordedResult: true
        )
        #expect(classification == .undoLatestCompletion)
    }

    @Test("A non-latest record classifies as olderCompletion regardless of metadata (Scenario 4)")
    func classify_notLatest_isOlderCompletion() {
        #expect(ReminderCompletionUndo.classify(candidateIsLatest: false, candidateHasUndoMetadata: true, reminderStateMatchesRecordedResult: true) == .olderCompletion)
        #expect(ReminderCompletionUndo.classify(candidateIsLatest: false, candidateHasUndoMetadata: false, reminderStateMatchesRecordedResult: false) == .olderCompletion)
    }

    @Test("A latest record without undo metadata classifies as latestButNotUndoable (Scenario 6: legacy record)")
    func classify_latestWithoutMetadata_isLatestButNotUndoable() {
        let classification = ReminderCompletionUndo.classify(
            candidateIsLatest: true,
            candidateHasUndoMetadata: false,
            reminderStateMatchesRecordedResult: false
        )
        #expect(classification == .latestButNotUndoable)
    }

    @Test("A latest, undo-capable record whose reminder state has diverged classifies as latestButNotUndoable")
    func classify_latestWithMetadataButDivergedState_isLatestButNotUndoable() {
        let classification = ReminderCompletionUndo.classify(
            candidateIsLatest: true,
            candidateHasUndoMetadata: true,
            reminderStateMatchesRecordedResult: false
        )
        #expect(classification == .latestButNotUndoable)
    }

    @Test("classify never returns undoLatestCompletion without undo metadata, regardless of other inputs (Scenario 7 safety property)")
    func classify_neverUndoesWithoutMetadata_regardlessOfOtherInputs() {
        for isLatest in [true, false] {
            for stateMatches in [true, false] {
                let classification = ReminderCompletionUndo.classify(
                    candidateIsLatest: isLatest,
                    candidateHasUndoMetadata: false,
                    reminderStateMatchesRecordedResult: stateMatches
                )
                #expect(classification != .undoLatestCompletion)
            }
        }
    }
}
