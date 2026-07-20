//
//  ReminderSchedulingTests.swift
//  EightyFiveBlendsTests
//
//  Tests for centralized reminder date math: overdue detection, day counts, and
//  recurrence advancement across DST transitions, leap years, and time zones.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct ReminderSchedulingTests {

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func losAngelesCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ isoString: String, calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: isoString)!
    }

    // MARK: - isOverdue

    @Test("A due date from yesterday is overdue")
    func isOverdue_yesterday_isTrue() {
        let calendar = utcCalendar()
        let due = date("2026-03-01 09:00:00", calendar: calendar)
        let now = date("2026-03-02 09:00:00", calendar: calendar)
        #expect(ReminderScheduling.isOverdue(dueDate: due, asOf: now, calendar: calendar))
    }

    @Test("A due date later today is not overdue")
    func isOverdue_laterToday_isFalse() {
        let calendar = utcCalendar()
        let due = date("2026-03-01 23:00:00", calendar: calendar)
        let now = date("2026-03-01 08:00:00", calendar: calendar)
        #expect(ReminderScheduling.isOverdue(dueDate: due, asOf: now, calendar: calendar) == false)
    }

    @Test("A due date due today but earlier in the day is not overdue (day-level granularity)")
    func isOverdue_earlierSameDay_isFalse() {
        let calendar = utcCalendar()
        let due = date("2026-03-01 06:00:00", calendar: calendar)
        let now = date("2026-03-01 23:00:00", calendar: calendar)
        #expect(ReminderScheduling.isOverdue(dueDate: due, asOf: now, calendar: calendar) == false)
    }

    // MARK: - wholeDays

    @Test("wholeDays counts whole calendar days between two dates")
    func wholeDays_basicRange() {
        let calendar = utcCalendar()
        let start = date("2026-01-01 09:00:00", calendar: calendar)
        let end = date("2026-01-08 09:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: start, to: end, calendar: calendar) == 7)
    }

    @Test("wholeDays is negative when the target date is earlier than the start")
    func wholeDays_negativeWhenReversed() {
        let calendar = utcCalendar()
        let start = date("2026-01-08 09:00:00", calendar: calendar)
        let end = date("2026-01-01 09:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: start, to: end, calendar: calendar) == -7)
    }

    // MARK: - Leap year / February boundaries

    @Test("Recurrence across a leap-year February 29th advances correctly")
    func nextDueDate_acrossLeapYearFebruary29() {
        let calendar = utcCalendar()
        // 2028 is a leap year. Completing on Feb 28 with a 2-day repeat should land on Mar 1,
        // passing through the leap day.
        let completion = date("2028-02-28 10:00:00", calendar: calendar)
        let next = ReminderScheduling.nextDueDate(afterCompleting: completion, repeatIntervalDays: 2, calendar: calendar)
        let expected = date("2028-03-01 10:00:00", calendar: calendar)
        #expect(next == expected)
    }

    @Test("Recurrence across a non-leap-year February does not land on a nonexistent Feb 29")
    func nextDueDate_acrossNonLeapYearFebruary() {
        let calendar = utcCalendar()
        // 2027 is not a leap year. Completing Feb 27 + 2 days should land on Mar 1 (there is
        // no Feb 29 to skip incorrectly onto).
        let completion = date("2027-02-27 10:00:00", calendar: calendar)
        let next = ReminderScheduling.nextDueDate(afterCompleting: completion, repeatIntervalDays: 2, calendar: calendar)
        let expected = date("2027-03-01 10:00:00", calendar: calendar)
        #expect(next == expected)
    }

    @Test("A 30-day recurrence starting on the 31st lands on a valid date the following month")
    func nextDueDate_fromThe31st_landsOnValidDate() {
        let calendar = utcCalendar()
        let completion = date("2026-01-31 10:00:00", calendar: calendar)
        let next = ReminderScheduling.nextDueDate(afterCompleting: completion, repeatIntervalDays: 30, calendar: calendar)
        // Jan 31 + 30 days = Mar 2, 2026 (Jan has 31 days, Feb 2026 has 28).
        let expected = date("2026-03-02 10:00:00", calendar: calendar)
        #expect(next == expected)
    }

    // MARK: - DST transitions

    @Test("Recurrence across a spring-forward DST transition preserves the calendar day count")
    func nextDueDate_acrossSpringForwardDST() {
        let calendar = losAngelesCalendar()
        // US spring-forward in 2026 is March 8. Completing March 7 with a 1-day repeat must
        // land on March 8 in local wall-clock time, not be off by an hour due to the DST gap.
        let completion = date("2026-03-07 09:00:00", calendar: calendar)
        let next = ReminderScheduling.nextDueDate(afterCompleting: completion, repeatIntervalDays: 1, calendar: calendar)
        let expected = date("2026-03-08 09:00:00", calendar: calendar)
        #expect(next == expected)
    }

    @Test("Recurrence across a fall-back DST transition preserves the calendar day count")
    func nextDueDate_acrossFallBackDST() {
        let calendar = losAngelesCalendar()
        // US fall-back in 2026 is November 1. Completing October 31 with a 1-day repeat must
        // land on November 1 in local wall-clock time.
        let completion = date("2026-10-31 09:00:00", calendar: calendar)
        let next = ReminderScheduling.nextDueDate(afterCompleting: completion, repeatIntervalDays: 1, calendar: calendar)
        let expected = date("2026-11-01 09:00:00", calendar: calendar)
        #expect(next == expected)
    }

    @Test("isOverdue is consistent across a DST transition day")
    func isOverdue_acrossDSTTransitionDay() {
        let calendar = losAngelesCalendar()
        let due = date("2026-03-07 09:00:00", calendar: calendar)
        let now = date("2026-03-08 12:00:00", calendar: calendar)
        #expect(ReminderScheduling.isOverdue(dueDate: due, asOf: now, calendar: calendar))
    }

    // MARK: - Time zone changes

    @Test("The same instant can be overdue in one time zone and not yet overdue in another")
    func isOverdue_differsAcrossTimeZones() {
        // Both instants fall in UTC's Dec 31 -> Jan 1 rollover, but in Los Angeles (UTC-8 in
        // winter) they're both still the afternoon/evening of Dec 31 — no day rollover yet.
        let utc = utcCalendar()
        let due = date("2025-12-31 23:00:00", calendar: utc)
        let now = date("2026-01-01 00:30:00", calendar: utc)

        #expect(ReminderScheduling.isOverdue(dueDate: due, asOf: now, calendar: utc))

        let losAngeles = losAngelesCalendar()
        #expect(ReminderScheduling.isOverdue(dueDate: due, asOf: now, calendar: losAngeles) == false)
    }

    // MARK: - Non-repeating / invalid interval guard

    @Test("A zero or negative repeat interval does not repeat")
    func nextDueDate_nonPositiveInterval_returnsNil() {
        let calendar = utcCalendar()
        let completion = date("2026-05-01 10:00:00", calendar: calendar)
        #expect(ReminderScheduling.nextDueDate(afterCompleting: completion, repeatIntervalDays: 0, calendar: calendar) == nil)
        #expect(ReminderScheduling.nextDueDate(afterCompleting: completion, repeatIntervalDays: -5, calendar: calendar) == nil)
    }

    // MARK: - Past-due handling

    @Test("A reminder overdue by many days still reports a correctly clamped day count")
    func wholeDays_pastDue_largeGap() {
        let calendar = utcCalendar()
        let due = date("2025-01-01 09:00:00", calendar: calendar)
        let now = date("2026-01-01 09:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: due, to: now, calendar: calendar) == 365)
        #expect(ReminderScheduling.isOverdue(dueDate: due, asOf: now, calendar: calendar))
    }
}
