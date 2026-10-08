//
//  CommunityPriceBreakdown.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 (Phase 3C) — what a station's recent community reports say, per payment method, ready to
//  show. Pure Foundation: given the newest reports of a station it decides which price is the CASH price, which
//  is the CREDIT price, whether one report covers both, and whether an unclassified (legacy) report is worth
//  mentioning — and builds the lines a card prints. It never invents a price and never shows one method's price
//  under the other method's name.
//
//  THE RULES (they mirror the server's comparable streams, supabase/migrations/20261007130000):
//    * The CASH price is the newest report that is `cash` or `same_for_both`.
//    * The CREDIT price is the newest report that is `credit` or `same_for_both`.
//    * If both of those resolve to the SAME same_for_both report, there is one line, "Cash & Credit".
//    * An `unknown` (legacy / older-app) report is its own slot. It is NEVER promoted to cash or credit. It is
//      shown, labelled "Payment type not specified", only when nothing typed exists or when it is NEWER than
//      every typed price (it carries fresher news the app cannot classify).
//    * Each line keeps ITS OWN report time. A cash price from last week is never shown as though it were the
//      current credit price.
//    * A station whose reports are all unknown has `hasTypedLines == false`: callers keep their original
//      single-price presentation, unchanged.
//

import Foundation

nonisolated struct CommunityPriceLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case cash
        case credit
        /// One explicit same_for_both report that is both the newest cash price and the newest credit price.
        case cashAndCredit
        /// A report that does not say which price it is.
        case unknown
    }

    let kind: Kind
    let price: Double
    let reportedAt: Date
    /// True when the price comes from a same_for_both report (so a Cash or Credit line can say so).
    let isFromSameForBothReport: Bool

    /// "Cash", "Credit", "Cash & Credit", "Payment type not specified".
    var methodTitle: String {
        switch kind {
        case .cash: return "Cash"
        case .credit: return "Credit"
        case .cashAndCredit: return "Cash & Credit"
        case .unknown: return "Payment type not specified"
        }
    }

    /// "$2.99/gal".
    var priceText: String {
        String(format: "$%.2f/gal", price)
    }

    /// "Cash $2.99/gal"; an unclassified price is "$3.19/gal · Payment type not specified" so it never claims a method.
    var labeledPriceText: String {
        switch kind {
        case .unknown: return "\(priceText) · \(methodTitle)"
        default: return "\(methodTitle) \(priceText)"
        }
    }

    /// For VoiceOver: "cash E85 price $2.99/gal" — the method is always spoken with its number.
    var spokenPriceText: String {
        switch kind {
        case .cash: return "Cash E85 price \(priceText)"
        case .credit: return "Credit E85 price \(priceText)"
        case .cashAndCredit: return "E85 price \(priceText), the same for cash and credit"
        case .unknown: return "E85 price \(priceText), payment type not specified"
        }
    }
}

nonisolated struct CommunityPriceBreakdown: Sendable {
    /// The newest report of ANY kind — what the app has always shown as "the" community price.
    let latestOverall: CommunityPriceReport?
    /// Newest `cash` or `same_for_both` report.
    let cashReport: CommunityPriceReport?
    /// Newest `credit` or `same_for_both` report.
    let creditReport: CommunityPriceReport?
    /// Newest `unknown` report.
    let unknownReport: CommunityPriceReport?

    /// - Parameter reports: any number of a station's reports, in any order.
    init(reports: [CommunityPriceReport]) {
        let newestFirst = reports.sorted(by: Self.isNewer)
        latestOverall = newestFirst.first
        cashReport = newestFirst.first { $0.paymentType == .cash || $0.paymentType == .sameForBoth }
        creditReport = newestFirst.first { $0.paymentType == .credit || $0.paymentType == .sameForBoth }
        unknownReport = newestFirst.first { $0.paymentType == .unknown }
    }

    /// The server's ordering: reported time, then creation time, then id (newest first).
    private static func isNewer(_ lhs: CommunityPriceReport, _ rhs: CommunityPriceReport) -> Bool {
        if lhs.reportedAt != rhs.reportedAt { return lhs.reportedAt > rhs.reportedAt }
        let lhsCreated = lhs.createdAt ?? .distantPast
        let rhsCreated = rhs.createdAt ?? .distantPast
        if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }
        return (lhs.id?.uuidString ?? "") > (rhs.id?.uuidString ?? "")
    }

    private static func isSameReport(_ lhs: CommunityPriceReport, _ rhs: CommunityPriceReport) -> Bool {
        if let lhsID = lhs.id, let rhsID = rhs.id { return lhsID == rhsID }
        return lhs.price == rhs.price
            && lhs.reportedAt == rhs.reportedAt
            && lhs.paymentType == rhs.paymentType
            && lhs.reporterID == rhs.reporterID
    }

    /// The lines a card prints, in order: Cash, Credit (or one "Cash & Credit"), then an unclassified price if it
    /// deserves a mention. Empty when there is no report at all.
    var lines: [CommunityPriceLine] {
        var result: [CommunityPriceLine] = []

        if let cashReport, let creditReport,
           cashReport.paymentType == .sameForBoth, creditReport.paymentType == .sameForBoth,
           Self.isSameReport(cashReport, creditReport) {
            result.append(CommunityPriceLine(
                kind: .cashAndCredit, price: cashReport.price, reportedAt: cashReport.reportedAt, isFromSameForBothReport: true
            ))
        } else {
            if let cashReport {
                result.append(CommunityPriceLine(
                    kind: .cash, price: cashReport.price, reportedAt: cashReport.reportedAt,
                    isFromSameForBothReport: cashReport.paymentType == .sameForBoth
                ))
            }
            if let creditReport {
                result.append(CommunityPriceLine(
                    kind: .credit, price: creditReport.price, reportedAt: creditReport.reportedAt,
                    isFromSameForBothReport: creditReport.paymentType == .sameForBoth
                ))
            }
        }

        if let unknownReport {
            let newestTyped = result.map(\.reportedAt).max()
            if let newestTyped {
                if unknownReport.reportedAt > newestTyped {
                    result.append(Self.unknownLine(unknownReport))
                }
            } else {
                result.append(Self.unknownLine(unknownReport))
            }
        }
        return result
    }

    private static func unknownLine(_ report: CommunityPriceReport) -> CommunityPriceLine {
        CommunityPriceLine(kind: .unknown, price: report.price, reportedAt: report.reportedAt, isFromSameForBothReport: false)
    }

    /// True when at least one line names a payment method. When false (a station with only legacy reports) the
    /// caller keeps its original, unlabelled single-price presentation — nothing changes for that station.
    var hasTypedLines: Bool {
        lines.contains { $0.kind != .unknown }
    }
}
