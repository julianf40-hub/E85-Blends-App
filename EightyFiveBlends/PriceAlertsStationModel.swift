//
//  PriceAlertsStationModel.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B). Everything the Price Alert sheet decides, with no view
//  in it: what to show, what a tap does, what is allowed while something else is happening.
//  Foundation + Observation only, over the `PriceAlertsServing` seam, so the whole state machine is
//  unit-tested against a fake that stops and fails on command.
//
//  THE SERVER'S ALERT IS THE ALERT. This model holds no copy of it. `existingListing` is read, every
//  time, from the service's list — the list the server last returned, refreshed after every change the
//  service makes. What this model owns is only the FORM (what the person is editing) and a few flags
//  about what is in flight. So there is no second alert model to fall out of step with the first.
//
//  PRO. The model never decides who is Pro: `phase` follows `service.entitlement`, the three-valued
//  answer from Phase 3A. `.unresolved` is its own phase ("checking") — never rendered as Free — and
//  the backend's own refusal of a save (`proRequiredByServer`) comes back as an ordinary, friendly
//  save failure.
//
//  PAYMENT TYPE (Phase 3C). Every alert watches Cash or Credit, and there is no default: `form.payment`
//  starts as nil for a new alert AND for an alert made before payment types existed, and Save stays off
//  until it is chosen. The model never fills it in, and it never sends one the person did not pick.
//
//  A LEGACY ALERT (Phase 3C.1). An alert the server holds with payment type `unknown` gets the "Choose Your Price
//  Type" prompt (`paymentChoicePrompt`). It is a pure function of the server's alert and the form: opening the sheet
//  writes nothing, the choice starts empty, the rule, drop size, target and cooldown the alert already has are carried
//  into the save unchanged, and the prompt goes away only when the server's own answer says the alert has a price type.
//  If the server answers a save with a DIFFERENT price type from the one chosen (a backend that does not know payment
//  types yet), the sheet says the choice was not saved instead of announcing an update that did not happen.
//
//  THINGS THAT CANNOT HAPPEN (each has a test)
//    - Two saves from one double tap: `isSaving` is set before the first suspension point, so the
//      second call finds it set and returns.
//    - A slow earlier load overwriting a newer save: `operationGeneration` moves on at every save and
//      turn-off, and a load only seeds the form if no change has started since it did and the person
//      has not edited the form. (The service additionally runs list-touching operations in request
//      order, so the list itself can never go backwards.)
//    - A failed save losing what was typed: the form is only re-seeded by a success.
//    - Turning an alert off unregistering the device: `disablePushDelivery` is not in the seam.
//    - Notification registration starting by itself: see PriceAlertsNotificationModel.
//

import Foundation
import Observation

@MainActor
@Observable
final class PriceAlertsStationModel {
    /// What the main area of the sheet shows.
    nonisolated enum Phase: Equatable {
        /// RevenueCat has not answered yet. Never shown as Free.
        case resolvingEntitlement
        /// RevenueCat answered: not Pro. The sheet shows the Pro card (and nothing is deleted).
        case proRequired
        case loading
        case loadFailed(PriceAlertsUserMessage)
        case ready
    }

    /// A sentence for VoiceOver (and a cue for a haptic) after something the person did finished.
    nonisolated struct Announcement: Equatable, Identifiable, Sendable {
        let id: Int
        let isError: Bool
        let text: String
    }

    // MARK: Copy

    static let turnOffTitle = "Turn Off Price Alert?"
    static let turnOffMessage = "You won't receive Price Alert notifications for this station unless you create a new alert."
    static let turnOffActionTitle = "Turn Off"

    // MARK: State

    let target: PriceAlertStationTarget
    /// The "Notifications" card's model.
    let notifications: PriceAlertsNotificationModel

    /// What the person is editing. Bound to the controls.
    var form: PriceAlertForm

    private(set) var isSaving = false
    private(set) var isTurningOff = false
    private(set) var isConfirmingTurnOff = false
    private(set) var announcement: Announcement?

    private let service: any PriceAlertsServing
    private var seededForm: PriceAlertForm
    private var isLoading = false
    private var hasAttemptedLoad = false
    private var hasLoadedBefore: Bool
    private var operationGeneration = 0
    private var announcementCount = 0
    private var saveFailure: PriceAlertsUserMessage?
    private var saveFailureForm: PriceAlertForm?
    private var turnOffFailure: PriceAlertsUserMessage?

    init(target: PriceAlertStationTarget, service: any PriceAlertsServing) {
        self.target = target
        self.service = service
        notifications = PriceAlertsNotificationModel(service: service)
        // Opened from the overview, the list is already here: show it at once rather than a spinner.
        hasLoadedBefore = service.listState == .loaded
        let existingAlert = service.alerts.first { $0.alert.stationID == target.communityStationID }?.alert
        let seed = PriceAlertForm(seededFrom: existingAlert)
        form = seed
        seededForm = seed
    }

    // MARK: Reading

    var entitlement: PriceAlertsEntitlement {
        service.entitlement
    }

    var phase: Phase {
        switch service.entitlement {
        case .unresolved:
            return .resolvingEntitlement
        case .inactive:
            return .proRequired
        case .active:
            if hasLoadedBefore { return .ready }
            if isLoading || hasAttemptedLoad == false { return .loading }
            switch service.listState {
            case .loaded: return .ready
            case .failed(let error): return .loadFailed(PriceAlertsUserMessage(error: error))
            case .idle, .loading: return .loading
            }
        }
    }

    /// The alert the server holds for this station, if any.
    var existingListing: PriceAlertListing? {
        service.alerts.first { $0.alert.stationID == target.communityStationID }
    }

    var hasExistingAlert: Bool {
        existingListing != nil
    }

    /// The server's alert in words, including one this UI cannot create (`any_change`) or read.
    var currentSummary: PriceAlertSummary? {
        existingListing.map { PriceAlertSummary(alert: $0.alert) }
    }

    /// The existing alert's rule, or `nil` if there is none or this build cannot read it.
    var existingRule: PriceAlertRule? {
        existingListing?.alert.rule
    }

    /// Which price the existing alert watches and how big a drop it waits for, in words. `nil` if none.
    var currentWatch: PriceAlertWatch? {
        existingListing.map { PriceAlertWatch(alert: $0.alert) }
    }

    var isBusy: Bool {
        isSaving || isTurningOff
    }

    var canSave: Bool {
        phase == .ready && isBusy == false && form.canSave(existing: existingListing?.alert)
    }

    /// Why Save is unavailable right now, or `nil` if it is (or the sheet is busy / not ready, where there
    /// is nothing to say). Used for the hint a screen reader speaks on a dimmed Save button.
    var saveBlocker: PriceAlertForm.SaveBlocker? {
        guard phase == .ready, isBusy == false else { return nil }
        return form.saveBlocker(existing: existingListing?.alert)
    }

    var saveButtonTitle: String {
        if isSaving { return "Saving…" }
        return hasExistingAlert ? "Update Alert" : "Create Alert"
    }

    /// Guidance under an empty At or Below field — not an error.
    var priceFieldHint: String? {
        guard form.showsPriceField, form.resolution == .needsPrice else { return nil }
        return PriceAlertPriceInput.emptyHint
    }

    /// Why a typed price is wrong, shown before anything is saved.
    var priceFieldMessage: String? {
        form.showsPriceField ? form.priceMessage : nil
    }

    /// Why Save is unavailable, in a sentence, for a screen reader: a dimmed button with no reason is a dead
    /// end. Empty when Save is available or the sheet is busy.
    var saveHint: String {
        if canSave || isBusy { return "" }
        switch saveBlocker {
        case .choosePayment?:
            return "Choose Cash or Credit first."
        case .needsPrice?:
            return "Enter a target price first."
        case .invalidPrice?:
            return priceFieldMessage ?? "Check the target price."
        case .needsChangeAmount?:
            return "Enter a custom drop size first."
        case .invalidChangeAmount?:
            return changeFieldMessage ?? "Check the custom drop size."
        case .noChanges?, nil:
            return "There are no changes to save."
        }
    }

    /// Guidance under the Cash / Credit choice while nothing is chosen — not an error. `nil` once chosen.
    var paymentHint: String? {
        form.payment == nil ? PriceAlertPaymentCopy.chooseHint : nil
    }

    /// The "Choose Your Price Type" prompt, for an alert the server holds with no payment type (one made before payment
    /// types existed). Driven entirely by the server's alert: it is there while the list says the payment type is not
    /// set, and gone as soon as a save makes the server say otherwise. `nil` for a new alert, for an alert that watches
    /// Cash or Credit, and whenever the sheet is not ready — a Free person sees the Pro card and an unresolved
    /// entitlement is "checking", never Free.
    var paymentChoicePrompt: PriceAlertPaymentChoicePrompt? {
        guard phase == .ready, let alert = existingListing?.alert else { return nil }
        return PriceAlertPaymentChoicePrompt.make(for: alert, form: form)
    }

    /// For an alert that watches Cash or Credit: said when the server knows no report of that kind for the station yet,
    /// so the next one sets the starting point of a Price Drop. `nil` otherwise — including when the backend does not
    /// send the comparable price at all (it then cannot say, and nothing is claimed).
    var noComparablePriceNote: String? {
        guard phase == .ready, let listing = existingListing,
              listing.alert.paymentType.isSpecified, listing.alert.rule == .priceDrop,
              listing.latestComparablePrice == nil
        else { return nil }
        return PriceAlertPaymentMigrationCopy.noPriceYet(for: listing.alert.paymentType)
    }

    /// Guidance under an empty Custom drop size — not an error.
    var changeFieldHint: String? {
        guard form.showsCustomChangeField, form.changeResolution == .needsAmount else { return nil }
        return PriceAlertMinimumChangeInput.emptyHint
    }

    /// Why a typed Custom drop size is wrong, shown before anything is saved.
    var changeFieldMessage: String? {
        form.changeMessage
    }

    /// How often the alert being configured can fire — from the choices on the form (the price it
    /// watches and, for Price Drop, the drop size) and the alert's own cooldown.
    var deliveryNote: String {
        var preferences = existingListing?.alert.preferences ?? .newAlertDefaults
        if form.showsSensitivity, let minimumChange = form.minimumChange {
            preferences.minimumChange = minimumChange
        }
        if let carried = form.carriedRule {
            return PriceAlertDeliveryNote.text(forCarried: carried, payment: form.payment, preferences: preferences)
        }
        return PriceAlertDeliveryNote.text(for: form.kind, payment: form.payment, preferences: preferences)
    }

    /// Whether the form still holds exactly what it was last seeded with (nothing edited since).
    var isFormPristine: Bool {
        form == seededForm
    }

    /// The outcome of the last successful save or turn-off, while it still describes what the sheet
    /// shows: once the person edits the form again, or something else is in progress, it goes away.
    var visibleSuccessNotice: String? {
        guard let announcement, announcement.isError == false, isFormPristine, isBusy == false else { return nil }
        return announcement.text
    }

    /// The last save's failure, while the form still holds what was sent. Editing makes it stale.
    var visibleSaveFailure: PriceAlertsUserMessage? {
        guard let saveFailure, saveFailureForm == form else { return nil }
        return saveFailure
    }

    var visibleTurnOffFailure: PriceAlertsUserMessage? {
        turnOffFailure
    }

    /// The list could not be refreshed, though an earlier one is showing. `nil` otherwise.
    var refreshWarning: PriceAlertsUserMessage? {
        guard phase == .ready, case .failed(let error) = service.listState else { return nil }
        return PriceAlertsUserMessage(error: error)
    }

    // MARK: Loading

    /// Reads the alerts from the server (not Pro-gated by the service, but only worth doing for a
    /// person who can use the result). Safe to call again — a call made while one runs does nothing.
    func load() async {
        guard service.entitlement == .active, isLoading == false else { return }
        isLoading = true
        hasAttemptedLoad = true
        let generation = operationGeneration
        await service.refreshAlerts()
        isLoading = false
        guard service.listState == .loaded else { return }
        hasLoadedBefore = true
        // A load that started before a save or turn-off began must not rewrite the form that change
        // just seeded; nor may it overwrite something the person has typed since.
        if generation == operationGeneration, form == seededForm {
            seedForm(from: existingListing?.alert)
        }
    }

    // MARK: Editing

    func select(_ kind: PriceAlertKind) {
        form.select(kind)
    }

    /// Picks the price this alert watches.
    func select(payment: PriceAlertPayment) {
        form.select(payment: payment)
    }

    /// Picks the drop size of a Price Drop alert.
    func select(sensitivity: PriceAlertSensitivity) {
        form.select(sensitivity: sensitivity)
    }

    // MARK: Saving

    /// Creates the alert, or — if the station already has one — updates it, sending its full state.
    /// Does nothing unless the form is complete, different from what the server holds, and nothing
    /// else is in progress.
    func save() async {
        guard phase == .ready, isBusy == false else { return }
        let existing = existingListing?.alert
        // Every save names the price it watches: a payment type nobody chose is never sent.
        guard let rule = form.rule,
              let payment = form.payment, payment.isSpecified,
              let preferences = form.preferences(existing: existing),
              form.isUnchanged(from: existing) == false
        else { return }

        isSaving = true
        saveFailure = nil
        saveFailureForm = nil
        turnOffFailure = nil
        operationGeneration += 1
        defer { isSaving = false }

        let sentForm = form
        do {
            let saved: PriceAlert
            if let existing {
                saved = try await service.updateAlert(existing, rule: rule, preferences: preferences, paymentType: payment)
            } else {
                saved = try await service.createAlert(
                    communityStationID: target.communityStationID,
                    rule: rule,
                    preferences: preferences,
                    paymentType: payment
                )
            }
            // The server must have applied the price type that was chosen. If it answers with another one (a backend that
            // does not know payment types yet ignores the field), nothing the person asked for happened: say so, keep
            // what they chose on screen, and do not announce an update.
            guard saved.paymentType == payment else {
                let message = PriceAlertsUserMessage.paymentChoiceNotSaved
                saveFailure = message
                saveFailureForm = sentForm
                announce("\(message.headline). \(message.body)", isError: true)
                return
            }
            // Seeded from the server's own answer to this save, not from the list: if the refresh the
            // service makes afterwards failed, the list can still be the old one, and reading it
            // would put the old alert back in the form.
            seedForm(from: saved)
            announce(existing == nil ? "Price Alert created." : "Price Alert updated.", isError: false)
        } catch {
            let message = PriceAlertsUserMessage(error: PriceAlertsServiceError.from(error))
            saveFailure = message
            saveFailureForm = sentForm
            announce("\(message.headline). \(message.body)", isError: true)
        }
    }

    // MARK: Turning off

    /// Asks for confirmation. Nothing is sent until `confirmTurnOff()`.
    func requestTurnOff() {
        guard phase == .ready, hasExistingAlert, isBusy == false else { return }
        turnOffFailure = nil
        isConfirmingTurnOff = true
    }

    func cancelTurnOff() {
        isConfirmingTurnOff = false
    }

    /// Deletes the alert on the server. The device's push registration is NOT touched: a person who
    /// turns one alert off keeps receiving the others.
    func confirmTurnOff() async {
        guard isConfirmingTurnOff, isBusy == false else { return }
        isConfirmingTurnOff = false
        isTurningOff = true
        turnOffFailure = nil
        operationGeneration += 1
        defer { isTurningOff = false }

        do {
            try await service.deleteAlert(communityStationID: target.communityStationID)
            seedForm(from: nil)
            announce("Price Alert turned off.", isError: false)
        } catch {
            let message = PriceAlertsUserMessage(error: PriceAlertsServiceError.from(error))
            turnOffFailure = message
            announce("\(message.headline). \(message.body)", isError: true)
        }
    }

    // MARK: Internals

    /// Re-seeds the form from the alert the server holds (`nil`: none, as after a turn-off).
    private func seedForm(from alert: PriceAlert?) {
        let seed = PriceAlertForm(seededFrom: alert)
        form = seed
        seededForm = seed
        saveFailure = nil
        saveFailureForm = nil
    }

    private func announce(_ text: String, isError: Bool) {
        announcementCount += 1
        announcement = Announcement(id: announcementCount, isError: isError, text: text)
    }
}
