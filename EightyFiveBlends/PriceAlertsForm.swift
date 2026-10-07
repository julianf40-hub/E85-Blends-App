//
//  PriceAlertsForm.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B). The state of the Price Alert form and the words that
//  describe an alert, with no view in sight. Pure Foundation.
//
//  WHAT THE MVP OFFERS. Two kinds of alert, and only two:
//    - Price Drop    — "Notify me when this station reports a lower E85 price."
//    - At or Below   — "Notify me when E85 reaches my target price." (needs a price)
//  The backend also has `any_change`; it is deliberately not offered (PriceAlertRule.isOfferedInMVP).
//  Price Drop has NO threshold and NO percentage on the backend, so the form has none for it.
//
//  THE FORM NEVER CARRIES A SECOND COPY OF THE SERVER'S ALERT. It holds what the person is editing;
//  the alert itself is whatever PriceAlertsService.alerts says (the server is authoritative). The form
//  is seeded from that, and re-seeded after a save or turn-off.
//
//  SWITCHING KINDS KEEPS THE TYPED PRICE. Choosing Price Drop and then At or Below again brings the
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

    var kind: PriceAlertKind
    var priceText: String

    init(kind: PriceAlertKind = .priceDrop, priceText: String = "") {
        self.kind = kind
        self.priceText = priceText
    }

    /// Seeds the form from the rule of the alert the server holds. A rule this build does not offer
    /// (`any_change`) or cannot read (`nil`: an unknown or malformed mode) starts the form at its
    /// default rather than pretending to edit it.
    init(seededFrom rule: PriceAlertRule?) {
        switch rule {
        case .priceDrop?:
            self.init(kind: .priceDrop, priceText: "")
        case .atOrBelow(let amount)?:
            self.init(kind: .atOrBelow, priceText: PriceAlertPriceInput.editableText(for: amount))
        case .anyChange?, nil:
            self.init()
        }
    }

    var showsPriceField: Bool {
        kind == .atOrBelow
    }

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

    /// Whether saving would change nothing: the form describes exactly the rule the server already
    /// holds. `false` whenever there is no alert, or its rule is one this build cannot read.
    func isUnchanged(from existingRule: PriceAlertRule?) -> Bool {
        guard let rule, let existingRule else { return false }
        return rule == existingRule
    }

    func canSave(existingRule: PriceAlertRule?) -> Bool {
        rule != nil && isUnchanged(from: existingRule) == false
    }

    /// Picks a kind. The typed price is kept — see this file's header.
    mutating func select(_ newKind: PriceAlertKind) {
        kind = newKind
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

// MARK: - How often it can fire

/// A plain statement of the delivery limits, built from the alert's OWN preferences (the values the
/// client sent, or the ones the server holds for an alert made elsewhere) rather than from constants
/// repeated here — so the sentence cannot disagree with what the backend will do.
nonisolated enum PriceAlertDeliveryNote {
    static func text(for kind: PriceAlertKind, preferences: PriceAlertPreferences) -> String {
        let interval = durationText(minutes: preferences.cooldownMinutes)
        switch kind {
        case .priceDrop:
            let drop = PriceAlertPriceInput.displayText(for: preferences.minimumChange)
            return "You'll be notified when the price falls by \(drop) or more, at most once every \(interval) for this station."
        case .atOrBelow:
            return "You'll be notified when the price reaches your target, at most once every \(interval) for this station."
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
