//
//  PriceAlertsPaymentMigration.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 (Phase 3C.1) — moving an alert that was made before Cash and Credit prices were reported separately
//  to one of them. Pure Foundation: the words, and the small value types the two Price Alert screens read.
//
//  THE SITUATION. Before 2.4.1 an alert had no payment type. The server keeps those alerts exactly as they were
//  (`payment_type = unknown`, nothing guessed, nothing rewritten) and keeps judging them on the reports that did not say
//  which price they were. As people report typed Cash and Credit prices, fewer and fewer unclassified reports arrive, so
//  such an alert would quietly stop hearing about its station. Nobody should find that out by silence. These types are
//  how the app tells them, and how it asks which price the alert should watch.
//
//  WHAT THIS DOES NOT DO
//    - It never picks Cash or Credit for anyone. The choice starts empty and Save stays off until it is made.
//    - It never writes anything by itself. Showing the prompt is a read of the list the server already returned; the
//      only write is the person's own Save, through the same PriceAlertsService.updateAlert as any other change.
//    - It owns no flag. Whether an alert needs a choice is `PriceAlertWatch.needsPaymentChoice`, computed from the
//      alert the server holds, so both screens agree and the prompt disappears the moment the server says the alert has
//      a payment type.
//    - It does not touch Pro. A Free person sees the Pro card, and an unresolved entitlement is "checking", not Free —
//      exactly as for every other Price Alert screen. Nothing is deleted when Pro lapses.
//
//  NO PROMISE OF AN ALERT. The words say when the alert will be able to compare prices, never that a notification is
//  coming: alerts follow community reports and are not instant.
//

import Foundation

// MARK: - Words

nonisolated enum PriceAlertPaymentMigrationCopy {
    /// The heading of the prompt, on both screens.
    static let title = "Choose Your Price Type"
    /// The explanation, on both screens.
    static let message = "Price reports now distinguish Cash and Credit prices. Choose which price you want to watch to keep your alerts up to date."

    /// The banner on a row of the Price Alerts list.
    static let rowTitle = "Payment type needed"
    static let rowMessage = "Choose Cash or Credit to continue watching this station's prices."
    static let editActionTitle = "Edit"
    static let editAccessibilityHint = "Opens this alert so you can choose Cash or Credit."

    /// Under the choice in the sheet, while nothing else about the alert has been touched.
    static let settingsStayTheSame = "Your alert type and settings stay the same."

    /// Under the alert types, for an alert whose type this screen has no card for (it notifies on any price change).
    static let carriedRuleNote = "This alert keeps its current type unless you choose one of these."

    /// Under the alert types, for an alert whose type this version of the app cannot show at all.
    static let unreadableRuleNote = "This alert's type can't be shown in this version of the app. Choose one of these to replace it."

    /// What a chosen price type means for a Price Drop's starting point, said before saving. It states how the
    /// comparison works and when it can begin; it does not say a notification will arrive.
    static func referenceNote(for payment: PriceAlertPayment) -> String {
        "Drops are measured from the latest \(payment.title) price reported for this station in the past week. If there isn't one, the next \(payment.title) price — or one reported as the same for both — sets the starting point."
    }

    /// What the alert's status says once it watches a price type and the server knows no report of that kind yet.
    static func noPriceYet(for payment: PriceAlertPayment) -> String {
        "No \(payment.title) price has been reported for this station yet. The next one — or one reported as the same for both — sets the starting point for price drops."
    }
}

// MARK: - The prompt in the sheet

/// What the Price Alert sheet shows above the form for an alert the server holds with no payment type.
nonisolated struct PriceAlertPaymentChoicePrompt: Equatable, Sendable {
    let title: String
    let message: String
    /// "Your alert type and settings stay the same." Present only while that is true of the form: the alert's rule can be
    /// read by this build and the form still holds exactly what the server holds, bar the price type.
    let settingsNote: String?
    /// How a Price Drop will be measured once the chosen price type is saved. `nil` until a price type is chosen, and
    /// for any alert that is not a Price Drop.
    let referenceNote: String?

    init(title: String = PriceAlertPaymentMigrationCopy.title,
         message: String = PriceAlertPaymentMigrationCopy.message,
         settingsNote: String?,
         referenceNote: String?) {
        self.title = title
        self.message = message
        self.settingsNote = settingsNote
        self.referenceNote = referenceNote
    }

    /// - Parameters:
    ///   - alert: the alert the server holds. The prompt exists only when it has no payment type.
    ///   - form: what the person has on screen right now.
    /// - Returns: `nil` for an alert that already watches Cash or Credit.
    static func make(for alert: PriceAlert, form: PriceAlertForm) -> PriceAlertPaymentChoicePrompt? {
        guard PriceAlertWatch(alert: alert).needsPaymentChoice else { return nil }
        let keepsSettings = form.matchesSettings(of: alert)
        var reference: String?
        if let payment = form.payment, payment.isSpecified, form.rule == .priceDrop {
            reference = PriceAlertPaymentMigrationCopy.referenceNote(for: payment)
        }
        return PriceAlertPaymentChoicePrompt(
            settingsNote: keepsSettings ? PriceAlertPaymentMigrationCopy.settingsStayTheSame : nil,
            referenceNote: reference
        )
    }
}

// MARK: - The banner on a row

/// The "Payment type needed" banner of one row of the Price Alerts list.
nonisolated struct PriceAlertPaymentChoiceBanner: Equatable, Sendable {
    let title: String
    let message: String
    let editTitle: String
    /// What VoiceOver says for the Edit action, naming the station.
    let editAccessibilityLabel: String
    let editAccessibilityHint: String

    init(stationName: String) {
        title = PriceAlertPaymentMigrationCopy.rowTitle
        message = PriceAlertPaymentMigrationCopy.rowMessage
        editTitle = PriceAlertPaymentMigrationCopy.editActionTitle
        editAccessibilityLabel = "Edit alert for \(stationName)"
        editAccessibilityHint = PriceAlertPaymentMigrationCopy.editAccessibilityHint
    }
}
