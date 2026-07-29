//
//  ReminderScheduling.swift
//  EightyFiveBlends
//
//  Centralized, pure date math for maintenance reminders: overdue/remaining-day
//  calculations and recurrence advancement. Kept independent of SwiftUI/SwiftData (and with
//  an injectable Calendar) so it can be unit tested directly across time zones and DST
//  transitions, and so this day math no longer has to be reimplemented at each call site.
//

import Foundation

enum ReminderScheduling {
    /// True when `dueDate`'s calendar day is strictly before `asOf`'s calendar day.
    static func isOverdue(dueDate: Date, asOf: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: dueDate) < calendar.startOfDay(for: asOf)
    }

    /// Whole calendar days between two dates (`to` minus `from`), compared by calendar day
    /// rather than elapsed clock time. Both dates are normalized to the start of their
    /// calendar day first, so the result depends only on which calendar dates are involved —
    /// not on what time of day either falls at, and not on what time of day this is called.
    /// Can be negative when `to`'s calendar day is earlier than `from`'s — callers that only
    /// want a non-negative count should clamp the result themselves, matching how each call
    /// site already used this before centralizing.
    static func wholeDays(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: fromDay, to: toDay).day ?? 0
    }

    /// The next due date after completing a recurring reminder. A non-positive interval means
    /// the reminder does not repeat by date, so this returns nil rather than looping the same
    /// due date forever or advancing in the wrong direction.
    static func nextDueDate(
        afterCompleting completionDate: Date,
        repeatIntervalDays: Int,
        calendar: Calendar = .current
    ) -> Date? {
        guard repeatIntervalDays > 0 else { return nil }
        return calendar.date(byAdding: .day, value: repeatIntervalDays, to: completionDate)
    }

    /// Parses and validates a completion-mileage text field entry. Rejects empty, non-numeric,
    /// malformed/NaN, zero, negative, and out-of-range (overflow) input. Deliberately does NOT
    /// compare against a vehicle's current odometer — a completion mileage lower than the
    /// current odometer is a valid historical service entry, not an invalid one.
    static func validatedCompletionMileage(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mileage = Int(trimmed), mileage > 0 else { return nil }
        return mileage
    }

    /// The next due mileage after completing a recurring, mileage-based reminder, computed from
    /// the actual completion mileage entered — including a historical completion below the
    /// vehicle's current odometer — never from the vehicle's current odometer. A non-positive
    /// interval means the reminder does not repeat by mileage.
    static func nextDueMileage(afterCompleting completionMileage: Int, repeatMileageInterval: Int) -> Int? {
        guard repeatMileageInterval > 0 else { return nil }
        return completionMileage + repeatMileageInterval
    }

    /// The vehicle odometer to persist after recording a completion. A completion can only
    /// ever move a vehicle's odometer forward (or leave it unchanged for a historical entry
    /// below the current reading) — never backward.
    static func advancedOdometer(current: Int, completionMileage: Int) -> Int {
        max(current, completionMileage)
    }

    /// True when `completionDate`'s calendar day is strictly after `asOf`'s calendar day.
    static func isFutureCompletionDate(_ completionDate: Date, asOf: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: completionDate) > calendar.startOfDay(for: asOf)
    }
}
