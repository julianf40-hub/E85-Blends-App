//
//  CommunityPaymentType.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 (Phase 3C) — which price a community E85 report is. A station can show one price for
//  paying cash and another for paying by card; a report that says only "3.19" cannot be compared with
//  another that says only "2.99". The identifiers are the backend's (public.e85_price_reports.payment_type)
//  and are spelled the same in the database, the API and here:
//
//      cash            the price shown for paying cash
//      credit          the price shown for paying by card
//      same_for_both   ONE price the reporter saw for both; it counts as the cash price AND the credit price
//      unknown         every report made before payment types existed, and every report from an app version
//                      that does not send the field. Nothing is guessed; it is never turned into cash or credit.
//
//  Pure Foundation. Decoding is deliberately lenient: a missing, null or unrecognised value reads as
//  `.unknown` and never throws, because one undecodable row would otherwise discard every community price on
//  the Stations screen (see StationsView's summary task group).
//

import Foundation

nonisolated enum CommunityPaymentType: String, CaseIterable, Hashable, Sendable {
    case cash
    case credit
    case sameForBoth = "same_for_both"
    case unknown

    /// What a person may CHOOSE when reporting a price. `.unknown` is not a choice: it is what a missing
    /// answer is stored as, never something to pick.
    static let reportChoices: [CommunityPaymentType] = [.cash, .credit, .sameForBoth]

    /// The backend's identifier. Exactly `cash`, `credit`, `same_for_both` or `unknown`.
    var wireValue: String { rawValue }

    /// Reads the backend's identifier. `nil`, an empty string, a different case (`"Cash"`) and any value this
    /// build has never heard of all read as `.unknown`.
    init(wireValue: String?) {
        guard let wireValue, let known = CommunityPaymentType(rawValue: wireValue) else {
            self = .unknown
            return
        }
        self = known
    }

    /// True for a report that says which price it is.
    var isSpecified: Bool {
        self != .unknown
    }

    /// The label on a button or a price line.
    var title: String {
        switch self {
        case .cash: return "Cash"
        case .credit: return "Credit"
        case .sameForBoth: return "Same for Both"
        case .unknown: return "Payment type not specified"
        }
    }

    /// What VoiceOver adds to the choice button in the report sheets, so "Same for Both" is not left to guesswork.
    var reportAccessibilityHint: String {
        switch self {
        case .cash: return "The price shown for paying with cash."
        case .credit: return "The price shown for paying by card."
        case .sameForBoth: return "One price shown for both cash and credit."
        case .unknown: return ""
        }
    }

    /// How VoiceOver says it inside a sentence ("cash price", "same price for cash and credit").
    var spokenDescription: String {
        switch self {
        case .cash: return "cash"
        case .credit: return "credit"
        case .sameForBoth: return "the same price for cash and credit"
        case .unknown: return "payment type not specified"
        }
    }
}

extension CommunityPaymentType: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .unknown
            return
        }
        self.init(wireValue: try? container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// The wording and the one rule of the payment-type selector in the report sheets.
nonisolated enum CommunityPaymentTypeValidation {
    static let sectionTitle = "Payment Type"
    static let helpText = "Select the price shown at the pump or on the sign."
    static let missingChoiceMessage = "Choose Cash, Credit, or Same for Both."

    /// The choice to send, or `nil` if the person has not made one. `.unknown` is never a valid answer, so
    /// a new report cannot be filed without saying which price it is.
    static func reportableChoice(_ selection: CommunityPaymentType?) -> CommunityPaymentType? {
        guard let selection, selection.isSpecified else { return nil }
        return selection
    }
}
