//
//  PriceAlertsFormTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B, extended in Phase 3C) — the At or Below price field and the form around
//  it (PriceAlertsPriceInput.swift, PriceAlertsForm.swift, PriceAlertsSensitivity.swift): exact
//  thousandths with no floating point, at most three decimals and never rounded, no negatives or
//  malformed text, the backend's own bounds, the two (and only two) kinds of alert the MVP offers, what
//  switching kinds keeps — and, for Phase 3C, the Cash / Credit choice (no default, never guessed for a
//  legacy alert) and the 5¢ / 10¢ / 20¢ / Custom drop size (new alerts 10¢, existing alerts untouched).
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

/// An alert as the server would send it, for seeding and comparing forms.
private func serverAlert(
    mode: String = "price_drop",
    threshold: String? = nil,
    minimumChange: String = "0.050",
    cooldownMinutes: Int = 360,
    payment: String? = nil
) throws -> PriceAlert {
    let object = BackendFixtures.alertObject(
        stationID: PriceAlertsStack.stationID(1),
        mode: mode,
        threshold: threshold,
        minimumChange: minimumChange,
        cooldownMinutes: cooldownMinutes,
        paymentType: payment
    )
    return try JSONDecoder().decode(PriceAlert.self, from: BackendFixtures.data(object))
}

struct PriceAlertFormTests {
    @Test("A new form is a Price Drop draft on the recommended 10¢, with no price and NO payment type chosen")
    func newFormDraft() {
        let form = PriceAlertForm()

        #expect(form.kind == .priceDrop)
        #expect(form.resolution == .rule(.priceDrop))
        #expect(form.rule == .priceDrop)
        #expect(form.showsPriceField == false)
        #expect(form.priceMessage == nil)
        #expect(form.payment == nil)
        #expect(form.sensitivity == .tenCents)
        #expect(form.minimumChange == PriceAlertAmount(thousandths: 100))
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
            // A payment type IS chosen, so the price is the only thing in the way.
            let form = PriceAlertForm(kind: .atOrBelow, priceText: text, payment: .cash)
            #expect(form.rule == nil, "\(text)")
            #expect(form.priceMessage == message, "\(text)")
            #expect(form.canSave(existing: nil) == false, "\(text)")
            #expect(form.saveBlocker(existing: nil) != .choosePayment, "\(text)")
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

    @Test("Switching kinds keeps the payment choice and the drop size too")
    func modeSwitch_retainsPaymentAndSensitivity() {
        var form = PriceAlertForm(kind: .priceDrop, priceText: "", payment: .credit, sensitivity: .twentyCents)
        form.select(.atOrBelow)
        #expect(form.payment == .credit)
        #expect(form.sensitivity == .twentyCents)
        #expect(form.showsSensitivity == false)
        form.select(.priceDrop)
        #expect(form.payment == .credit)
        #expect(form.sensitivity == .twentyCents)
        #expect(form.showsSensitivity)
    }

    @Test("Seeding from the server's alert: kind, price, payment type and drop size all come from the alert")
    func seeding_fromTheServersAlert() throws {
        #expect(PriceAlertForm(seededFrom: nil) == PriceAlertForm())

        let drop = try serverAlert(mode: "price_drop", minimumChange: "0.100", payment: "credit")
        #expect(PriceAlertForm(seededFrom: drop) == PriceAlertForm(kind: .priceDrop, priceText: "", payment: .credit, sensitivity: .tenCents))

        let target = try serverAlert(mode: "at_or_below", threshold: "3.499", minimumChange: "0.050", payment: "cash")
        #expect(PriceAlertForm(seededFrom: target) == PriceAlertForm(kind: .atOrBelow, priceText: "3.499", payment: .cash, sensitivity: .fiveCents))

        // An alert type this UI does not offer starts the kind at its default, keeps what it can read, and CARRIES the
        // alert's own rule so that saving it does not silently turn it into a Price Drop.
        let any = try serverAlert(mode: "any_change", minimumChange: "0.200", payment: "cash")
        #expect(PriceAlertForm(seededFrom: any) == PriceAlertForm(kind: .priceDrop, priceText: "", payment: .cash, sensitivity: .twentyCents, carriedRule: .anyChange))
        let future = try serverAlert(mode: "percent_drop", payment: "credit")
        #expect(PriceAlertForm(seededFrom: future).kind == .priceDrop)
    }

    @Test("An alert made before payment types existed seeds the form with NO payment chosen — nothing is guessed")
    func seeding_legacyAlertHasNoPayment() throws {
        for payment in [nil, "unknown", "same_for_both", "debit", ""] as [String?] {
            let legacy = try serverAlert(mode: "price_drop", payment: payment)
            let form = PriceAlertForm(seededFrom: legacy)
            #expect(form.payment == nil, "\(String(describing: payment))")
            #expect(form.canSave(existing: legacy) == false)
            #expect(form.saveBlocker(existing: legacy) == .choosePayment)
        }
    }

    @Test("An existing 5¢ alert shows as 5¢, an odd amount as Custom with its exact text — neither becomes 10¢")
    func seeding_keepsTheStoredDropSize() throws {
        let legacy = try serverAlert(minimumChange: "0.050", payment: "cash")
        #expect(PriceAlertForm(seededFrom: legacy).sensitivity == .fiveCents)
        #expect(PriceAlertForm(seededFrom: legacy).minimumChange == PriceAlertAmount(thousandths: 50))

        let twenty = try serverAlert(minimumChange: "0.200", payment: "cash")
        #expect(PriceAlertForm(seededFrom: twenty).sensitivity == .twentyCents)

        let odd = try serverAlert(minimumChange: "0.150", payment: "cash")
        let oddForm = PriceAlertForm(seededFrom: odd)
        #expect(oddForm.sensitivity == .custom)
        #expect(oddForm.customChangeText == "0.15")
        #expect(oddForm.minimumChange == PriceAlertAmount(thousandths: 150))

        let subCent = try serverAlert(minimumChange: "0.015", payment: "cash")
        #expect(PriceAlertForm(seededFrom: subCent).customChangeText == "0.015")
    }

    @Test("Saving is offered only for a complete form that differs from what the server holds")
    func canSave_requiresAChange() throws {
        let existing = try serverAlert(mode: "at_or_below", threshold: "3.250", minimumChange: "0.100", payment: "cash")
        var form = PriceAlertForm(seededFrom: existing)

        #expect(form.isUnchanged(from: existing))
        #expect(form.canSave(existing: existing) == false)
        #expect(form.saveBlocker(existing: existing) == .noChanges)

        form.priceText = "3.249"
        #expect(form.canSave(existing: existing))

        form.priceText = "3.250"
        #expect(form.isUnchanged(from: existing))
        #expect(form.canSave(existing: existing) == false)

        form.select(.priceDrop)
        #expect(form.canSave(existing: existing))

        // With no alert, or one this build cannot read, nothing is "unchanged".
        #expect(PriceAlertForm(payment: .cash).isUnchanged(from: nil) == false)
        let unreadable = try serverAlert(mode: "percent_drop", payment: "cash")
        #expect(PriceAlertForm(payment: .cash).isUnchanged(from: unreadable) == false)
    }

    @Test("A new alert cannot be saved until a payment type is chosen — then a Price Drop draft is savable as it stands")
    func newAlert_needsAnExplicitPayment() {
        var form = PriceAlertForm()
        #expect(form.canSave(existing: nil) == false)
        #expect(form.saveBlocker(existing: nil) == .choosePayment)

        form.select(payment: .credit)
        #expect(form.payment == .credit)
        #expect(form.canSave(existing: nil))
        #expect(form.saveBlocker(existing: nil) == nil)

        // An empty At or Below draft is still not savable, with a payment type chosen.
        #expect(PriceAlertForm(kind: .atOrBelow, payment: .cash).canSave(existing: nil) == false)
        #expect(PriceAlertForm(kind: .atOrBelow, payment: .cash).saveBlocker(existing: nil) == .needsPrice)
    }

    @Test("`unknown` is not a choice: selecting it does nothing, and a form cannot be built holding it")
    func unknownIsNeverChosen() {
        var form = PriceAlertForm()
        form.select(payment: .unknown)
        #expect(form.payment == nil)
        #expect(PriceAlertForm(payment: .unknown).payment == nil)

        form.select(payment: .cash)
        form.select(payment: .unknown)
        #expect(form.payment == .cash)
    }

    @Test("Changing only the payment type of an existing alert is a change that can be saved")
    func paymentOnlyChange() throws {
        let existing = try serverAlert(mode: "price_drop", minimumChange: "0.100", payment: "cash")
        var form = PriceAlertForm(seededFrom: existing)
        #expect(form.canSave(existing: existing) == false)

        form.select(payment: .credit)
        #expect(form.canSave(existing: existing))
        #expect(form.saveBlocker(existing: existing) == nil)

        form.select(payment: .cash)
        #expect(form.canSave(existing: existing) == false)
    }

    @Test("Choosing a payment type for a legacy alert makes it savable without touching anything else")
    func legacyAlert_isSavableOnceAPaymentIsChosen() throws {
        let legacy = try serverAlert(mode: "price_drop", minimumChange: "0.050", payment: "unknown")
        var form = PriceAlertForm(seededFrom: legacy)
        #expect(form.canSave(existing: legacy) == false)

        form.select(payment: .credit)
        #expect(form.canSave(existing: legacy))
        // Its 5¢ drop size and its cooldown are exactly what it had.
        let preferences = try #require(form.preferences(existing: legacy))
        #expect(preferences.minimumChange == PriceAlertAmount(thousandths: 50))
        #expect(preferences.cooldownMinutes == 360)
    }

    @Test("Changing only the drop size is a change that can be saved")
    func sensitivityOnlyChange() throws {
        let existing = try serverAlert(mode: "price_drop", minimumChange: "0.050", payment: "credit")
        var form = PriceAlertForm(seededFrom: existing)
        #expect(form.canSave(existing: existing) == false)

        form.select(sensitivity: .twentyCents)
        #expect(form.canSave(existing: existing))
        #expect(form.preferences(existing: existing)?.minimumChange == PriceAlertAmount(thousandths: 200))

        form.select(sensitivity: .fiveCents)
        #expect(form.canSave(existing: existing) == false)
    }

    @Test("A Custom drop size must be a valid amount before the form can be saved; the typed text survives switching away")
    func customDropSize_isValidated() throws {
        var form = PriceAlertForm(payment: .cash, sensitivity: .custom)
        #expect(form.showsCustomChangeField)
        #expect(form.changeResolution == .needsAmount)
        #expect(form.canSave(existing: nil) == false)
        #expect(form.saveBlocker(existing: nil) == .needsChangeAmount)
        #expect(form.changeMessage == nil, "empty is guidance, not an error")

        form.customChangeText = "0.15"
        #expect(form.minimumChange == PriceAlertAmount(thousandths: 150))
        #expect(form.canSave(existing: nil))
        #expect(form.preferences(existing: nil)?.minimumChange == PriceAlertAmount(thousandths: 150))

        form.customChangeText = "0.001"
        #expect(form.minimumChange == nil)
        #expect(form.canSave(existing: nil) == false)
        #expect(form.saveBlocker(existing: nil) == .invalidChangeAmount(.belowMinimum))
        #expect(form.changeMessage == PriceAlertMinimumChangeInput.message(for: .belowMinimum))

        // Picking a preset ignores (and keeps) the typed text; the error goes away because it no longer applies.
        form.select(sensitivity: .tenCents)
        #expect(form.customChangeText == "0.001")
        #expect(form.changeMessage == nil)
        #expect(form.canSave(existing: nil))
        form.select(sensitivity: .custom)
        #expect(form.changeMessage != nil)
    }

    @Test("At or Below never shows or validates a drop size, and sends the alert's own (or the new-alert default)")
    func atOrBelow_hasNoDropSize() throws {
        // A broken Custom amount is irrelevant to an At or Below alert.
        var form = PriceAlertForm(kind: .atOrBelow, priceText: "2.89", payment: .credit, sensitivity: .custom, customChangeText: "banana")
        #expect(form.showsSensitivity == false)
        #expect(form.showsCustomChangeField == false)
        #expect(form.changeMessage == nil)
        #expect(form.canSave(existing: nil))
        // New alert: the new-alert default, not whatever the hidden control held.
        #expect(form.preferences(existing: nil) == PriceAlertPreferences.newAlertDefaults)

        // Existing alert: its own preferences, untouched.
        let existing = try serverAlert(mode: "at_or_below", threshold: "2.790", minimumChange: "0.050", cooldownMinutes: 720, payment: "credit")
        form.priceText = "2.89"
        #expect(form.preferences(existing: existing) == existing.preferences)
        #expect(form.preferences(existing: existing)?.cooldownMinutes == 720)
    }

    @Test("A Price Drop keeps the existing alert's cooldown when only the drop size changes")
    func priceDrop_keepsTheCooldown() throws {
        let existing = try serverAlert(mode: "price_drop", minimumChange: "0.050", cooldownMinutes: 1_440, payment: "cash")
        var form = PriceAlertForm(seededFrom: existing)
        form.select(sensitivity: .twentyCents)
        let preferences = try #require(form.preferences(existing: existing))
        #expect(preferences.minimumChange == PriceAlertAmount(thousandths: 200))
        #expect(preferences.cooldownMinutes == 1_440)
    }

    @Test("A new alert starts at 10¢ and the 6-hour cooldown; the legacy defaults are still 5¢ and are untouched")
    func newAlertDefaults_versusLegacyDefaults() {
        #expect(PriceAlertPreferences.newAlertDefaults.minimumChange == PriceAlertAmount(thousandths: 100))
        #expect(PriceAlertPreferences.newAlertDefaults.cooldownMinutes == 360)
        #expect(PriceAlertPreferences.defaults.minimumChange == PriceAlertAmount(thousandths: 50))
        #expect(PriceAlertPreferences.defaults.cooldownMinutes == 360)
        #expect(PriceAlertForm().preferences(existing: nil) == PriceAlertPreferences.newAlertDefaults)
    }

    @Test("The save blocker names the first thing in the way, in the order a person decides")
    func saveBlockerOrder() throws {
        // Nothing chosen: payment comes first, even though the price is also missing.
        #expect(PriceAlertForm(kind: .atOrBelow).saveBlocker(existing: nil) == .choosePayment)
        // Payment chosen: the price is next.
        #expect(PriceAlertForm(kind: .atOrBelow, payment: .cash).saveBlocker(existing: nil) == .needsPrice)
        #expect(PriceAlertForm(kind: .atOrBelow, priceText: "x", payment: .cash).saveBlocker(existing: nil) == .invalidPrice(.notANumber))
        // Price Drop: the drop size is next.
        #expect(PriceAlertForm(payment: .cash, sensitivity: .custom).saveBlocker(existing: nil) == .needsChangeAmount)
        // A complete new alert has no blocker.
        #expect(PriceAlertForm(payment: .cash).saveBlocker(existing: nil) == nil)
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
    @Test("The limits are stated from the alert's own preferences, naming the price when one is chosen")
    func note_usesThePreferences() {
        let defaults = PriceAlertPreferences.defaults
        let timing = PriceAlertDeliveryNote.timingSentence
        #expect(PriceAlertDeliveryNote.text(for: .priceDrop, preferences: defaults)
            == "You'll be notified when the price falls by 5¢ or more, at most once every 6 hours for this station. \(timing)")
        #expect(PriceAlertDeliveryNote.text(for: .atOrBelow, preferences: defaults)
            == "You'll be notified when the price reaches your target, at most once every 6 hours for this station. \(timing)")

        let custom = PriceAlertPreferences(minimumChange: PriceAlertAmount(thousandths: 100), cooldownMinutes: 1_440)
        #expect(PriceAlertDeliveryNote.text(for: .priceDrop, preferences: custom).contains("10¢"))
        #expect(PriceAlertDeliveryNote.text(for: .priceDrop, preferences: custom).contains("once every day"))

        #expect(PriceAlertDeliveryNote.text(for: .priceDrop, payment: .credit, preferences: custom)
            == "You'll be notified when the Credit price falls by 10¢ or more, at most once every day for this station. \(timing)")
        #expect(PriceAlertDeliveryNote.text(for: .atOrBelow, payment: .cash, preferences: custom)
            == "You'll be notified when the Cash price reaches your target, at most once every day for this station. \(timing)")
        // `unknown` is not named: the note stays generic rather than claiming a price.
        #expect(PriceAlertDeliveryNote.text(for: .priceDrop, payment: .unknown, preferences: custom).contains("the price falls"))
    }

    @Test("The note says alerts are not instant")
    func note_saysNotInstant() {
        for kind in PriceAlertKind.allCases {
            let text = PriceAlertDeliveryNote.text(for: kind, payment: .cash, preferences: .newAlertDefaults)
            #expect(text.contains("aren't instant"))
            #expect(text.lowercased().contains("verified") == false)
        }
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

// MARK: - Payment type

struct PriceAlertPaymentTests {
    @Test("The identifiers are the backend's, and only Cash and Credit can be chosen")
    func identifiers() {
        #expect(PriceAlertPayment.cash.wireValue == "cash")
        #expect(PriceAlertPayment.credit.wireValue == "credit")
        #expect(PriceAlertPayment.unknown.wireValue == "unknown")
        #expect(PriceAlertPayment.choices == [.cash, .credit])
        let allSpecified = PriceAlertPayment.choices.allSatisfy { $0.isSpecified }
        #expect(allSpecified)
        #expect(PriceAlertPayment.unknown.isSpecified == false)
    }

    @Test("A missing, empty, differently-spelled or future value reads as unknown — never as cash or credit")
    func lenientReading() {
        #expect(PriceAlertPayment(wireValue: "cash") == .cash)
        #expect(PriceAlertPayment(wireValue: "credit") == .credit)
        for value in [nil, "", "Cash", "CREDIT", "same_for_both", "debit", " cash"] as [String?] {
            #expect(PriceAlertPayment(wireValue: value) == .unknown, "\(String(describing: value))")
        }
    }

    @Test("Words: Cash, Credit, and 'Payment type not set' for an alert that never chose")
    func words() {
        #expect(PriceAlertPayment.cash.title == "Cash")
        #expect(PriceAlertPayment.credit.title == "Credit")
        #expect(PriceAlertPayment.cash.priceTitle == "Cash price")
        #expect(PriceAlertPayment.credit.priceTitle == "Credit price")
        #expect(PriceAlertPayment.unknown.priceTitle == "Payment type not set")
    }

    @Test("An alert decodes its payment type; an old backend's response without the field decodes as unknown")
    func alertDecoding() throws {
        func decode(_ payment: String?) throws -> PriceAlert {
            try serverAlert(payment: payment)
        }
        #expect(try decode("cash").paymentType == .cash)
        #expect(try decode("credit").paymentType == .credit)
        #expect(try decode("unknown").paymentType == .unknown)
        #expect(try decode(nil).paymentType == .unknown)
        #expect(try decode("something_new").paymentType == .unknown)

        // null and a non-string never make the alert undecodable either.
        var object = BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(1))
        object["payment_type"] = NSNull()
        #expect(try JSONDecoder().decode(PriceAlert.self, from: BackendFixtures.data(object)).paymentType == .unknown)
        object["payment_type"] = 7
        #expect(try JSONDecoder().decode(PriceAlert.self, from: BackendFixtures.data(object)).paymentType == .unknown)
    }

    @Test("A listing decodes the comparable-price fields, and tolerates a backend that does not send them")
    func listingDecoding() throws {
        let alert = BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(1), paymentType: "credit")
        let withComparable = BackendFixtures.listRow(
            alert: alert,
            latestPrice: "2.990",
            latestComparable: (price: "3.090", reportedAt: "2026-10-06T09:00:00.000Z", paymentType: "same_for_both")
        )
        let listing = try BackendFixtures.decodeListing(withComparable)
        #expect(listing.alert.paymentType == .credit)
        #expect(listing.latestPrice == PriceAlertAmount(thousandths: 2_990))
        #expect(listing.latestComparablePrice == PriceAlertAmount(thousandths: 3_090))
        #expect(listing.latestComparablePaymentType == .sameForBoth)
        #expect(listing.latestComparableReportedAt != nil)

        let old = try BackendFixtures.decodeListing(BackendFixtures.listRow(alert: alert))
        #expect(old.latestComparablePrice == nil)
        #expect(old.latestComparablePaymentType == nil)
        #expect(old.latestPrice == PriceAlertAmount(thousandths: 3_149))

        let nothingYet = try BackendFixtures.decodeListing(BackendFixtures.listRow(
            alert: alert,
            latestPrice: nil,
            latestReportedAt: nil,
            latestComparable: (price: nil, reportedAt: nil, paymentType: nil)
        ))
        #expect(nothingYet.latestComparablePrice == nil)
    }
}

// MARK: - Drop size

struct PriceAlertSensitivityTests {
    @Test("Exactly four choices — 5¢, 10¢ (Recommended), 20¢, Custom — in that order")
    func choices() {
        #expect(PriceAlertSensitivity.allCases == [.fiveCents, .tenCents, .twentyCents, .custom])
        let titles = PriceAlertSensitivity.allCases.map { $0.title }
        let presets = PriceAlertSensitivity.allCases.map { $0.presetAmount }
        #expect(titles == ["5¢", "10¢", "20¢", "Custom"])
        #expect(presets == [
            PriceAlertAmount(thousandths: 50), PriceAlertAmount(thousandths: 100), PriceAlertAmount(thousandths: 200), nil,
        ])
        // Percentages are deliberately absent.
        #expect(titles.joined().contains("%") == false)
    }

    @Test("Only 10¢ is recommended, and it is the default for a new alert")
    func recommendation() {
        #expect(PriceAlertSensitivity.recommended == .tenCents)
        let recommended = PriceAlertSensitivity.allCases.filter { $0.isRecommended }
        #expect(recommended == [.tenCents])
        #expect(PriceAlertSensitivity.tenCents.detail == "Recommended")
        #expect(PriceAlertSensitivity.fiveCents.detail == nil)
        #expect(PriceAlertSensitivity.twentyCents.detail == nil)
        #expect(PriceAlertSensitivity.custom.detail == nil)
        #expect(PriceAlertSensitivity.tenCents.presetAmount == PriceAlertPreferences.newAlertDefaults.minimumChange)
    }

    @Test("A stored amount maps back to its preset, or to Custom")
    func matching() {
        #expect(PriceAlertSensitivity(matching: PriceAlertAmount(thousandths: 50)) == .fiveCents)
        #expect(PriceAlertSensitivity(matching: PriceAlertAmount(thousandths: 100)) == .tenCents)
        #expect(PriceAlertSensitivity(matching: PriceAlertAmount(thousandths: 200)) == .twentyCents)
        for thousandths in [10, 49, 51, 99, 101, 150, 199, 201, 1_000, 2_000] {
            #expect(PriceAlertSensitivity(matching: PriceAlertAmount(thousandths: thousandths)) == .custom, "\(thousandths)")
        }
        // The presets sit inside the backend's accepted range.
        for preset in PriceAlertSensitivity.allCases.compactMap({ $0.presetAmount }) {
            #expect(PriceAlertPreferences.minimumChangeRange.contains(preset))
        }
    }

    @Test("Amounts read as cents below a dollar and as dollars from there")
    func amountText() {
        func display(_ thousandths: Int) -> String { PriceAlertSensitivity.displayText(for: PriceAlertAmount(thousandths: thousandths)) }
        func spoken(_ thousandths: Int) -> String { PriceAlertSensitivity.spokenText(for: PriceAlertAmount(thousandths: thousandths)) }
        #expect(display(10) == "1¢")
        #expect(display(50) == "5¢")
        #expect(display(150) == "15¢")
        #expect(display(990) == "99¢")
        #expect(display(15) == "$0.015")
        #expect(display(1_000) == "$1.00")
        #expect(display(1_250) == "$1.25")
        #expect(display(2_000) == "$2.00")
        #expect(spoken(10) == "1 cent")
        #expect(spoken(100) == "10 cents")
        #expect(spoken(1_250) == "$1.25")
        #expect(PriceAlertSensitivity.tenCents.spokenTitle == "10 cents, recommended")
        #expect(PriceAlertSensitivity.fiveCents.spokenTitle == "5 cents")
        #expect(PriceAlertSensitivity.custom.spokenTitle == "Custom amount")
    }
}

struct PriceAlertMinimumChangeInputTests {
    private func parse(_ text: String) -> PriceAlertMinimumChangeInput.Result {
        PriceAlertMinimumChangeInput.parse(text)
    }

    private func valid(_ thousandths: Int) -> PriceAlertMinimumChangeInput.Result {
        .valid(PriceAlertAmount(thousandths: thousandths))
    }

    @Test("0.01 through 2.00 dollars are accepted at the edges and refused just beyond")
    func bounds() {
        #expect(parse("0.01") == valid(10))
        #expect(parse("0.010") == valid(10))
        #expect(parse("2") == valid(2_000))
        #expect(parse("2.00") == valid(2_000))
        #expect(parse("2.000") == valid(2_000))
        #expect(parse("0.009") == .invalid(.belowMinimum))
        #expect(parse("0") == .invalid(.belowMinimum))
        #expect(parse("2.001") == .invalid(.aboveMaximum))
        #expect(parse("50") == .invalid(.aboveMaximum))
        #expect(PriceAlertPreferences.minimumChangeRange == PriceAlertAmount(thousandths: 10)...PriceAlertAmount(thousandths: 2_000))
    }

    @Test("Exact thousandths: .15, 0.15, $0.15 and 0,15 are the same 15 cents; no floating point is involved")
    func exactness() {
        #expect(parse(".15") == valid(150))
        #expect(parse("0.15") == valid(150))
        #expect(parse("$0.15") == valid(150))
        #expect(parse("0,15") == valid(150))
        #expect(parse("0.075") == valid(75))
        #expect(parse("0.015") == valid(15))
        #expect(parse("1.005") == valid(1_005))
        #expect(parse("0.07") == valid(70))
    }

    @Test("A fourth decimal, negatives, text and blanks are handled like the target price")
    func malformed() {
        #expect(parse("0.1501") == .invalid(.tooManyDecimals))
        #expect(parse("0.1500") == .invalid(.tooManyDecimals))
        #expect(parse("-0.15") == .invalid(.negative))
        #expect(parse("abc") == .invalid(.notANumber))
        #expect(parse("1e1") == .invalid(.notANumber))
        #expect(parse("0.1.5") == .invalid(.notANumber))
        #expect(parse("") == .empty)
        #expect(parse("   ") == .empty)
        #expect(parse(String(repeating: "9", count: 400)) == .invalid(.aboveMaximum))
    }

    @Test("What a field shows round-trips for every valid amount")
    func roundTrip() {
        for thousandths in stride(from: 10, through: 2_000, by: 3) {
            let amount = PriceAlertAmount(thousandths: thousandths)
            #expect(parse(PriceAlertPriceInput.editableText(for: amount)) == .valid(amount), "\(thousandths)")
        }
    }

    @Test("The words quote the same bounds the backend enforces")
    func words() {
        #expect(PriceAlertMinimumChangeInput.allowedRangeText == "$0.01 and $2.00")
        #expect(PriceAlertMinimumChangeInput.message(for: .belowMinimum) == "Enter an amount between $0.01 and $2.00.")
        #expect(PriceAlertMinimumChangeInput.message(for: .aboveMaximum) == PriceAlertMinimumChangeInput.message(for: .belowMinimum))
        #expect(PriceAlertMinimumChangeInput.message(for: .negative).contains("negative"))
        #expect(PriceAlertMinimumChangeInput.message(for: .tooManyDecimals).contains("3 decimal"))
        #expect(PriceAlertMinimumChangeInput.message(for: .notANumber).contains("numbers"))
        #expect(PriceAlertMinimumChangeInput.emptyHint.contains("$0.01"))
        #expect(PriceAlertMinimumChangeInput.emptyHint.contains("$2.00"))
    }
}

// MARK: - Describing what an alert watches

struct PriceAlertWatchTests {
    @Test("A Cash alert and a Credit alert say which price they watch; a Price Drop adds its drop size")
    func specifiedAlerts() throws {
        let cashDrop = PriceAlertWatch(alert: try serverAlert(mode: "price_drop", minimumChange: "0.100", payment: "cash"))
        #expect(cashDrop.paymentLine == "Watching the Cash price")
        #expect(cashDrop.dropLine == "Notifies on a drop of 10¢ or more")
        #expect(cashDrop.shortText == "Cash price · 10¢ drop")
        #expect(cashDrop.needsPaymentChoice == false)
        #expect(cashDrop.spokenText == "Cash price. Notifies on a drop of 10¢ or more")

        let creditTarget = PriceAlertWatch(alert: try serverAlert(mode: "at_or_below", threshold: "2.890", payment: "credit"))
        #expect(creditTarget.paymentLine == "Watching the Credit price")
        #expect(creditTarget.dropLine == nil, "At or Below has no drop size")
        #expect(creditTarget.shortText == "Credit price")
    }

    @Test("A legacy alert says its payment type is not set, and never claims Cash or Credit")
    func legacyAlert() throws {
        for payment in [nil, "unknown"] as [String?] {
            let watch = PriceAlertWatch(alert: try serverAlert(mode: "price_drop", minimumChange: "0.050", payment: payment))
            #expect(watch.needsPaymentChoice)
            #expect(watch.paymentLine == "Payment type not set")
            #expect(watch.shortText == "Payment type not set · 5¢ drop")
            #expect(watch.shortText.contains("Cash") == false)
            #expect(watch.shortText.contains("Credit") == false)
        }
    }

    @Test("A drop size of an unusual amount is shown exactly")
    func oddAmounts() throws {
        #expect(PriceAlertWatch(alert: try serverAlert(minimumChange: "0.150", payment: "cash")).dropText == "15¢")
        #expect(PriceAlertWatch(alert: try serverAlert(minimumChange: "0.015", payment: "cash")).dropText == "$0.015")
        #expect(PriceAlertWatch(alert: try serverAlert(minimumChange: "1.250", payment: "cash")).dropText == "$1.25")
    }
}
