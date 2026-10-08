//
//  CommunityPaymentTypeTests.swift
//  EightyFiveBlendsTests
//
//  Phase 3C — the payment-type vocabulary of a community E85 price report (CommunityPaymentType.swift): the
//  identifiers are the backend's, a missing or unknown value is never turned into cash or credit, decoding never
//  throws (one bad row must not empty every community price), the comparability rule matches the server's, and the
//  report sheets' one rule — "an explicit choice, never `unknown`" — holds.
//
//  Pure value logic: no network, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct CommunityPaymentTypeTests {
    @Test("The vocabulary is exactly cash, credit, same_for_both and unknown — the backend's identifiers")
    func vocabulary() {
        let wire = CommunityPaymentType.allCases.map { $0.wireValue }
        #expect(wire == ["cash", "credit", "same_for_both", "unknown"])
        #expect(CommunityPaymentType.sameForBoth.wireValue == "same_for_both")
    }

    @Test("A person can choose Cash, Credit or Same for Both — never `unknown`")
    func reportChoices() {
        #expect(CommunityPaymentType.reportChoices == [.cash, .credit, .sameForBoth])
        #expect(CommunityPaymentType.reportChoices.contains(.unknown) == false)
        let titles = CommunityPaymentType.reportChoices.map { $0.title }
        #expect(titles == ["Cash", "Credit", "Same for Both"])
        for choice in CommunityPaymentType.reportChoices {
            #expect(choice.isSpecified)
            #expect(choice.reportAccessibilityHint.isEmpty == false)
        }
        #expect(CommunityPaymentType.unknown.isSpecified == false)
        #expect(CommunityPaymentType.unknown.reportAccessibilityHint.isEmpty)
    }

    @Test("A missing, empty, differently-spelled or future value reads as unknown — never as cash or credit")
    func lenientWireReading() {
        #expect(CommunityPaymentType(wireValue: "cash") == .cash)
        #expect(CommunityPaymentType(wireValue: "credit") == .credit)
        #expect(CommunityPaymentType(wireValue: "same_for_both") == .sameForBoth)
        #expect(CommunityPaymentType(wireValue: "unknown") == .unknown)
        for value in [nil, "", "Cash", "CREDIT", " cash", "cash ", "debit", "same-for-both", "both", "sameForBoth"] as [String?] {
            #expect(CommunityPaymentType(wireValue: value) == .unknown, "\(String(describing: value))")
        }
    }

    private struct Wrapper: Codable {
        let paymentType: CommunityPaymentType
        enum CodingKeys: String, CodingKey { case paymentType = "payment_type" }
    }

    private func decode(_ json: String) throws -> CommunityPaymentType {
        try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8)).paymentType
    }

    @Test("Decoding never throws: strings map to their case, everything else is unknown")
    func lenientDecoding() throws {
        #expect(try decode(#"{"payment_type":"cash"}"#) == .cash)
        #expect(try decode(#"{"payment_type":"credit"}"#) == .credit)
        #expect(try decode(#"{"payment_type":"same_for_both"}"#) == .sameForBoth)
        #expect(try decode(#"{"payment_type":"unknown"}"#) == .unknown)
        #expect(try decode(#"{"payment_type":"barter"}"#) == .unknown)
        #expect(try decode(#"{"payment_type":""}"#) == .unknown)
        #expect(try decode(#"{"payment_type":null}"#) == .unknown)
        #expect(try decode(#"{"payment_type":7}"#) == .unknown)
        #expect(try decode(#"{"payment_type":true}"#) == .unknown)
        #expect(try decode(#"{"payment_type":["cash"]}"#) == .unknown)
        #expect(try decode(#"{"payment_type":{"cash":1}}"#) == .unknown)
    }

    @Test("Encoding writes exactly the backend's identifier")
    func encoding() throws {
        for type in CommunityPaymentType.allCases {
            let data = try JSONEncoder().encode(Wrapper(paymentType: type))
            let text = String(decoding: data, as: UTF8.self)
            #expect(text == #"{"payment_type":"\#(type.wireValue)"}"#)
        }
    }

    @Test("A report is comparable to an alert exactly as the server compares them")
    func comparabilityMatrix() {
        // Rows: the report's type. Columns: the alert's payment type.
        let expectations: [(CommunityPaymentType, PriceAlertPayment, Bool)] = [
            (.cash, .cash, true), (.cash, .credit, false), (.cash, .unknown, false),
            (.credit, .cash, false), (.credit, .credit, true), (.credit, .unknown, false),
            (.sameForBoth, .cash, true), (.sameForBoth, .credit, true), (.sameForBoth, .unknown, false),
            (.unknown, .cash, false), (.unknown, .credit, false), (.unknown, .unknown, true),
        ]
        for (report, alert, expected) in expectations {
            #expect(report.isComparable(to: alert) == expected, "\(report) report vs \(alert) alert")
        }
    }
}

struct CommunityPaymentTypeValidationTests {
    @Test("The selector's words are the product's, word for word")
    func copy() {
        #expect(CommunityPaymentTypeValidation.sectionTitle == "Payment Type")
        #expect(CommunityPaymentTypeValidation.helpText == "Select the price shown at the pump or on the sign.")
        #expect(CommunityPaymentTypeValidation.missingChoiceMessage == "Choose Cash, Credit, or Same for Both.")
    }

    @Test("A report needs an explicit choice: nothing, and `unknown`, are not answers")
    func reportableChoice() {
        #expect(CommunityPaymentTypeValidation.reportableChoice(nil) == nil)
        #expect(CommunityPaymentTypeValidation.reportableChoice(.unknown) == nil)
        #expect(CommunityPaymentTypeValidation.reportableChoice(.cash) == .cash)
        #expect(CommunityPaymentTypeValidation.reportableChoice(.credit) == .credit)
        #expect(CommunityPaymentTypeValidation.reportableChoice(.sameForBoth) == .sameForBoth)
    }
}

// MARK: - The report's input rules

struct CommunityReportInputCheckTests {
    private func check(_ price: String, _ payment: CommunityPaymentType?, required: Bool = true) -> CommunityReportInputCheck {
        CommunityReportInputCheck.evaluate(priceText: price, paymentSelection: payment, requiresPaymentChoice: required)
    }

    @Test("A valid price with an explicit choice is valid, and carries both")
    func valid() {
        for choice in CommunityPaymentType.reportChoices {
            let result = check("3.19", choice)
            #expect(result.isValid)
            #expect(result.price == 3.19)
            #expect(result.paymentType == choice)
            #expect(result.priceMessage == nil)
            #expect(result.paymentMessage == nil)
        }
    }

    @Test("No payment choice blocks a community report — there is no default and `unknown` does not count")
    func missingChoice() {
        for selection in [nil, CommunityPaymentType.unknown] as [CommunityPaymentType?] {
            let result = check("3.19", selection)
            #expect(result.isValid == false)
            #expect(result.paymentType == nil)
            #expect(result.paymentMessage == CommunityPaymentTypeValidation.missingChoiceMessage)
            #expect(result.priceMessage == nil, "the price is fine; only the choice is missing")
        }
    }

    @Test("A bad price blocks the report with the server's own bound in the message")
    func badPrice() {
        for text in ["", "abc", "0.99", "8.01", "nan", "inf", "-3", "999"] {
            let result = check(text, .cash)
            #expect(result.isValid == false, "\(text)")
            #expect(result.price == nil, "\(text)")
            #expect(result.priceMessage == "Enter an E85 price between $1.00 and $8.00.", "\(text)")
            #expect(result.paymentMessage == nil)
        }
        #expect(check("1.00", .cash).isValid)
        #expect(check("8.00", .cash).isValid)
    }

    @Test("Both problems are reported together")
    func bothProblems() {
        let result = check("abc", nil)
        #expect(result.isValid == false)
        #expect(result.priceMessage != nil)
        #expect(result.paymentMessage != nil)
    }

    @Test("A station that cannot be reported to the community is not asked which price it is")
    func notRequiredWhenNotReporting() {
        let result = check("3.19", nil, required: false)
        #expect(result.isValid)
        #expect(result.paymentMessage == nil)
        #expect(result.paymentType == nil)
    }
}
