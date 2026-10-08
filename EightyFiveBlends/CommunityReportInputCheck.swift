//
//  CommunityReportInputCheck.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 (Phase 3C) — everything a community E85 price report needs before it may be sent, decided in one
//  place so the Stations sheet (both layouts) and the tests apply the same rules:
//
//    * the price: a finite dollar amount inside the server's own bound (CommunityPriceValidation), and
//    * the payment type: an explicit Cash / Credit / Same for Both. There is NO default and `.unknown` is not a
//      valid answer, so a price is never filed without saying which price it is, and is never silently labelled.
//
//  The payment type is required only when a report is actually going to the community. A station that cannot be
//  reported (not enough location information) is saved locally, as it always was, without asking.
//
//  Both problems are reported together, so a person fixing one is not surprised by the other.
//

import Foundation

struct CommunityReportInputCheck: Equatable {
    let price: Double?
    let paymentType: CommunityPaymentType?
    let priceMessage: String?
    let paymentMessage: String?

    /// "Enter an E85 price between $1.00 and $8.00." — built from the server bound, so the text cannot drift from it.
    static var invalidPriceMessage: String {
        String(
            format: "Enter an E85 price between $%.2f and $%.2f.",
            CommunityPriceValidation.minimumValidPrice,
            CommunityPriceValidation.maximumValidPrice
        )
    }

    /// True when the report may be saved and sent.
    var isValid: Bool {
        price != nil && priceMessage == nil && paymentMessage == nil
    }

    static func evaluate(
        priceText: String,
        paymentSelection: CommunityPaymentType?,
        requiresPaymentChoice: Bool
    ) -> CommunityReportInputCheck {
        let price = CommunityPriceValidation.parseValidPrice(from: priceText)
        let choice = CommunityPaymentTypeValidation.reportableChoice(paymentSelection)
        return CommunityReportInputCheck(
            price: price,
            paymentType: choice,
            priceMessage: price == nil ? invalidPriceMessage : nil,
            paymentMessage: (requiresPaymentChoice && choice == nil) ? CommunityPaymentTypeValidation.missingChoiceMessage : nil
        )
    }
}
