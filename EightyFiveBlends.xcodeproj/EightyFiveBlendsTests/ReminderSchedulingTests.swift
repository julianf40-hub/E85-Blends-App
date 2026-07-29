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

    private func phoenixCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
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

    // MARK: - Calendar-day countdown regression (2.2.2 TestFlight off-by-one)
    //
    // wholeDays previously diffed raw clock times: from "now" (whatever time of day the user
    // opened the app) to a due date that isn't necessarily stored at midnight. Whenever the
    // due date's time-of-day was earlier than "now"'s, that undercounted the day gap by
    // exactly one full day. These tests pin "now" to a specific mid-afternoon clock time
    // (2:25 PM) precisely to exercise that gap; the old implementation fails every test below
    // except the same-day one.

    @Test("July 20 at 2:25 PM to July 31 at midnight is 11 days remaining, not 10")
    func wholeDays_july20ToJuly31_is11Days() {
        let calendar = utcCalendar()
        let now = date("2026-07-20 14:25:00", calendar: calendar)
        let dueDate = date("2026-07-31 00:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: now, to: dueDate, calendar: calendar) == 11)
    }

    @Test("July 20 at 2:25 PM to October 18 at midnight is 90 days remaining, not 89")
    func wholeDays_july20ToOctober18_is90Days() {
        let calendar = utcCalendar()
        let now = date("2026-07-20 14:25:00", calendar: calendar)
        let dueDate = date("2026-10-18 00:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: now, to: dueDate, calendar: calendar) == 90)
    }

    @Test("Same calendar date at different clock times is 0 days remaining")
    func wholeDays_sameCalendarDate_differentClockTimes_isZero() {
        let calendar = utcCalendar()
        let now = date("2026-07-20 14:25:00", calendar: calendar)
        let dueDate = date("2026-07-20 08:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: now, to: dueDate, calendar: calendar) == 0)
    }

    @Test("Due date at midnight tomorrow, checked mid-afternoon today, is 1 day remaining")
    func wholeDays_tomorrowAtMidnight_isOneDay() {
        let calendar = utcCalendar()
        let now = date("2026-07-20 14:25:00", calendar: calendar)
        let dueDate = date("2026-07-21 00:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: now, to: dueDate, calendar: calendar) == 1)
    }

    @Test("Due date yesterday, checked mid-afternoon today, is one day overdue")
    func wholeDays_yesterday_isOneDayOverdue() {
        let calendar = utcCalendar()
        let now = date("2026-07-20 14:25:00", calendar: calendar)
        let dueDate = date("2026-07-19 23:00:00", calendar: calendar)
        // Overdue-days display computes wholeDays(from: dueDate, to: now), matching
        // RemindersView's statusText usage.
        #expect(ReminderScheduling.wholeDays(from: dueDate, to: now, calendar: calendar) == 1)
        #expect(ReminderScheduling.isOverdue(dueDate: dueDate, asOf: now, calendar: calendar))
    }

    @Test("Calendar-day countdown across a spring-forward DST transition is unaffected by the clock jump")
    func wholeDays_acrossSpringForwardDST_isUnaffectedByClockJump() {
        let calendar = losAngelesCalendar()
        // US spring-forward in 2026 is March 8. A reminder due March 9 at midnight, checked
        // mid-afternoon on March 7, must read 2 calendar days regardless of the lost hour.
        let now = date("2026-03-07 14:25:00", calendar: calendar)
        let dueDate = date("2026-03-09 00:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: now, to: dueDate, calendar: calendar) == 2)
    }

    @Test("Calendar-day countdown across a fall-back DST transition is unaffected by the clock jump")
    func wholeDays_acrossFallBackDST_isUnaffectedByClockJump() {
        let calendar = losAngelesCalendar()
        // US fall-back in 2026 is November 1. A reminder due November 2 at midnight, checked
        // mid-afternoon on October 31, must read 2 calendar days regardless of the extra hour.
        let now = date("2026-10-31 14:25:00", calendar: calendar)
        let dueDate = date("2026-11-02 00:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: now, to: dueDate, calendar: calendar) == 2)
    }

    @Test("Calendar-day countdown in a non-DST time zone (Phoenix) matches the plain calendar-day gap")
    func wholeDays_nonDSTZonePhoenix_matchesPlainDayGap() {
        let calendar = phoenixCalendar()
        let now = date("2026-07-20 14:25:00", calendar: calendar)
        let dueDate = date("2026-07-31 00:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: now, to: dueDate, calendar: calendar) == 11)
    }

    @Test("Calendar-day countdown across a leap-year February 29th counts correctly")
    func wholeDays_acrossLeapYearFebruary29_countsCorrectly() {
        let calendar = utcCalendar()
        // 2028 is a leap year. Feb 28 mid-afternoon to Mar 1 midnight spans Feb 29 and must
        // read 2 calendar days, not 1.
        let now = date("2028-02-28 14:25:00", calendar: calendar)
        let dueDate = date("2028-03-01 00:00:00", calendar: calendar)
        #expect(ReminderScheduling.wholeDays(from: now, to: dueDate, calendar: calendar) == 2)
    }

    @Test("Completing a July 20 reminder with a 90-day interval still advances the due date to October 18")
    func nextDueDate_july20With90DayInterval_advancesToOctober18() {
        let calendar = utcCalendar()
        // Confirms recurrence advancement (a separate function from wholeDays) is unchanged
        // by the countdown-display fix above.
        let completion = date("2026-07-20 14:25:00", calendar: calendar)
        let next = ReminderScheduling.nextDueDate(afterCompleting: completion, repeatIntervalDays: 90, calendar: calendar)
        let expected = date("2026-10-18 14:25:00", calendar: calendar)
        #expect(next == expected)
    }

    // MARK: - Historical service completions (2.2.4)
    //
    // Covers RemindersView's completion-sheet fix: a completion mileage below the vehicle's
    // current odometer is a valid historical entry, must never lower/overwrite the odometer,
    // and the next due mileage/date must be computed from the entered completion values —
    // not from the vehicle's current state. Scenario letters (A-G) match the task's test plan.
    //
    // Scenario F ("wrong active vehicle") is not exercised here: RemindersView.vehicleProfile
    // (for:) — the function this scenario depends on — reads @Query'd SwiftData models and
    // View @State, and this repo has no wired SwiftData/XCTest target (see the note at the top
    // of this file's sibling test files and CLAUDE.md). It is a direct equality check
    // (`reminder.vehicleName == activeVehicle?.nickname`, else search `vehicles` by name) with
    // no branch that could fall back to the active vehicle by mistake — verified by inspection.

    // MARK: A. Historical mileage / G. Invalid input

    @Test("A completion mileage below the current vehicle odometer is a valid historical entry, not rejected")
    func validatedCompletionMileage_belowCurrentOdometer_isValid() {
        // Vehicle odometer 149,024; completion mileage 148,132 — historical entry (Scenario A).
        // validatedCompletionMileage never compares against a vehicle odometer at all.
        #expect(ReminderScheduling.validatedCompletionMileage(from: "148132") == 148132)
    }

    @Test("Empty completion mileage input is rejected")
    func validatedCompletionMileage_empty_isRejected() {
        #expect(ReminderScheduling.validatedCompletionMileage(from: "") == nil)
        #expect(ReminderScheduling.validatedCompletionMileage(from: "   ") == nil)
    }

    @Test("Zero completion mileage is rejected")
    func validatedCompletionMileage_zero_isRejected() {
        #expect(ReminderScheduling.validatedCompletionMileage(from: "0") == nil)
    }

    @Test("Negative completion mileage is rejected")
    func validatedCompletionMileage_negative_isRejected() {
        #expect(ReminderScheduling.validatedCompletionMileage(from: "-100") == nil)
    }

    @Test("Malformed or NaN completion mileage input is rejected")
    func validatedCompletionMileage_malformed_isRejected() {
        #expect(ReminderScheduling.validatedCompletionMileage(from: "abc") == nil)
        #expect(ReminderScheduling.validatedCompletionMileage(from: "NaN") == nil)
        #expect(ReminderScheduling.validatedCompletionMileage(from: "148,132") == nil)
        #expect(ReminderScheduling.validatedCompletionMileage(from: "148132.5") == nil)
    }

    @Test("Overflowing completion mileage input is rejected")
    func validatedCompletionMileage_overflow_isRejected() {
        #expect(ReminderScheduling.validatedCompletionMileage(from: "999999999999999999999999999999") == nil)
    }

    @Test("A valid positive completion mileage is accepted")
    func validatedCompletionMileage_validPositive_isAccepted() {
        #expect(ReminderScheduling.validatedCompletionMileage(from: "  148132  ") == 148132)
    }

    // MARK: B/C. Recurring mileage calculation, including an already-overdue result

    @Test("Next due mileage is computed from the entered completion mileage, not the current odometer")
    func nextDueMileage_fromHistoricalCompletion_advancesByInterval() {
        // Completion mileage 148,132; interval 5,000 -> next due 153,132 (Scenario B).
        #expect(ReminderScheduling.nextDueMileage(afterCompleting: 148132, repeatMileageInterval: 5000) == 153132)
    }

    @Test("A historical completion can produce a next due mileage that is already behind the current odometer")
    func nextDueMileage_historicalCompletion_canLandBehindCurrentOdometer() {
        // Current odometer 160,000; completion 148,132; interval 5,000 -> next due 153,132,
        // which is already behind 160,000 mi and must be displayed as overdue (Scenario C).
        // The scheduling math itself doesn't know about "current odometer" — RemindersView's
        // existing ReminderStatusInfo.isMileageOverdue (currentOdometer >= dueMileage) is what
        // surfaces this as overdue once dueMileage is set from this value.
        let nextDueMileage = ReminderScheduling.nextDueMileage(afterCompleting: 148132, repeatMileageInterval: 5000)
        #expect(nextDueMileage == 153132)
        let currentOdometer = 160000
        #expect(nextDueMileage.map { currentOdometer >= $0 } == true)
    }

    @Test("A non-repeating (non-positive interval) reminder has no next due mileage")
    func nextDueMileage_nonPositiveInterval_returnsNil() {
        #expect(ReminderScheduling.nextDueMileage(afterCompleting: 148132, repeatMileageInterval: 0) == nil)
        #expect(ReminderScheduling.nextDueMileage(afterCompleting: 148132, repeatMileageInterval: -10) == nil)
    }

    // MARK: D. Forward odometer protection

    @Test("A completion mileage below the current odometer never lowers the odometer")
    func advancedOdometer_belowCurrent_leavesOdometerUnchanged() {
        // Vehicle odometer 149,024; completion 148,132 -> odometer stays 149,024 (Scenario A/D).
        #expect(ReminderScheduling.advancedOdometer(current: 149024, completionMileage: 148132) == 149024)
    }

    @Test("A completion mileage above the current odometer advances the odometer forward")
    func advancedOdometer_aboveCurrent_movesForward() {
        // Existing forward-update behavior is preserved for a newer completion mileage.
        #expect(ReminderScheduling.advancedOdometer(current: 149024, completionMileage: 150500) == 150500)
    }

    @Test("A completion mileage equal to the current odometer leaves it unchanged")
    func advancedOdometer_equalToCurrent_isUnchanged() {
        #expect(ReminderScheduling.advancedOdometer(current: 149024, completionMileage: 149024) == 149024)
    }

    @Test("advancedOdometer is equivalent to max(current, completionMileage) and can never decrease the odometer")
    func advancedOdometer_isEquivalentToMax_neverDecreases() {
        let cases: [(current: Int, completion: Int)] = [
            (149024, 148132), (149024, 150000), (0, 5000), (200000, 1), (149024, 149024)
        ]
        for testCase in cases {
            let result = ReminderScheduling.advancedOdometer(current: testCase.current, completionMileage: testCase.completion)
            #expect(result == max(testCase.current, testCase.completion))
            #expect(result >= testCase.current)
        }
    }

    // MARK: E. Past completion dates / future-date rejection

    @Test("A past completion date is not a future date")
    func isFutureCompletionDate_pastDate_isFalse() {
        let calendar = utcCalendar()
        let now = date("2026-07-29 12:00:00", calendar: calendar)
        let pastCompletion = date("2026-06-01 09:00:00", calendar: calendar)
        #expect(ReminderScheduling.isFutureCompletionDate(pastCompletion, asOf: now, calendar: calendar) == false)
    }

    @Test("Today's completion date, at any time of day, is not a future date")
    func isFutureCompletionDate_today_isFalse() {
        let calendar = utcCalendar()
        let now = date("2026-07-29 08:00:00", calendar: calendar)
        let laterToday = date("2026-07-29 23:00:00", calendar: calendar)
        #expect(ReminderScheduling.isFutureCompletionDate(laterToday, asOf: now, calendar: calendar) == false)
    }

    @Test("A completion date after today's calendar day is a future date")
    func isFutureCompletionDate_futureDate_isTrue() {
        let calendar = utcCalendar()
        let now = date("2026-07-29 12:00:00", calendar: calendar)
        let futureCompletion = date("2026-07-30 00:01:00", calendar: calendar)
        #expect(ReminderScheduling.isFutureCompletionDate(futureCompletion, asOf: now, calendar: calendar))
    }

    @Test("A historical completion date drives the recurring next due date, not the current date")
    func nextDueDate_usesHistoricalCompletionDate_notNow() {
        // Scenario E: the recurring next date must be computed from the entered (historical)
        // completion date, matching how RemindersView.completeReminder always passes the
        // user-selected completionDate — never `.now` — into nextDueDate.
        let calendar = utcCalendar()
        let historicalCompletionDate = date("2026-06-01 09:00:00", calendar: calendar)
        let next = ReminderScheduling.nextDueDate(afterCompleting: historicalCompletionDate, repeatIntervalDays: 90, calendar: calendar)
        let expected = date("2026-08-30 09:00:00", calendar: calendar)
        #expect(next == expected)
    }
}
