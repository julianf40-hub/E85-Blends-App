//
//  CommunityPriceLinePresentationTests.swift
//  EightyFiveBlendsTests
//
//  Phase 3C — the words for a station's per-payment-method community prices (CommunityPriceLinePresentation.swift),
//  shared by every surface that prints them: Cash and Credit lines each with their OWN age and staleness, one
//  "Cash & Credit" line for a same-for-both report, an unclassified (legacy) price that claims no method, and the
//  rule that a station with only unclassified reports looks exactly as it always did (no typed lines at all).
//
//  The clock and calendar are pinned, so nothing here depends on today's date. Pure value logic.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

/// 2026-10-07 15:00 UTC.
private let now = Date(timeIntervalSince1970: 1_791_385_200)

private func ago(days: Int = 0, hours: Double = 0) -> Date {
    now.addingTimeInterval(-(Double(days) * 86_400 + hours * 3_600))
}

private func report(_ price: Double, _ type: CommunityPaymentType, at date: Date) -> CommunityPriceReport {
    CommunityPriceReport(
        id: UUID(),
        stationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111"),
        normalizedStationKey: "key",
        price: price,
        reportedAt: date,
        reporterID: "reporter",
        notes: nil,
        createdAt: date,
        paymentType: type
    )
}

private func summary(_ reports: [CommunityPriceReport]) -> CommunityPriceSummary {
    CommunityPriceSummary(
        normalizedStationKey: "key",
        latestReport: reports.max { $0.reportedAt < $1.reportedAt },
        reportCount: reports.isEmpty ? 0 : 1,
        recentReports: reports
    )
}

private func lines(_ reports: [CommunityPriceReport]) -> [CommunityPriceLinePresentation] {
    CommunityPriceLinePresenter.typedLines(from: summary(reports), now: now, calendar: calendar)
}

struct CommunityPriceLinePresentationTests {
    @Test("Cash and Credit each get a line with their own price, their own age and their own staleness")
    func independentFreshness() throws {
        let result = lines([report(2.99, .cash, at: ago(hours: 2)), report(3.19, .credit, at: ago(days: 20))])

        let cash = try #require(result.first { $0.kind == .cash })
        let credit = try #require(result.first { $0.kind == .credit })
        #expect(cash.label == "Cash")
        #expect(cash.priceText == "$2.99/gal")
        #expect(cash.reportedText == "Reported today")
        #expect(cash.isStale == false)
        #expect(credit.label == "Credit")
        #expect(credit.priceText == "$3.19/gal")
        #expect(credit.reportedText == "Reported 20 days ago")
        #expect(credit.isStale)
    }

    @Test("The reverse: a stale Cash price next to a fresh Credit price — the Cash price is NOT shown as current")
    func staleCashNextToFreshCredit() throws {
        let result = lines([report(2.79, .cash, at: ago(days: 30)), report(3.19, .credit, at: ago(hours: 1))])

        let cash = try #require(result.first { $0.kind == .cash })
        let credit = try #require(result.first { $0.kind == .credit })
        #expect(cash.isStale)
        #expect(cash.reportedText == "Reported 30 days ago")
        #expect(credit.isStale == false)
        #expect(credit.price == 3.19)
        #expect(result.map { $0.label } == ["Cash", "Credit"])
    }

    @Test("A same_for_both report is one 'Cash & Credit' line")
    func sameForBoth() throws {
        let result = lines([report(3.09, .sameForBoth, at: ago(hours: 3))])

        #expect(result.count == 1)
        let line = try #require(result.first)
        #expect(line.kind == .cashAndCredit)
        #expect(line.label == "Cash & Credit")
        #expect(line.summaryText == "Cash & Credit $3.09/gal · Reported today")
        #expect(line.accessibilityText == "E85 price $3.09/gal, the same for cash and credit, reported today")
    }

    @Test("Only unclassified reports: NO typed lines — every surface keeps its legacy single-price presentation")
    func legacyHasNoTypedLines() {
        #expect(lines([report(3.19, .unknown, at: ago(hours: 1))]).isEmpty)
        #expect(lines([report(3.19, .unknown, at: ago(hours: 1)), report(3.29, .unknown, at: ago(days: 4))]).isEmpty)
        #expect(lines([]).isEmpty)
        #expect(CommunityPriceLinePresenter.typedLines(from: nil, now: now, calendar: calendar).isEmpty)
    }

    @Test("A newer unclassified price next to typed prices is labelled 'Payment type not specified' and claims no method")
    func unclassifiedIsLabelled() throws {
        let result = lines([report(2.99, .cash, at: ago(days: 2)), report(3.19, .unknown, at: ago(hours: 1))])

        #expect(result.map { $0.kind } == [.cash, .unknown])
        let unclassified = try #require(result.last)
        #expect(unclassified.label == nil)
        #expect(unclassified.isUnclassified)
        #expect(unclassified.captionText == "Payment type not specified · Reported today")
        #expect(unclassified.summaryText == "$3.19/gal · Payment type not specified · Reported today")
        #expect(unclassified.accessibilityText == "E85 price $3.19/gal, payment type not specified, reported today")
        #expect(unclassified.summaryText.contains("Cash") == false)
        #expect(unclassified.summaryText.contains("Credit") == false)
    }

    @Test("Summary and caption text for a typed line")
    func typedText() throws {
        let line = try #require(lines([report(2.99, .cash, at: ago(days: 1))]).first)
        #expect(line.captionText == "Reported yesterday")
        #expect(line.summaryText == "Cash $2.99/gal · Reported yesterday")
        #expect(line.accessibilityText == "Cash E85 price $2.99/gal, reported yesterday")
    }

    @Test("A stale line says so to VoiceOver")
    func staleAccessibility() throws {
        let line = try #require(lines([report(3.19, .credit, at: ago(days: 21))]).first)
        #expect(line.accessibilityText == "Credit E85 price $3.19/gal, reported 21 days ago, may be outdated")
    }

    @Test("Line ids are distinct, so a list of lines is stable")
    func ids() {
        let result = lines([report(2.99, .cash, at: ago(hours: 1)), report(3.19, .credit, at: ago(hours: 2)), report(3.49, .unknown, at: ago(minutes: 1))])
        #expect(Set(result.map { $0.id }).count == result.count)
    }
}

private func ago(minutes: Double) -> Date {
    now.addingTimeInterval(-minutes * 60)
}

struct CommunityReportAgeTextTests {
    private func text(_ date: Date) -> String {
        CommunityPriceLinePresenter.reportedText(for: date, now: now, calendar: calendar)
    }

    @Test("Today, yesterday and N days ago — by calendar day, not by 24-hour blocks")
    func calendarDays() {
        #expect(text(now) == "Reported today")
        #expect(text(ago(hours: 14)) == "Reported today")                    // 01:00 the same UTC day
        #expect(text(ago(hours: 16)) == "Reported yesterday")                // 23:00 the day before
        #expect(text(ago(days: 1)) == "Reported yesterday")
        #expect(text(ago(days: 2)) == "Reported 2 days ago")
        #expect(text(ago(days: 13)) == "Reported 13 days ago")
        #expect(text(ago(days: 40)) == "Reported 40 days ago")
    }

    @Test("A time in the future (a skewed clock) reads as today, never as '0 days ago'")
    func future() {
        #expect(text(now.addingTimeInterval(3_600)) == "Reported today")
        #expect(text(now.addingTimeInterval(3 * 86_400)) == "Reported today")
    }

    @Test("Stale means more than 14 calendar days — the app's existing threshold")
    func staleness() {
        func stale(_ date: Date) -> Bool { CommunityPriceLinePresenter.isStale(date, now: now, calendar: calendar) }
        #expect(stale(ago(days: 14)) == false)
        #expect(stale(ago(days: 15)))
        #expect(stale(ago(hours: 1)) == false)
    }

    @Test("Spoken form lowercases only the first letter")
    func spoken() {
        #expect(CommunityPriceLinePresenter.spoken("Reported today") == "reported today")
        #expect(CommunityPriceLinePresenter.spoken("") == "")
    }
}

struct CommunityWidgetPriceLineTests {
    @Test("The widget shows the most recent TYPED price; on a tie, Credit")
    func newestTyped() throws {
        let cashNewer = summary([report(2.99, .cash, at: ago(hours: 1)), report(3.19, .credit, at: ago(days: 2))])
        #expect(CommunityPriceLinePresenter.newestTypedLine(from: cashNewer, now: now, calendar: calendar)?.kind == .cash)

        let creditNewer = summary([report(2.99, .cash, at: ago(days: 3)), report(3.19, .credit, at: ago(hours: 2))])
        #expect(CommunityPriceLinePresenter.newestTypedLine(from: creditNewer, now: now, calendar: calendar)?.kind == .credit)

        let instant = ago(hours: 5)
        let tie = summary([report(2.99, .cash, at: instant), report(3.19, .credit, at: instant)])
        #expect(CommunityPriceLinePresenter.newestTypedLine(from: tie, now: now, calendar: calendar)?.kind == .credit)
    }

    @Test("An unclassified price never wins the widget's single slot — a labelled older price is shown instead")
    func unclassifiedNeverWins() {
        let mixed = summary([report(2.99, .cash, at: ago(days: 5)), report(3.19, .unknown, at: ago(hours: 1))])
        let line = CommunityPriceLinePresenter.newestTypedLine(from: mixed, now: now, calendar: calendar)
        #expect(line?.kind == .cash)
        #expect(line?.price == 2.99)
    }

    @Test("No typed price: nil, so the widget keeps its legacy behavior")
    func noTyped() {
        #expect(CommunityPriceLinePresenter.newestTypedLine(from: summary([report(3.19, .unknown, at: ago(hours: 1))]), now: now, calendar: calendar) == nil)
        #expect(CommunityPriceLinePresenter.newestTypedLine(from: nil, now: now, calendar: calendar) == nil)
    }

    @Test("The snapshot records the backend's spelling for typed prices and nothing for an unclassified one")
    func widgetPaymentType() {
        #expect(CommunityPriceLinePresenter.widgetPaymentType(for: .cash) == "cash")
        #expect(CommunityPriceLinePresenter.widgetPaymentType(for: .credit) == "credit")
        #expect(CommunityPriceLinePresenter.widgetPaymentType(for: .cashAndCredit) == "same_for_both")
        #expect(CommunityPriceLinePresenter.widgetPaymentType(for: .unknown) == nil)
    }
}

// MARK: - The widget's price model

struct NearbyE85PricePaymentTypeTests {
    private let now = Date(timeIntervalSince1970: 1_791_385_200)

    @Test("A price with a payment type is labelled in the status line; one without reads exactly as before")
    func labeledStatus() {
        let reported = now.addingTimeInterval(-3_600)
        let cash = NearbyE85Price(dollarsPerGallon: 2.99, reportedAt: reported, source: .community, paymentType: "cash")
        #expect(cash.paymentShortLabel == "Cash")
        #expect(cash.paymentDescription == "Cash price")
        #expect(cash.labeledStatus(at: now) == "Cash · \(cash.status(at: now))")

        let credit = NearbyE85Price(dollarsPerGallon: 3.19, reportedAt: reported, source: .community, paymentType: "credit")
        #expect(credit.paymentShortLabel == "Credit")
        #expect(credit.paymentDescription == "Credit price")

        let both = NearbyE85Price(dollarsPerGallon: 3.09, reportedAt: reported, source: .community, paymentType: "same_for_both")
        #expect(both.paymentShortLabel == "Cash/Credit")
        #expect(both.paymentDescription == "Same price for cash and credit")

        let legacy = NearbyE85Price(dollarsPerGallon: 3.19, reportedAt: reported, source: .community)
        #expect(legacy.paymentType == nil)
        #expect(legacy.paymentShortLabel == nil)
        #expect(legacy.paymentDescription == nil)
        #expect(legacy.labeledStatus(at: now) == legacy.status(at: now))
    }

    @Test("An unrecognised payment type claims no method")
    func unrecognised() {
        for raw in ["unknown", "barter", "", "Cash"] {
            let price = NearbyE85Price(dollarsPerGallon: 3.19, reportedAt: now, source: .community, paymentType: raw)
            #expect(price.paymentShortLabel == nil, "\(raw)")
            #expect(price.paymentDescription == nil, "\(raw)")
            #expect(price.labeledStatus(at: now) == price.status(at: now), "\(raw)")
        }
    }

    @Test("validated() carries the payment type through, and still rejects an implausible price")
    func validated() {
        let price = NearbyE85Price.validated(2.99, reportedAt: now, source: .community, paymentType: "cash", now: now)
        #expect(price?.paymentType == "cash")
        #expect(NearbyE85Price.validated(2.99, reportedAt: now, source: .saved, now: now)?.paymentType == nil)
        #expect(NearbyE85Price.validated(999, reportedAt: now, source: .community, paymentType: "cash", now: now) == nil)
        #expect(NearbyE85Price.validated(nil, reportedAt: now, source: .community, paymentType: "cash", now: now) == nil)
    }

    @Test("A snapshot saved before payment types existed still decodes, and a new one round-trips")
    func codableCompatibility() throws {
        let oldJSON = #"{"dollarsPerGallon":3.19,"reportedAt":0,"source":"community"}"#
        let decoded = try JSONDecoder().decode(NearbyE85Price.self, from: Data(oldJSON.utf8))
        #expect(decoded.dollarsPerGallon == 3.19)
        #expect(decoded.paymentType == nil)

        let original = NearbyE85Price(dollarsPerGallon: 2.99, reportedAt: now, source: .community, paymentType: "credit")
        let data = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(NearbyE85Price.self, from: data)
        #expect(roundTripped == original)

        // An older widget reading a new snapshot ignores the extra key: simulate by decoding without the field.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["paymentType"] as? String == "credit")
    }
}
