//
//  PriceAlertsFormTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B) — the At or Below price field and the form around it
//  (PriceAlertsPriceInput.swift, PriceAlertsForm.swift): exact thousandths with no floating point,
//  at most three decimals and never rounded, no negatives or malformed text, the backend's own
//  bounds, the two (and only two) kinds of alert the MVP offers, and what switching kinds keeps.
//
//  Pure value logic: no network, no Keychain, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private func parse(_ text: String) -> PriceAlertPriceInput.Result {
    PriceAlertPriceInput.parse(text)
}

private func valid(_ thousandths: Int) -> PriceAlertPriceInput.Result {
    .valid(PriceAlertAmount(thousandths: thousandths))
}

// MARK: - Parsing

struct PriceAlertsPriceInputTests {
    @Test("Valid prices become exact thousandths — including three decimals — with no floating-point drift")
    func validPrices_areExact() {
        #expect(parse("3.25") == valid(3_250))
        #expect(parse("3.499") == valid(3_499))
        #expect(parse("3.5") == valid(3_500))
        #expect(parse("4") == valid(4_000))
        #expect(parse("2.999") == valid(2_999))
        #expect(parse("1.001") == valid(1_001))
        // Values whose binary floating-point forms are inexact stay exact here.
        #expect(parse("2.675") == valid(2_675))
        #expect(parse("1.005") == valid(1_005))
        #expect(parse("0007.250") == valid(7_250))
    }

    @Test("The bounds the backend enforces are accepted at the edge and refused just beyond")
    func bounds_matchTheBackend() {
        #expect(parse("1") == valid(1_000))
        #expect(parse("1.000") == valid(1_000))
        #expect(parse("8") == valid(8_000))
        #expect(parse("8.000") == valid(8_000))
        #expect(parse("0.999") == .invalid(.belowMinimum))
        #expect(parse("8.001") == .invalid(.aboveMaximum))
        #expect(parse("0") == .invalid(.belowMinimum))
        #expect(parse("100") == .invalid(.aboveMaximum))
        // The bounds are the shared constant, not numbers repeated here.
        #expect(PriceAlertRule.thresholdRange == PriceAlertAmount(thousandths: 1_000)...PriceAlertAmount(thousandths: 8_000))
    }

    @Test("A fourth decimal place is refused, never rounded into a different number")
    func fourDecimals_areRefused() {
        #expect(parse("3.2501") == .invalid(.tooManyDecimals))
        #expect(parse("3.4999") == .invalid(.tooManyDecimals))
        // Even a harmless trailing zero: the rule is three places, and what is typed is what is meant.
        #expect(parse("3.2500") == .invalid(.tooManyDecimals))
        #expect(parse("3.25000") == .invalid(.tooManyDecimals))
    }

    @Test("Negative prices are refused with their own reason")
    func negatives_areRefused() {
        #expect(parse("-3.25") == .invalid(.negative))
        #expect(parse("-1") == .invalid(.negative))
        #expect(parse("-0") == .invalid(.negative))
        #expect(parse("\u{2212}3.25") == .invalid(.negative))
        #expect(parse("  -3.25  ") == .invalid(.negative))
        // Any leading minus is a negative price, however it is repeated.
        #expect(parse("--3") == .invalid(.negative))
    }

    @Test("Malformed text is refused: letters, symbols, exponents, repeated marks, inner spaces, other numerals")
    func malformed_isRefused() {
        let malformed = [
            "abc", "3.2x", "x3.25", "nan", "NaN", "inf", "Infinity", "1e3", "1E3", "0x10",
            "3.2.1", "3..2", "..", ".", ",", "$", "$$3", "3 25", "3. 25", "+3.25", "3-",
            "1,234.5", "1.234,5", "3,2,5", "\u{0663}.\u{0662}\u{0665}", "3.25\u{0663}", "½", "3\u{2024}25",
        ]
        for text in malformed {
            #expect(parse(text) == .invalid(.notANumber), "\(text.debugDescription) should be refused")
        }
    }

    @Test("Blank input is 'not entered yet' — neither valid nor an error")
    func blank_isEmpty() {
        #expect(parse("") == .empty)
        #expect(parse("   ") == .empty)
        #expect(parse("\n\t ") == .empty)
    }

    @Test("A pasted '$', surrounding whitespace, a trailing decimal point and a comma decimal mark are all read as intended")
    func tolerableForms_areRead() {
        #expect(parse("$3.25") == valid(3_250))
        #expect(parse("  3.25  ") == valid(3_250))
        #expect(parse("3.") == valid(3_000))
        #expect(parse("3,25") == valid(3_250))
        #expect(parse("3,499") == valid(3_499))
        #expect(parse(".5") == .invalid(.belowMinimum))
    }

    @Test("An absurdly long number cannot overflow: it is simply too large")
    func hugeNumbers_areSafe() {
        #expect(parse("99999999999999999999999999") == .invalid(.aboveMaximum))
        #expect(parse(String(repeating: "9", count: 400)) == .invalid(.aboveMaximum))
        #expect(parse("3." + String(repeating: "9", count: 400)) == .invalid(.tooManyDecimals))
    }

    @Test("Text for an amount shows two decimals, and a third only when it matters — never a rounded value")
    func editableText_isFaithful() {
        func text(_ thousandths: Int) -> String { PriceAlertPriceInput.editableText(for: PriceAlertAmount(thousandths: thousandths)) }
        #expect(text(3_250) == "3.25")
        #expect(text(3_000) == "3.00")
        #expect(text(3_499) == "3.499")
        #expect(text(3_005) == "3.005")
        #expect(text(1_001) == "1.001")
        #expect(text(8_000) == "8.00")
        #expect(PriceAlertPriceInput.displayText(for: PriceAlertAmount(thousandths: 3_499)) == "$3.499")
        #expect(PriceAlertPriceInput.displayText(for: PriceAlertAmount(thousandths: 3_490)) == "$3.49")
    }

    @Test("What the field shows round-trips: parsing the text of any valid amount gives the same amount")
    func editableText_roundTrips() {
        for thousandths in stride(from: 1_000, through: 8_000, by: 7) {
            let amount = PriceAlertAmount(thousandths: thousandths)
            #expect(parse(PriceAlertPriceInput.editableText(for: amount)) == .valid(amount))
        }
    }

    @Test("Messages are specific, speak in dollars, and quote the same bounds the backend enforces")
    func messages_areSpecific() {
        #expect(PriceAlertPriceInput.allowedRangeText == "$1.00 and $8.00")
        #expect(PriceAlertPriceInput.message(for: .belowMinimum) == "Enter a price between $1.00 and $8.00.")
        #expect(PriceAlertPriceInput.message(for: .aboveMaximum) == PriceAlertPriceInput.message(for: .belowMinimum))
        #expect(PriceAlertPriceInput.message(for: .negative).contains("negative"))
        #expect(PriceAlertPriceInput.message(for: .tooManyDecimals).contains("3 decimal"))
        #expect(PriceAlertPriceInput.message(for: .notANumber).contains("numbers"))
        #expect(PriceAlertPriceInput.emptyHint.contains("$1.00"))
        #expect(PriceAlertPriceInput.emptyHint.contains("$8.00"))
    }
}

// MARK: - The two kinds

struct PriceAlertKindTests {
    @Test("The MVP offers exactly Price Drop and At or Below — never Any Change")
    func exactlyTwoKinds() {
        #expect(PriceAlertKind.allCases == [.priceDrop, .atOrBelow])
        #expect(PriceAlertKind.allCases.map(\.title) == ["Price Drop", "At or Below"])
        let combined = PriceAlertKind.allCases.map { "\($0.title) \($0.detail)" }.joined().lowercased()
        #expect(combined.contains("any change") == false)
        #expect(combined.contains("any_change") == false)
    }

    @Test("Each kind carries the product's copy, word for word")
    func copy_isExact() {
        #expect(PriceAlertKind.priceDrop.detail == "Notify me when this station reports a lower E85 price.")
        #expect(PriceAlertKind.atOrBelow.detail == "Notify me when E85 reaches my target price.")
    }

    @Test("Whatever is typed, the form can only ever produce Price Drop or At or Below — never any_change")
    func form_neverProducesAnyChange() {
        let texts = ["", "3", "3.25", "abc", "-1", "9", "3.2501"]
        for kind in PriceAlertKind.allCases {
            for text in texts {
                let form = PriceAlertForm(kind: kind, priceText: text)
                if let rule = form.rule {
                    #expect(rule.mode == .priceDrop || rule.mode == .atOrBelow)
                    #expect(rule != .anyChange)
                    #expect(rule.isOfferedInMVP)
                }
            }
        }
    }
}

// MARK: - The form

struct PriceAlertFormTests {
    @Test("A new form is a Price Drop draft: complete as it stands, with no price")
    func priceDropDraft() {
        let form = PriceAlertForm()

        #expect(form.kind == .priceDrop)
        #expect(form.resolution == .rule(.priceDrop))
        #expect(form.rule == .priceDrop)
        #expect(form.showsPriceField == false)
        #expect(form.priceMessage == nil)
        // Price Drop has no threshold: a price typed while another kind was selected is never sent.
        #expect(PriceAlertForm(kind: .priceDrop, priceText: "3.25").rule?.thresholdPrice == nil)
    }

    @Test("An At or Below draft needs a price; with a valid one it is a complete rule")
    func atOrBelowDraft() {
        var form = PriceAlertForm(kind: .atOrBelow)
        #expect(form.showsPriceField)
        #expect(form.resolution == .needsPrice)
        #expect(form.rule == nil)
        #expect(form.priceMessage == nil)

        form.priceText = "3.25"
        #expect(form.resolution == .rule(.atOrBelow(PriceAlertAmount(thousandths: 3_250))))
        #expect(form.rule?.thresholdPrice == PriceAlertAmount(thousandths: 3_250))
    }

    @Test("A wrong price is explained before anything is saved, and blocks the rule")
    func invalidPrice_isExplainedBeforeSaving() {
        let cases: [(String, String)] = [
            ("abc", PriceAlertPriceInput.message(for: .notANumber)),
            ("-3", PriceAlertPriceInput.message(for: .negative)),
            ("3.2501", PriceAlertPriceInput.message(for: .tooManyDecimals)),
            ("0.5", PriceAlertPriceInput.message(for: .belowMinimum)),
            ("12", PriceAlertPriceInput.message(for: .aboveMaximum)),
        ]
        for (text, message) in cases {
            let form = PriceAlertForm(kind: .atOrBelow, priceText: text)
            #expect(form.rule == nil, "\(text)")
            #expect(form.priceMessage == message, "\(text)")
            #expect(form.canSave(existingRule: nil) == false, "\(text)")
        }
    }

    @Test("Switching kinds keeps the typed price, so switching back restores it; the price is simply not part of Price Drop")
    func modeSwitch_retainsThePrice() {
        var form = PriceAlertForm(kind: .atOrBelow, priceText: "3.25")

        form.select(.priceDrop)
        #expect(form.kind == .priceDrop)
        #expect(form.priceText == "3.25")
        #expect(form.rule == .priceDrop)
        #expect(form.showsPriceField == false)

        form.select(.atOrBelow)
        #expect(form.priceText == "3.25")
        #expect(form.rule == .atOrBelow(PriceAlertAmount(thousandths: 3_250)))
    }

    @Test("Seeding from the server's alert: Price Drop has no price; At or Below shows its exact threshold")
    func seeding_fromTheServersRule() {
        #expect(PriceAlertForm(seededFrom: .priceDrop) == PriceAlertForm(kind: .priceDrop, priceText: ""))
        #expect(PriceAlertForm(seededFrom: .atOrBelow(PriceAlertAmount(thousandths: 3_499))) == PriceAlertForm(kind: .atOrBelow, priceText: "3.499"))
        // No alert, an alert type this UI does not offer, and one it cannot read all start at the default.
        #expect(PriceAlertForm(seededFrom: nil) == PriceAlertForm())
        #expect(PriceAlertForm(seededFrom: .anyChange) == PriceAlertForm())
    }

    @Test("Saving is offered only for a complete form that differs from what the server holds")
    func canSave_requiresAChange() {
        let existing = PriceAlertRule.atOrBelow(PriceAlertAmount(thousandths: 3_250))
        var form = PriceAlertForm(seededFrom: existing)

        #expect(form.isUnchanged(from: existing))
        #expect(form.canSave(existingRule: existing) == false)

        form.priceText = "3.249"
        #expect(form.canSave(existingRule: existing))

        form.priceText = "3.250"
        #expect(form.isUnchanged(from: existing))
        #expect(form.canSave(existingRule: existing) == false)

        form.select(.priceDrop)
        #expect(form.canSave(existingRule: existing))

        // No alert yet: a Price Drop draft is savable as it stands, an empty At or Below one is not.
        #expect(PriceAlertForm().canSave(existingRule: nil))
        #expect(PriceAlertForm(kind: .atOrBelow).canSave(existingRule: nil) == false)
        // With no alert, or one this build cannot read, nothing is "unchanged".
        #expect(PriceAlertForm().isUnchanged(from: nil) == false)
    }
}

// MARK: - Describing alerts

struct PriceAlertSummaryTests {
    private func summary(mode: String, threshold: String? = nil) throws -> PriceAlertSummary {
        let object = BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(1), mode: mode, threshold: threshold)
        let alert = try JSONDecoder().decode(PriceAlert.self, from: BackendFixtures.data(object))
        return PriceAlertSummary(alert: alert)
    }

    @Test("The alerts this UI creates are described in the product's words")
    func knownModes() throws {
        let drop = try summary(mode: "price_drop")
        #expect(drop == .priceDrop)
        #expect(drop.title == "Price Drop")
        #expect(drop.detail == PriceAlertKind.priceDrop.detail)

        let target = try summary(mode: "at_or_below", threshold: "3.499")
        #expect(target == .atOrBelow(PriceAlertAmount(thousandths: 3_499)))
        #expect(target.title == "At or below $3.499")
        #expect(target.detail == PriceAlertKind.atOrBelow.detail)
        #expect(try summary(mode: "at_or_below", threshold: "3.250").title == "At or below $3.25")
    }

    @Test("An alert created elsewhere as Any Change is shown, not hidden — but is not something this UI offers")
    func anyChange_isShown() throws {
        let any = try summary(mode: "any_change")
        #expect(any == .anyChange)
        #expect(any.title == "Any price change")
        #expect(any.isOfferedInMVP == false)
    }

    @Test("An unknown future mode — or At or Below with no price — displays safely as a custom alert")
    func unknownMode_isSafe() throws {
        let future = try summary(mode: "percent_drop")
        #expect(future == .unrecognized)
        #expect(future.title == "Custom alert")
        #expect(future.detail.contains("replaces it"))
        #expect(future.isOfferedInMVP == false)

        #expect(try summary(mode: "at_or_below", threshold: nil) == .unrecognized)
        #expect(try summary(mode: "price_drop").isOfferedInMVP)
    }
}

struct PriceAlertDeliveryNoteTests {
    @Test("The limits are stated from the alert's own preferences")
    func note_usesThePreferences() {
        let defaults = PriceAlertPreferences.defaults
        #expect(PriceAlertDeliveryNote.text(for: .priceDrop, preferences: defaults)
            == "You'll be notified when the price falls by $0.05 or more, at most once every 6 hours for this station.")
        #expect(PriceAlertDeliveryNote.text(for: .atOrBelow, preferences: defaults)
            == "You'll be notified when the price reaches your target, at most once every 6 hours for this station.")

        let custom = PriceAlertPreferences(minimumChange: PriceAlertAmount(thousandths: 100), cooldownMinutes: 1_440)
        #expect(PriceAlertDeliveryNote.text(for: .priceDrop, preferences: custom).contains("$0.10"))
        #expect(PriceAlertDeliveryNote.text(for: .priceDrop, preferences: custom).contains("once every day"))
    }

    @Test("Durations read naturally")
    func durations() {
        #expect(PriceAlertDeliveryNote.durationText(minutes: 60) == "hour")
        #expect(PriceAlertDeliveryNote.durationText(minutes: 360) == "6 hours")
        #expect(PriceAlertDeliveryNote.durationText(minutes: 1_440) == "day")
        #expect(PriceAlertDeliveryNote.durationText(minutes: 4_320) == "3 days")
        #expect(PriceAlertDeliveryNote.durationText(minutes: 90) == "90 minutes")
        // Not reachable through the backend's 60-minute floor, but never ungrammatical or zero.
        #expect(PriceAlertDeliveryNote.durationText(minutes: 1) == "minute")
        #expect(PriceAlertDeliveryNote.durationText(minutes: 0) == "minute")
    }
}
