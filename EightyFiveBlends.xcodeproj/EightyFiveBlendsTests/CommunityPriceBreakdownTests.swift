//
//  CommunityPriceBreakdownTests.swift
//  EightyFiveBlendsTests
//
//  Phase 3C — how a station's recent community reports become per-payment-method prices
//  (CommunityPriceBreakdown.swift, CommunityPriceModels.swift): a cash report and a credit report are different
//  prices, "same for both" counts as each, an unclassified (legacy) report is never promoted to either, and each
//  method keeps its OWN report time — a stale cash price is never shown as the current credit price.
//
//  Pure value logic: no network, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func report(
    _ price: Double,
    _ type: CommunityPaymentType,
    hoursAgo: Double,
    createdSecondsAfter: Double = 0,
    id: UUID? = UUID()
) -> CommunityPriceReport {
    let reportedAt = now.addingTimeInterval(-hoursAgo * 3600)
    return CommunityPriceReport(
        id: id,
        stationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111"),
        normalizedStationKey: "key",
        price: price,
        reportedAt: reportedAt,
        reporterID: "reporter",
        notes: nil,
        createdAt: reportedAt.addingTimeInterval(createdSecondsAfter),
        paymentType: type
    )
}

struct CommunityPriceBreakdownTests {
    @Test("No reports: no lines")
    func empty() {
        let breakdown = CommunityPriceBreakdown(reports: [])
        #expect(breakdown.lines.isEmpty)
        #expect(breakdown.hasTypedLines == false)
        #expect(breakdown.latestOverall == nil)
    }

    @Test("Cash and Credit are separate lines, each with its own price and its own report time")
    func cashAndCreditSeparate() {
        let cash = report(2.99, .cash, hoursAgo: 1)
        let credit = report(3.19, .credit, hoursAgo: 72)
        let breakdown = CommunityPriceBreakdown(reports: [credit, cash])

        #expect(breakdown.lines.count == 2)
        #expect(breakdown.lines[0].kind == .cash)
        #expect(breakdown.lines[0].price == 2.99)
        #expect(breakdown.lines[0].reportedAt == cash.reportedAt)
        #expect(breakdown.lines[1].kind == .credit)
        #expect(breakdown.lines[1].price == 3.19)
        #expect(breakdown.lines[1].reportedAt == credit.reportedAt)
        #expect(breakdown.hasTypedLines)
        #expect(breakdown.latestOverall?.price == 2.99)
    }

    @Test("Cash only is only a Cash line; Credit only is only a Credit line — the other is never invented")
    func oneMethodOnly() {
        let cashOnly = CommunityPriceBreakdown(reports: [report(2.99, .cash, hoursAgo: 1)])
        #expect(cashOnly.lines.map { $0.kind } == [.cash])
        let creditOnly = CommunityPriceBreakdown(reports: [report(3.19, .credit, hoursAgo: 1)])
        #expect(creditOnly.lines.map { $0.kind } == [.credit])
    }

    @Test("A price is never derived from the other: no plus-or-minus ten cents")
    func noDerivedPrice() {
        let breakdown = CommunityPriceBreakdown(reports: [report(2.99, .cash, hoursAgo: 1)])
        #expect(breakdown.creditReport == nil)
        #expect(breakdown.lines.contains { $0.kind == .credit } == false)
        #expect(breakdown.lines.contains { abs($0.price - 3.09) < 0.0001 || abs($0.price - 3.19) < 0.0001 } == false)
    }

    @Test("A single same_for_both report is ONE line that says it is the same for cash and credit")
    func sameForBothAlone() {
        let both = report(3.09, .sameForBoth, hoursAgo: 2)
        let breakdown = CommunityPriceBreakdown(reports: [both])

        #expect(breakdown.lines.count == 1)
        #expect(breakdown.lines[0].kind == .cashAndCredit)
        #expect(breakdown.lines[0].price == 3.09)
        #expect(breakdown.lines[0].isFromSameForBothReport)
        #expect(breakdown.lines[0].methodTitle == "Cash & Credit")
        #expect(breakdown.cashReport?.id == both.id)
        #expect(breakdown.creditReport?.id == both.id)
    }

    @Test("A same_for_both report that is newest for both methods hides the older single-method prices it supersedes")
    func sameForBothSupersedes() {
        let both = report(3.09, .sameForBoth, hoursAgo: 1)
        let olderCash = report(2.99, .cash, hoursAgo: 30)
        let olderCredit = report(3.29, .credit, hoursAgo: 40)
        let breakdown = CommunityPriceBreakdown(reports: [olderCash, olderCredit, both])

        #expect(breakdown.lines.count == 1)
        #expect(breakdown.lines[0].kind == .cashAndCredit)
        #expect(breakdown.lines[0].price == 3.09)
    }

    @Test("A newer cash report beats an older same_for_both for Cash; Credit still comes from the same_for_both report")
    func sameForBothServesTheOtherMethod() {
        let both = report(3.09, .sameForBoth, hoursAgo: 10)
        let newerCash = report(2.95, .cash, hoursAgo: 1)
        let breakdown = CommunityPriceBreakdown(reports: [both, newerCash])

        #expect(breakdown.lines.map { $0.kind } == [.cash, .credit])
        #expect(breakdown.lines[0].price == 2.95)
        #expect(breakdown.lines[0].isFromSameForBothReport == false)
        #expect(breakdown.lines[1].price == 3.09)
        #expect(breakdown.lines[1].isFromSameForBothReport)
    }

    @Test("Newer single-method reports replace an older same_for_both entirely")
    func newerTypedReplacesSameForBoth() {
        let both = report(3.09, .sameForBoth, hoursAgo: 10)
        let cash = report(2.95, .cash, hoursAgo: 2)
        let credit = report(3.15, .credit, hoursAgo: 1)
        let breakdown = CommunityPriceBreakdown(reports: [both, cash, credit])

        #expect(breakdown.lines.map { $0.kind } == [.cash, .credit])
        #expect(breakdown.lines.map { $0.price } == [2.95, 3.15])
    }

    @Test("The input order does not matter: the newest report of each method wins")
    func orderIndependence() {
        let reports = [
            report(2.89, .cash, hoursAgo: 50),
            report(2.99, .cash, hoursAgo: 5),
            report(3.29, .credit, hoursAgo: 60),
            report(3.19, .credit, hoursAgo: 6),
        ]
        let forward = CommunityPriceBreakdown(reports: reports)
        let backward = CommunityPriceBreakdown(reports: reports.reversed())
        #expect(forward.lines.map { $0.price } == [2.99, 3.19])
        #expect(backward.lines.map { $0.price } == [2.99, 3.19])
    }

    @Test("Rapid alternation between cash and credit never mixes the two: each line is the newest of ITS method")
    func rapidAlternation() {
        let reports = [
            report(2.90, .cash, hoursAgo: 4),
            report(3.20, .credit, hoursAgo: 3),
            report(2.95, .cash, hoursAgo: 2),
            report(3.25, .credit, hoursAgo: 1),
        ]
        let breakdown = CommunityPriceBreakdown(reports: reports)
        #expect(breakdown.lines.map { $0.kind } == [.cash, .credit])
        #expect(breakdown.lines.map { $0.price } == [2.95, 3.25])
    }

    @Test("A stale cash price keeps its own old report time and is never shown as the current credit price")
    func staleCashIsNotCurrentCredit() {
        let staleCash = report(2.79, .cash, hoursAgo: 24 * 30)
        let freshCredit = report(3.19, .credit, hoursAgo: 2)
        let breakdown = CommunityPriceBreakdown(reports: [staleCash, freshCredit])

        let cashLine = breakdown.lines.first { $0.kind == .cash }
        let creditLine = breakdown.lines.first { $0.kind == .credit }
        #expect(cashLine?.reportedAt == staleCash.reportedAt)
        #expect(creditLine?.reportedAt == freshCredit.reportedAt)
        #expect(creditLine?.price == 3.19)
        #expect(creditLine?.price != 2.79)

        // …and with no credit report at all, the stale cash price does not become the credit price.
        let cashOnly = CommunityPriceBreakdown(reports: [staleCash])
        #expect(cashOnly.creditReport == nil)
        #expect(cashOnly.lines.contains { $0.kind == .credit } == false)
    }

    @Test("Reports tied on time are ordered by creation time, then by id — deterministically")
    func ties() {
        let low = UUID(uuidString: "00000000-0000-4000-8000-000000000001")
        let high = UUID(uuidString: "00000000-0000-4000-8000-0000000000ff")
        let sameInstantEarlyCreate = report(2.90, .cash, hoursAgo: 1, createdSecondsAfter: 1, id: low)
        let sameInstantLateCreate = report(2.95, .cash, hoursAgo: 1, createdSecondsAfter: 5, id: low)
        #expect(CommunityPriceBreakdown(reports: [sameInstantEarlyCreate, sameInstantLateCreate]).cashReport?.price == 2.95)
        #expect(CommunityPriceBreakdown(reports: [sameInstantLateCreate, sameInstantEarlyCreate]).cashReport?.price == 2.95)

        let a = report(2.90, .cash, hoursAgo: 1, id: low)
        let b = report(2.95, .cash, hoursAgo: 1, id: high)
        #expect(CommunityPriceBreakdown(reports: [a, b]).cashReport?.price == 2.95)
        #expect(CommunityPriceBreakdown(reports: [b, a]).cashReport?.price == 2.95)
    }

    // MARK: Legacy / unclassified

    @Test("Only unclassified reports: one line that claims no method, and no typed lines — the legacy presentation")
    func legacyOnly() {
        let legacy = report(3.19, .unknown, hoursAgo: 1)
        let breakdown = CommunityPriceBreakdown(reports: [legacy, report(3.29, .unknown, hoursAgo: 90)])

        #expect(breakdown.hasTypedLines == false)
        #expect(breakdown.lines.count == 1)
        #expect(breakdown.lines[0].kind == .unknown)
        #expect(breakdown.lines[0].price == 3.19)
        #expect(breakdown.lines[0].methodTitle == "Payment type not specified")
        #expect(breakdown.lines[0].labeledPriceText == "$3.19/gal · Payment type not specified")
        #expect(breakdown.cashReport == nil)
        #expect(breakdown.creditReport == nil)
    }

    @Test("An unclassified report is never promoted to Cash or Credit")
    func unknownNeverPromoted() {
        let breakdown = CommunityPriceBreakdown(reports: [report(3.19, .unknown, hoursAgo: 1), report(2.99, .cash, hoursAgo: 5)])
        #expect(breakdown.creditReport == nil)
        #expect(breakdown.cashReport?.price == 2.99)
        #expect(breakdown.lines.first { $0.kind == .credit } == nil)
    }

    @Test("An unclassified report newer than every typed price is shown (labelled); an older one is left out")
    func unknownShownOnlyWhenNewer() {
        let typed = report(2.99, .cash, hoursAgo: 10)
        let newerUnknown = report(3.19, .unknown, hoursAgo: 1)
        let olderUnknown = report(3.49, .unknown, hoursAgo: 100)

        let withNewer = CommunityPriceBreakdown(reports: [typed, newerUnknown])
        #expect(withNewer.lines.map { $0.kind } == [.cash, .unknown])
        #expect(withNewer.lines[1].price == 3.19)

        let withOlder = CommunityPriceBreakdown(reports: [typed, olderUnknown])
        #expect(withOlder.lines.map { $0.kind } == [.cash])
    }

    @Test("latestOverall is the newest report of any kind — what the app has always called the community price")
    func latestOverall() {
        let reports = [
            report(2.99, .cash, hoursAgo: 5),
            report(3.19, .unknown, hoursAgo: 1),
            report(3.29, .credit, hoursAgo: 9),
        ]
        #expect(CommunityPriceBreakdown(reports: reports).latestOverall?.price == 3.19)
    }

    @Test("Line text names the method with its number")
    func lineText() {
        let cash = CommunityPriceLine(kind: .cash, price: 2.99, reportedAt: now, isFromSameForBothReport: false)
        #expect(cash.methodTitle == "Cash")
        #expect(cash.priceText == "$2.99/gal")
        #expect(cash.labeledPriceText == "Cash $2.99/gal")
        #expect(cash.spokenPriceText == "Cash E85 price $2.99/gal")
        let credit = CommunityPriceLine(kind: .credit, price: 3.19, reportedAt: now, isFromSameForBothReport: false)
        #expect(credit.labeledPriceText == "Credit $3.19/gal")
        #expect(credit.spokenPriceText == "Credit E85 price $3.19/gal")
        let both = CommunityPriceLine(kind: .cashAndCredit, price: 3.09, reportedAt: now, isFromSameForBothReport: true)
        #expect(both.labeledPriceText == "Cash & Credit $3.09/gal")
        #expect(both.spokenPriceText.contains("the same for cash and credit"))
    }
}

// MARK: - Models

struct CommunityPriceModelsPaymentTests {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SupabaseTimestamp.decodingStrategy
        return decoder
    }

    private func reportJSON(paymentType: String?) -> Data {
        let field = paymentType.map { #","payment_type":\#($0)"# } ?? ""
        return Data("""
        {"id":"22222222-2222-4222-8222-222222222222","station_id":"11111111-1111-4111-8111-111111111111","price":3.19,"reported_at":"2026-10-06T08:00:00.000Z","anonymous_reporter_id":"r","created_at":"2026-10-06T08:00:01.000Z"\(field)}
        """.utf8)
    }

    @Test("A report row decodes its payment type; a row without the column — an old backend — reads as unknown")
    func reportDecoding() throws {
        #expect(try decoder().decode(CommunityPriceReport.self, from: reportJSON(paymentType: #""cash""#)).paymentType == .cash)
        #expect(try decoder().decode(CommunityPriceReport.self, from: reportJSON(paymentType: #""credit""#)).paymentType == .credit)
        #expect(try decoder().decode(CommunityPriceReport.self, from: reportJSON(paymentType: #""same_for_both""#)).paymentType == .sameForBoth)
        #expect(try decoder().decode(CommunityPriceReport.self, from: reportJSON(paymentType: #""unknown""#)).paymentType == .unknown)
        #expect(try decoder().decode(CommunityPriceReport.self, from: reportJSON(paymentType: nil)).paymentType == .unknown)
    }

    @Test("A null, malformed or future payment type never makes the row (or the whole list) undecodable")
    func reportDecoding_isLenient() throws {
        for raw in ["null", #""barter""#, "7", "true", "[]", "{}"] {
            let report = try decoder().decode(CommunityPriceReport.self, from: reportJSON(paymentType: raw))
            #expect(report.paymentType == .unknown, "\(raw)")
            #expect(report.price == 3.19, "\(raw)")
        }
        let list = Data("[".utf8) + reportJSON(paymentType: #""cash""#) + Data(",".utf8) + reportJSON(paymentType: #""barter""#) + Data("]".utf8)
        let reports = try decoder().decode([CommunityPriceReport].self, from: list)
        #expect(reports.map { $0.paymentType } == [.cash, .unknown])
    }

    @Test("A summary keeps `latest` as the newest report of ANY type, and reads per-method prices from the recent window")
    func summary() {
        let newest = report(3.19, .credit, hoursAgo: 1)
        let cash = report(2.99, .cash, hoursAgo: 4)
        let summary = CommunityPriceSummary(
            normalizedStationKey: "key", latestReport: newest, reportCount: 1, recentReports: [newest, cash]
        )
        #expect(summary.latestPrice == 3.19)
        #expect(summary.latestReportedAt == newest.reportedAt)
        #expect(summary.communityStationID == newest.stationID)
        #expect(summary.breakdown.lines.map { $0.kind } == [.cash, .credit])
    }

    @Test("A summary built from one report (no recent window) still has a breakdown")
    func summaryFromOneReport() {
        let only = report(3.19, .credit, hoursAgo: 1)
        let summary = CommunityPriceSummary(normalizedStationKey: "key", latestReport: only, reportCount: 1)
        #expect(summary.recentReports.isEmpty)
        #expect(summary.breakdown.lines.map { $0.kind } == [.credit])

        let legacy = CommunityPriceSummary(normalizedStationKey: "key", latestReport: report(3.19, .unknown, hoursAgo: 1), reportCount: 1)
        #expect(legacy.breakdown.hasTypedLines == false)
        #expect(legacy.latestPrice == 3.19)

        let none = CommunityPriceSummary(normalizedStationKey: "key", latestReport: nil, reportCount: 0)
        #expect(none.breakdown.lines.isEmpty)
    }
}
