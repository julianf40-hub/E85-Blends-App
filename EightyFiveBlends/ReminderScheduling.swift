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
}
