//
//  PriceAlertsForm.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B, extended in Phase 3C). The state of the Price Alert form and
//  the words that describe an alert, with no view in sight. Pure Foundation.
//
//  WHAT THE MVP OFFERS. Two kinds of alert, and only two:
//    - Price Drop    — "Notify me when this station reports a lower E85 price."
//    - At or Below   — "Notify me when E85 reaches my target price." (needs a price)
//  The backend also has `any_change`; it is deliberately not offered (PriceAlertRule.isOfferedInMVP).
//  Price Drop has NO threshold and NO percentage on the backend, so the form has none for it.
//
//  PHASE 3C ADDS TWO CHOICES TO BOTH KINDS (and one more to Price Drop):
//    - WHICH PRICE: Cash or Credit. An alert watches one of them, and the server compares it only with
//      reports of that price (a "same for both" report counts for either). There is NO DEFAULT: a new alert
//      cannot be saved until a person picks one, so a price is never silently labelled Credit (or Cash).
//      An alert made before payment types existed reads as "not set", the form starts with nothing
//      chosen, and a change to it asks for a choice rather than guessing one.
//    - HOW BIG A DROP (Price Drop only): 5¢, 10¢ (Recommended), 20¢ or a Custom amount. A NEW alert starts
//      on 10¢; an alert that exists keeps what it holds. At or Below has no drop size, so the form neither
//      shows nor changes one: a new At or Below alert is stored with the new-alert default, an existing one
//      keeps its own.
//
//  THE FORM NEVER CARRIES A SECOND COPY OF THE SERVER'S ALERT. It holds what the person is editing;
//  the alert itself is whatever PriceAlertsService.alerts says (the server is authoritative). The form
//  is seeded from that, and re-seeded after a save or turn-off.
//
//  SWITCHING KINDS KEEPS WHAT WAS TYPED. Choosing Price Drop and then At or Below again brings the
//  number back, so a mis-tap costs nothing. The price is simply not part of a Price Drop alert, so it
//  is never sent for one. (After a successful save the form is re-seeded from the server, which is
//  what clears it for a Price Drop alert.)
//

import Foundation

// MARK: - Kind

nonisolated enum PriceAlertKind: String, CaseIterable, Identifiable, Equatable, Sendable {
    case priceDrop
    case atOrBelow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .priceDrop: return "Price Drop"
        case .atOrBelow: return "At or Below"
        }
    }

    /// The one-line description the product specified for each choice.
    var detail: String {
        switch self {
        case .priceDrop: return "Notify me when this station reports a lower E85 price."
        case .atOrBelow: return "Notify me when E85 reaches my target price."
        }
    }

    var systemImage: String {
        switch self {
        case .priceDrop: return "arrow.down.circle"
        case .atOrBelow: return "dollarsign.circle"
        }
    }
}

// MARK: - Form

nonisolated struct PriceAlertForm: Equatable, Sendable {
    enum Resolution: Equatable, Sendable {
        /// A complete alert, ready to send.
        case rule(PriceAlertRule)
        /// At or Below with nothing typed yet.
        case needsPrice
        case invalid(PriceAlertPriceInput.Problem)
    }

    /// The drop size, as far as the form can tell.
    enum ChangeResolution: Equatable, Sendable {
        case amount(PriceAlertAmount)
        /// Custom with nothing typed yet.
        case needsAmount
        case invalid(PriceAlertPriceInput.Problem)
    }

    /// The first thing standing between the form and a save — what a dimmed Save button should say.
    enum SaveBlocker: Equatable, Sendable {
        case choosePayment
        case needsPrice
        case invalidPrice(PriceAlertPriceInput.Problem)
        case needsChangeAmount
        case invalidChangeAmount(PriceAlertPriceInput.Problem)
        /// Everything is valid and exactly what the server already holds.
        case noChanges
    }

    var kind: PriceAlertKind
    var priceText: String
    /// The price this alert watches. `nil` until the person chooses: there is no default.
    var payment: PriceAlertPayment?
    var sensitivity: PriceAlertSensitivity
    /// What was typed for a Custom drop size. Kept when another choice is picked, like the target price.
    var customChangeText: String

    init(
        kind: PriceAlertKind = .priceDrop,
        priceText: String = "",
        payment: PriceAlertPayment? = nil,
        sensitivity: PriceAlertSensitivity = .recommended,
        customChangeText: String = ""
    ) {
        self.kind = kind
        self.priceText = priceText
        self.payment = payment?.isSpecified == true ? payment : nil
        self.sensitivity = sensitivity
        self.customChangeText = customChangeText
    }

    /// Seeds the form from the alert the server holds (`nil`: there is none — a fresh form, with the new-alert
    /// drop size and no price chosen). A rule this build does not offer (`any_change`) or cannot read (an
    /// unknown or malformed mode) starts the kind at its default rather than pretending to edit it. A payment
    /// type of `unknown` (an alert made before payment types existed) starts as NOT CHOSEN. The drop size is
    /// read from the alert, so a legacy 5¢ alert shows as 5¢ and an unusual amount as Custom.
    init(seededFrom alert: PriceAlert?) {
        guard let alert else {
            self.init()
            return
        }
        var kind = PriceAlertKind.priceDrop
        var priceText = ""
        switch alert.rule {
        case .priceDrop?:
            break
        case .atOrBelow(let amount)?:
            kind = .atOrBelow
            priceText = PriceAlertPriceInput.editableText(for: amount)
        case .anyChange?, nil:
            break
        }
        let sensitivity = PriceAlertSensitivity(matching: alert.minimumChange)
        self.init(
            kind: kind,
            priceText: priceText,
            payment: alert.paymentType,
            sensitivity: sensitivity,
            customChangeText: sensitivity == .custom ? PriceAlertPriceInput.editableText(for: alert.minimumChange) : ""
        )
    }

    var showsPriceField: Bool {
        kind == .atOrBelow
    }

    /// The drop size only means something to a Price Drop alert.
    var showsSensitivity: Bool {
        kind == .priceDrop
    }

    var showsCustomChangeField: Bool {
        showsSensitivity && sensitivity == .custom
    }

    // MARK: Rule

    var resolution: Resolution {
        switch kind {
        case .priceDrop:
            return .rule(.priceDrop)
        case .atOrBelow:
            switch PriceAlertPriceInput.parse(priceText) {
            case .empty: return .needsPrice
            case .valid(let amount): return .rule(.atOrBelow(amount))
            case .invalid(let problem): return .invalid(problem)
            }
        }
    }

    /// The alert this form describes, or `nil` while it is incomplete or invalid.
    var rule: PriceAlertRule? {
        if case .rule(let rule) = resolution { return rule }
        return nil
    }

    /// Text for a price that has been typed and is wrong. `nil` for an empty field (guidance, not an
    /// error), for a valid price, and for Price Drop.
    var priceMessage: String? {
        guard case .invalid(let problem) = resolution else { return nil }
        return PriceAlertPriceInput.message(for: problem)
    }

    // MARK: Drop size

    var changeResolution: ChangeResolution {
        if let preset = sensitivity.presetAmount {
            return .amount(preset)
        }
        switch PriceAlertMinimumChangeInput.parse(customChangeText) {
        case .empty: return .needsAmount
        case .valid(let amount): return .amount(amount)
        case .invalid(let problem): return .invalid(problem)
        }
    }

    /// The drop size chosen, or `nil` while a Custom amount is empty or wrong.
    var minimumChange: PriceAlertAmount? {
        if case .amount(let amount) = changeResolution { return amount }
        return nil
    }

    /// Text for a Custom amount that has been typed and is wrong. `nil` for an empty field, a valid amount,
    /// a preset, and At or Below.
    var changeMessage: String? {
        guard showsCustomChangeField, case .invalid(let problem) = changeResolution else { return nil }
        return PriceAlertMinimumChangeInput.message(for: problem)
    }

    // MARK: What would be sent

    /// The preferences a save would send, or `nil` while a Custom drop size is incomplete or invalid.
    /// - Price Drop sends the drop size chosen here.
    /// - At or Below has no drop size on screen, so it sends what the alert already has — or, for a new
    ///   alert, the new-alert default. The cooldown is never edited here: an existing alert keeps its own.
    func preferences(existing: PriceAlert?) -> PriceAlertPreferences? {
        let base = existing?.preferences ?? .newAlertDefaults
        switch kind {
        case .atOrBelow:
            return base
        case .priceDrop:
            guard let minimumChange else { return nil }
            return PriceAlertPreferences(minimumChange: minimumChange, cooldownMinutes: base.cooldownMinutes)
        }
    }

    /// Whether saving would change nothing: the form describes exactly the alert the server already holds —
    /// the same kind and price, the same payment type, and (for Price Drop) the same drop size. `false`
    /// whenever there is no alert, the alert's mode is one this build cannot read, or the form is incomplete.
    func isUnchanged(from existing: PriceAlert?) -> Bool {
        guard let existing, let existingRule = existing.rule, let rule, let payment else { return false }
        guard rule == existingRule, payment == existing.paymentType else { return false }
        if kind == .priceDrop {
            return minimumChange == existing.minimumChange
        }
        return true
    }

    /// The first reason Save is unavailable, or `nil` when it is available.
    func saveBlocker(existing: PriceAlert?) -> SaveBlocker? {
        if payment?.isSpecified != true { return .choosePayment }
        switch resolution {
        case .needsPrice: return .needsPrice
        case .invalid(let problem): return .invalidPrice(problem)
        case .rule: break
        }
        if kind == .priceDrop {
            switch changeResolution {
            case .needsAmount: return .needsChangeAmount
            case .invalid(let problem): return .invalidChangeAmount(problem)
            case .amount: break
            }
        }
        return isUnchanged(from: existing) ? .noChanges : nil
    }

    func canSave(existing: PriceAlert?) -> Bool {
        saveBlocker(existing: existing) == nil
    }

    // MARK: Editing

    /// Picks a kind. The typed price is kept — see this file's header.
    mutating func select(_ newKind: PriceAlertKind) {
        kind = newKind
    }

    /// Picks the price to watch. `.unknown` is not a choice and is ignored.
    mutating func select(payment newPayment: PriceAlertPayment) {
        guard newPayment.isSpecified else { return }
        payment = newPayment
    }

    /// Picks a drop size. What was typed for Custom is kept.
    mutating func select(sensitivity newSensitivity: PriceAlertSensitivity) {
        sensitivity = newSensitivity
    }
}

// MARK: - Describing an alert

/// What an alert the server holds is, in words — including the ones the MVP cannot create.
nonisolated enum PriceAlertSummary: Equatable, Sendable {
    case priceDrop
    case atOrBelow(PriceAlertAmount)
    /// Supported by the backend, not offered by this UI. Shown, never hidden.
    case anyChange
    /// A mode this build does not know (a newer backend), or `at_or_below` without a threshold.
    case unrecognized

    init(alert: PriceAlert) {
        switch alert.rule {
        case .priceDrop?: self = .priceDrop
        case .atOrBelow(let amount)?: self = .atOrBelow(amount)
        case .anyChange?: self = .anyChange
        case nil: self = .unrecognized
        }
    }

    var title: String {
        switch self {
        case .priceDrop: return "Price Drop"
        case .atOrBelow(let amount): return "At or below \(PriceAlertPriceInput.displayText(for: amount))"
        case .anyChange: return "Any price change"
        case .unrecognized: return "Custom alert"
        }
    }

    var detail: String {
        switch self {
        case .priceDrop: return PriceAlertKind.priceDrop.detail
        case .atOrBelow: return PriceAlertKind.atOrBelow.detail
        case .anyChange: return "Notify me when this station's E85 price changes."
        case .unrecognized:
            return "This alert uses a setting this version of 85Blends can't show. Choosing an alert type below replaces it."
        }
    }

    /// Whether the form can stand in for this alert. `false` for the two this UI does not offer.
    var isOfferedInMVP: Bool {
        switch self {
        case .priceDrop, .atOrBelow: return true
        case .anyChange, .unrecognized: return false
        }
    }
}

/// Which price an alert the server holds watches, and how big a drop it waits for — the part of its
/// description that `PriceAlertSummary` (the kind) does not carry.
nonisolated struct PriceAlertWatch: Equatable, Sendable {
    let payment: PriceAlertPayment
    /// The drop a Price Drop alert waits for ("10¢"); `nil` for any other kind.
    let dropText: String?

    init(alert: PriceAlert) {
        payment = alert.paymentType
        if case .priceDrop? = alert.rule {
            dropText = PriceAlertSensitivity.displayText(for: alert.minimumChange)
        } else {
            dropText = nil
        }
    }

    /// An alert whose payment type was never set (made before payment types existed) needs one chosen.
    var needsPaymentChoice: Bool {
        payment.isSpecified == false
    }

    /// "Watching the Cash price", "Watching the Credit price", "Payment type not set".
    var paymentLine: String {
        switch payment {
        case .cash: return "Watching the Cash price"
        case .credit: return "Watching the Credit price"
        case .unknown: return "Payment type not set"
        }
    }

    /// "Notifies on a drop of 10¢ or more"; `nil` unless this is a Price Drop alert.
    var dropLine: String? {
        dropText.map { "Notifies on a drop of \($0) or more" }
    }

    /// Short form for a list row: "Credit price · 10¢ drop", "Cash price", "Payment type not set".
    var shortText: String {
        var parts = [payment.priceTitle]
        if let dropText { parts.append("\(dropText) drop") }
        return parts.joined(separator: " · ")
    }

    /// For VoiceOver: "Credit price. Notifies on a drop of 10¢ or more."
    var spokenText: String {
        var parts = [payment.priceTitle]
        if let dropText { parts.append("Notifies on a drop of \(dropText) or more") }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Words around the payment choice

nonisolated enum PriceAlertPaymentCopy {
    static let sectionTitle = "Price to watch"
    /// Always shown under the Cash / Credit choice: how the two are kept apart.
    static let helpText = "A Cash alert looks only at Cash prices and a Credit alert only at Credit prices. A price reported as the same for both counts for either."
    /// Under the choice while nothing is chosen. Guidance, not an error.
    static let chooseHint = "Choose Cash or Credit to continue."
    /// For an alert made before payment types existed.
    static let legacyAlertNotice = "This alert was set up before Cash and Credit prices were reported separately. Choose the price it should watch so it keeps up with new reports."
}

// MARK: - How often it can fire

/// A plain statement of the delivery limits, built from the alert's OWN preferences (the values the
/// client sent, or the ones the server holds for an alert made elsewhere) rather than from constants
/// repeated here — so the sentence cannot disagree with what the backend will do.
nonisolated enum PriceAlertDeliveryNote {
    /// Appended to every note: alerts follow community reports and are sent in batches, so they are not
    /// instant.
    static let timingSentence = "Alerts follow community reports, so they aren't instant."

    static func text(for kind: PriceAlertKind, preferences: PriceAlertPreferences) -> String {
        text(for: kind, payment: nil, preferences: preferences)
    }

    /// - Parameter payment: the price the alert watches, `nil` while none is chosen (the note then says
    ///   "the price" rather than naming one).
    static func text(for kind: PriceAlertKind, payment: PriceAlertPayment?, preferences: PriceAlertPreferences) -> String {
        let interval = durationText(minutes: preferences.cooldownMinutes)
        let price: String
        if let payment, payment.isSpecified {
            price = "\(payment.title) price"
        } else {
            price = "price"
        }
        switch kind {
        case .priceDrop:
            let drop = PriceAlertSensitivity.displayText(for: preferences.minimumChange)
            return "You'll be notified when the \(price) falls by \(drop) or more, at most once every \(interval) for this station. \(timingSentence)"
        case .atOrBelow:
            return "You'll be notified when the \(price) reaches your target, at most once every \(interval) for this station. \(timingSentence)"
        }
    }

    /// "hour", "6 hours", "day", "2 days", "90 minutes".
    static func durationText(minutes: Int) -> String {
        let total = max(minutes, 1)
        if total % 1440 == 0 {
            let days = total / 1440
            return days == 1 ? "day" : "\(days) days"
        }
        if total % 60 == 0 {
            let hours = total / 60
            return hours == 1 ? "hour" : "\(hours) hours"
        }
        return total == 1 ? "minute" : "\(total) minutes"
    }
}
