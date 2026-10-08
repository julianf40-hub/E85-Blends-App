//
//  CommunityPriceLinePresentation.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 (Phase 3C) — the words for a station's community prices once they are told apart by payment
//  method. One presenter shared by every place the app prints them (the saved-station and Nearby cards, the Pro map
//  card, the post-navigation reporter, the widget label), so Cash and Credit can never be worded two ways. Pure
//  Foundation: the clock and calendar are parameters, so the tests pin them.
//
//  THE LEGACY RULE. A station whose community reports are all unclassified (everything reported before payment types
//  existed, and everything an older app sends) has NO typed lines: `typedLines` returns [] and each caller keeps
//  its original single-price presentation, unchanged. Nothing about such a station looks different, and nothing
//  claims a payment method for a price that never said which it was.
//
//  FRESHNESS BELONGS TO THE LINE. Each line carries its own report time and its own stale flag, so a Cash price
//  from three weeks ago is shown as three weeks old next to a Credit price from today — never as the current
//  Credit price (the line list is built per method; see CommunityPriceBreakdown).
//

import Foundation

// MARK: - A line, ready to print

nonisolated struct CommunityPriceLinePresentation: Identifiable, Equatable, Sendable {
    let kind: CommunityPriceLine.Kind
    let price: Double
    let reportedAt: Date
    /// "Cash", "Credit", "Cash & Credit"; `nil` for a price that does not say which it is.
    let label: String?
    /// "$2.99/gal".
    let priceText: String
    /// "Reported today", "Reported yesterday", "Reported 3 days ago".
    let reportedText: String
    /// Older than the app's 14-day staleness threshold (StationDataValidation.isStale).
    let isStale: Bool

    var id: String {
        switch kind {
        case .cash: return "cash"
        case .credit: return "credit"
        case .cashAndCredit: return "cashAndCredit"
        case .unknown: return "unknown"
        }
    }

    /// True for a price that does not say which method it is.
    var isUnclassified: Bool {
        kind == .unknown
    }

    /// Under the price: "Reported today", or "Payment type not specified · Reported today" for an unclassified one.
    var captionText: String {
        isUnclassified ? "\(CommunityPriceLinePresenter.unclassifiedLabel) · \(reportedText)" : reportedText
    }

    /// One line of text: "Cash $2.99/gal · Reported today" / "$3.19/gal · Payment type not specified · Reported today".
    var summaryText: String {
        if let label {
            return "\(label) \(priceText) · \(reportedText)"
        }
        return "\(priceText) · \(captionText)"
    }

    /// For VoiceOver. The method is always spoken with its number, and a stale price says so.
    var accessibilityText: String {
        var parts: [String]
        switch kind {
        case .cash: parts = ["Cash E85 price \(priceText)"]
        case .credit: parts = ["Credit E85 price \(priceText)"]
        case .cashAndCredit: parts = ["E85 price \(priceText), the same for cash and credit"]
        case .unknown: parts = ["E85 price \(priceText), payment type not specified"]
        }
        parts.append(CommunityPriceLinePresenter.spoken(reportedText))
        if isStale {
            parts.append("may be outdated")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Presenter

nonisolated enum CommunityPriceLinePresenter {
    static let unclassifiedLabel = "Payment type not specified"

    /// The station's community prices by payment method, in print order (Cash, Credit — or one "Cash & Credit" —
    /// then an unclassified price when it is newer than every typed one). EMPTY when no typed price exists, which
    /// is the signal for the caller to keep its legacy single-price presentation.
    static func typedLines(
        from summary: CommunityPriceSummary?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [CommunityPriceLinePresentation] {
        guard let summary else { return [] }
        let breakdown = summary.breakdown
        guard breakdown.hasTypedLines else { return [] }
        return breakdown.lines.map { present($0, now: now, calendar: calendar) }
    }

    static func present(
        _ line: CommunityPriceLine,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> CommunityPriceLinePresentation {
        let label: String?
        switch line.kind {
        case .cash: label = "Cash"
        case .credit: label = "Credit"
        case .cashAndCredit: label = "Cash & Credit"
        case .unknown: label = nil
        }
        return CommunityPriceLinePresentation(
            kind: line.kind,
            price: line.price,
            reportedAt: line.reportedAt,
            label: label,
            priceText: line.priceText,
            reportedText: reportedText(for: line.reportedAt, now: now, calendar: calendar),
            isStale: isStale(line.reportedAt, now: now, calendar: calendar)
        )
    }

    /// The typed line a single-price surface (the widget) shows: the most recently reported TYPED price; on a tie,
    /// the Credit line (the price most people pay at the pump). `nil` when there is no typed price, in which case
    /// the surface keeps its legacy behavior. An unclassified price never wins here: a surface with no room for
    /// "payment type not specified" shows a labelled older price rather than an unlabelled newer one.
    static func newestTypedLine(
        from summary: CommunityPriceSummary?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> CommunityPriceLinePresentation? {
        let typed = typedLines(from: summary, now: now, calendar: calendar).filter { $0.isUnclassified == false }
        guard let newest = typed.map(\.reportedAt).max() else { return nil }
        let candidates = typed.filter { $0.reportedAt == newest }
        return candidates.first { $0.kind == .credit } ?? candidates.first
    }

    /// The payment type the Nearby E85 widget snapshot records for a line: the backend's spelling, `nil` for an
    /// unclassified price (the widget then shows no method, as it always did).
    static func widgetPaymentType(for kind: CommunityPriceLine.Kind) -> String? {
        switch kind {
        case .cash: return CommunityPaymentType.cash.wireValue
        case .credit: return CommunityPaymentType.credit.wireValue
        case .cashAndCredit: return CommunityPaymentType.sameForBoth.wireValue
        case .unknown: return nil
        }
    }

    // MARK: Age

    /// "Reported today" / "Reported yesterday" / "Reported N days ago". A time in the future (a skewed clock) reads
    /// as today.
    static func reportedText(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday {
            return "Reported today"
        }
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday), date >= startOfYesterday {
            return "Reported yesterday"
        }
        let days = StationDataValidation.daysSince(date, asOf: now, calendar: calendar)
        return "Reported \(days) day\(days == 1 ? "" : "s") ago"
    }

    static func isStale(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        StationDataValidation.isStale(daysSince: StationDataValidation.daysSince(date, asOf: now, calendar: calendar))
    }

    /// "Reported today" → "reported today", for the middle of a spoken sentence.
    static func spoken(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
