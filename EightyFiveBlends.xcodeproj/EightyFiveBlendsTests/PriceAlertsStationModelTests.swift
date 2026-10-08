//
//  PriceAlertsStationModelTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B, extended in Phase 3C) — the state machine behind the Price Alert sheet
//  (PriceAlertsStationModel.swift): what it shows while loading, for Free / Pro / still-checking users
//  and for every kind of alert the server may hold; that saving cannot be doubled, never loses what
//  was typed when it fails, and is seeded from the server's own answer; that turning an alert off
//  asks first, deletes, and never touches the device's push registration. Phase 3C adds: every save
//  names the price it watches (Cash or Credit — never defaulted, never guessed for a legacy alert) and,
//  for Price Drop, how big a drop it waits for (new alerts 10¢, existing alerts keep what they hold).
//
//  Everything runs through the REAL PriceAlertsService over the Phase 3A fakes: the transport
//  simulates price-alerts-api as documented, so these tests read as behavior (a Pro-gated upsert, a
//  list that returns what was saved), and a held request makes ordering and double-taps deterministic.
//  No network, no Keychain, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private func amount(_ thousandths: Int) -> PriceAlertAmount {
    PriceAlertAmount(thousandths: thousandths)
}

private let stationOneID = PriceAlertsStack.stationID(1)

/// Replaces what the simulated server holds for a station with a row of the given mode — the way a
/// newer backend (or another platform) could leave one that this build must still display safely.
@MainActor
private func overwriteServerAlert(_ stack: PriceAlertsStack, mode: String, threshold: String? = nil) {
    let installationID = stack.transport.installations.keys.first!
    stack.transport.alerts[installationID, default: [:]][stationOneID.uuidString.lowercased()] =
        BackendFixtures.alertObject(stationID: stationOneID, mode: mode, threshold: threshold)
}

// MARK: - What the sheet shows

struct PriceAlertsStationModelPhaseTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))

    @Test("No alert yet: the sheet loads to an empty, ready form — and sends nothing, since this install has never used Price Alerts")
    func noAlert() async {
        let model = stack.stationModel()
        #expect(model.phase == .loading)

        await model.load()

        #expect(model.phase == .ready)
        #expect(model.hasExistingAlert == false)
        #expect(model.currentSummary == nil)
        #expect(model.form == PriceAlertForm())
        #expect(model.saveButtonTitle == "Create Alert")
        #expect(stack.transport.requests.isEmpty)
    }

    @Test("An existing Price Drop alert is loaded and shown, with the form on Price Drop")
    func existingPriceDrop() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        #expect(model.phase == .loading)

        await model.load()

        #expect(model.phase == .ready)
        #expect(model.currentSummary == .priceDrop)
        #expect(model.form == PriceAlertForm(kind: .priceDrop, priceText: "", payment: .cash, sensitivity: .fiveCents))
        #expect(model.saveButtonTitle == "Update Alert")
        #expect(model.canSave == false)
    }

    @Test("An existing At or Below alert is loaded with its exact threshold in the field")
    func existingAtOrBelow() async throws {
        let model = try await stack.relaunchedStationModel(existing: .atOrBelow(amount(3_499)))

        await model.load()

        #expect(model.currentSummary == .atOrBelow(amount(3_499)))
        #expect(model.currentSummary?.title == "At or below $3.499")
        #expect(model.form == PriceAlertForm(kind: .atOrBelow, priceText: "3.499", payment: .cash, sensitivity: .fiveCents))
        #expect(model.canSave == false)
    }

    @Test("A mode this build has never heard of displays as a custom alert, cannot crash, and can be replaced")
    func unknownFutureMode() async throws {
        _ = try await stack.service.createAlert(communityStationID: stationOneID, rule: .priceDrop)
        overwriteServerAlert(stack, mode: "percent_drop")
        let model = stack.stationModel(service: stack.relaunchedService())

        await model.load()

        #expect(model.phase == .ready)
        #expect(model.currentSummary == .unrecognized)
        #expect(model.currentSummary?.title == "Custom alert")
        #expect(model.existingRule == nil)
        // Nothing of the unreadable alert is guessed: its drop size is read (5¢), its payment type is not set.
        #expect(model.form == PriceAlertForm(sensitivity: .fiveCents))
        // Saving a chosen type replaces it — the one alert per station — once a price is chosen for it.
        #expect(model.canSave == false)
        model.select(payment: .cash)
        #expect(model.canSave)
        await model.save()
        #expect(model.currentSummary == .priceDrop)
        #expect(model.visibleSaveFailure == nil)
    }

    @Test("An Any Change alert made elsewhere is shown rather than hidden, and the form never offers it")
    func anyChangeMadeElsewhere() async throws {
        _ = try await stack.service.createAlert(communityStationID: stationOneID, rule: .priceDrop)
        overwriteServerAlert(stack, mode: "any_change")
        let model = stack.stationModel(service: stack.relaunchedService())

        await model.load()

        #expect(model.currentSummary == .anyChange)
        #expect(model.currentSummary?.title == "Any price change")
        // The form never OFFERS any_change, but it carries the alert's rule so nothing rewrites it unasked (Phase 3C.1).
        #expect(model.form == PriceAlertForm(sensitivity: .fiveCents, carriedRule: .anyChange))
        #expect(model.form.selectedKind == nil, "no kind card is shown as selected for a rule that has no card")
        #expect(PriceAlertKind.allCases.contains { $0.title.lowercased().contains("any") } == false)
    }

    @Test("While loading the sheet says so; once the alerts arrive it is ready")
    func loadingState() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "list_alerts" { await gate.parkFirstCaller() }
        }

        let load = Task { await model.load() }
        #expect(await gate.waitUntilParked())
        #expect(model.phase == .loading)
        #expect(model.canSave == false)

        gate.release()
        await load.value
        #expect(model.phase == .ready)
        #expect(model.currentSummary == .priceDrop)
    }

    @Test("A failed load is reported in plain words, offers a retry, and a retry shows the alerts")
    func loadFailure_thenRetry() async throws {
        let model = try await stack.relaunchedStationModel(existing: .atOrBelow(amount(3_250)))
        stack.transport.enqueue("list_alerts", .error(status: 503, code: "internal_error"))

        await model.load()

        #expect(model.phase == .loadFailed(.busy))
        #expect(model.canSave == false)
        assertSafeToShow(PriceAlertsUserMessage.busy.headline)

        await model.load()
        #expect(model.phase == .ready)
        #expect(model.form == PriceAlertForm(kind: .atOrBelow, priceText: "3.25", payment: .cash, sensitivity: .fiveCents))
    }

    @Test("An offline load says so")
    func offlineLoad() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        stack.transport.enqueue("list_alerts", .failure(URLError(.notConnectedToInternet)))

        await model.load()

        guard case .loadFailed(let message) = model.phase else {
            Issue.record("expected a load failure, got \(model.phase)")
            return
        }
        #expect(message.headline == "You're offline")
        #expect(message.isRetryable)
    }

    @Test("Calling load again while one is running does nothing extra")
    func loadIsCoalesced() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "list_alerts" { await gate.parkFirstCaller() }
        }
        let first = Task { await model.load() }
        #expect(await gate.waitUntilParked())

        await model.load()
        await model.load()
        #expect(stack.transport.count(of: "list_alerts") == 2)   // the setup's refresh after its save, and this one

        gate.release()
        await first.value
        #expect(stack.transport.count(of: "list_alerts") == 2)
    }
}

// MARK: - Pro

struct PriceAlertsStationModelProTests {
    @Test("A Pro user can configure alerts")
    func pro_canConfigure() async {
        let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)), entitlement: .active)
        let model = stack.stationModel()

        await model.load()

        #expect(model.entitlement == .active)
        #expect(model.phase == .ready)
        // A new alert can be saved once a price (Cash or Credit) is chosen — not before.
        #expect(model.canSave == false)
        model.select(payment: .cash)
        #expect(model.canSave)
    }

    @Test("A Free user gets the Pro phase: nothing is requested, and nothing can be saved or turned off")
    func free_routesToTheProGate() async {
        let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)), entitlement: .inactive)
        let model = stack.stationModel()

        await model.load()
        await model.save()
        model.requestTurnOff()
        await model.confirmTurnOff()

        #expect(model.phase == .proRequired)
        #expect(model.canSave == false)
        #expect(model.isConfirmingTurnOff == false)
        #expect(stack.totalSideEffects == 0)
        #expect(stack.credentials.loadCount == 0)
    }

    @Test("An UNRESOLVED entitlement is its own phase — never Free, never the Pro gate — and resolves into the sheet")
    func unresolved_isNotFree() async {
        let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)), entitlement: .unresolved)
        let model = stack.stationModel()

        #expect(model.phase == .resolvingEntitlement)
        #expect(model.phase != .proRequired)
        await model.load()
        await model.save()
        #expect(stack.totalSideEffects == 0)

        stack.entitlement.entitlement = .active
        #expect(model.phase == .loading)
        await model.load()
        #expect(model.phase == .ready)
    }

    @Test("A lapsed subscriber who still has an installation opens the Pro card without any request being made")
    func lapsed_doesNotLoad() async throws {
        let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
        _ = try await stack.service.createAlert(communityStationID: stationOneID, rule: .priceDrop)
        stack.entitlement.entitlement = .inactive
        let model = stack.stationModel(service: stack.relaunchedService())
        let sent = stack.transport.requests.count

        await model.load()

        #expect(model.phase == .proRequired)
        #expect(stack.transport.requests.count == sent)
        // Nothing was removed on the server because of the lapse.
        #expect(stack.transport.alerts.values.flatMap { $0.values }.count == 1)
    }

    @Test("Purchasing while the sheet is open turns the Pro card into the form")
    func purchase_whileOpen() async {
        let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)), entitlement: .inactive)
        let model = stack.stationModel()
        await model.load()
        #expect(model.phase == .proRequired)

        stack.entitlement.entitlement = .active
        #expect(model.phase == .loading)
        await model.load()

        #expect(model.phase == .ready)
        model.select(payment: .credit)
        #expect(model.canSave)
    }

    @Test("A Pro lapse changes what the sheet shows — and deletes, disables and unregisters nothing; renewal brings it all back")
    func lapse_preservesEverything() async throws {
        let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
        let model = try await stack.relaunchedStationModel(existing: .atOrBelow(amount(3_250)))
        await model.load()
        _ = await stack.service.enablePushDelivery()
        let sent = stack.transport.requests.count

        stack.entitlement.entitlement = .inactive

        #expect(model.phase == .proRequired)
        #expect(stack.transport.requests.count == sent)
        #expect(stack.transport.alerts.values.flatMap { $0.values }.count == 1)
        #expect(stack.transport.devices.filter(\.enabled).count == 1)
        #expect(stack.records.clearCount == 0)

        stack.entitlement.entitlement = .active
        #expect(model.phase == .ready)
        #expect(model.currentSummary == .atOrBelow(amount(3_250)))
    }
}

// MARK: - Saving

struct PriceAlertsStationModelSaveTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))

    @Test("Creating an At or Below alert sends exactly that rule, the chosen price type and the new-alert defaults, then shows it")
    func create_atOrBelow() async throws {
        let model = stack.stationModel()
        await model.load()
        model.select(.atOrBelow)
        model.form.priceText = "3.25"
        #expect(model.canSave == false, "no price type chosen yet")
        model.select(payment: .credit)
        #expect(model.canSave)

        await model.save()

        let request = try #require(stack.transport.lastRequest("set_alert"))
        #expect(request.json["station_id"] as? String == stationOneID.uuidString.lowercased())
        #expect(request.json["alert_mode"] as? String == "at_or_below")
        #expect(request.json["threshold_price"] as? Double == 3.25)
        #expect(request.json["payment_type"] as? String == "credit")
        #expect(request.json["minimum_change"] as? Double == 0.1)
        #expect(request.json["cooldown_minutes"] as? Int == 360)
        #expect(model.hasExistingAlert)
        #expect(model.currentSummary == .atOrBelow(amount(3_250)))
        #expect(model.currentWatch?.payment == .credit)
        #expect(model.form == PriceAlertForm(kind: .atOrBelow, priceText: "3.25", payment: .credit, sensitivity: .tenCents))
        #expect(model.isSaving == false)
        #expect(model.saveButtonTitle == "Update Alert")
        #expect(model.canSave == false)
        #expect(model.announcement?.isError == false)
        #expect(model.announcement?.text == "Price Alert created.")
    }

    @Test("Creating a Price Drop alert sends no threshold, the chosen price type and the recommended 10¢")
    func create_priceDrop() async throws {
        let model = stack.stationModel()
        await model.load()
        model.select(payment: .cash)

        await model.save()

        let request = try #require(stack.transport.lastRequest("set_alert"))
        #expect(request.json["alert_mode"] as? String == "price_drop")
        #expect(request.json["threshold_price"] as? Double == nil)
        #expect(request.json["payment_type"] as? String == "cash")
        #expect(request.json["minimum_change"] as? Double == 0.1)
        #expect(model.currentSummary == .priceDrop)
        #expect(model.currentWatch?.dropLine == "Notifies on a drop of 10¢ or more")
    }

    @Test("Changing the price an existing alert watches reaches the server — Cash to Credit, and a legacy alert to a chosen price")
    func changingThePaymentType_isSent() async throws {
        // Cash → Credit on an alert that already watches Cash.
        let model = try await stack.relaunchedStationModel(existing: .priceDrop, preferences: .newAlertDefaults, paymentType: .cash)
        await model.load()
        model.select(payment: .credit)
        #expect(model.canSave)

        await model.save()

        let request = try #require(stack.transport.lastRequest("set_alert"))
        #expect(request.json["payment_type"] as? String == "credit")
        #expect(model.currentWatch?.payment == .credit)
        #expect(model.form.payment == .credit)
        let stored = stack.transport.alerts.values.flatMap { $0.values }
        #expect(stored.count == 1)
        #expect(stored.first?["payment_type"] as? String == "credit", "the server now holds the new choice")

        // A legacy alert (made before payment types existed) is moved to a chosen price by the same path, and its
        // 5¢ drop size is carried, not reset.
        let legacyStack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
        let legacyModel = try await legacyStack.relaunchedStationModel(existing: .priceDrop, paymentType: nil)
        await legacyModel.load()
        #expect(legacyModel.currentWatch?.needsPaymentChoice == true)
        legacyModel.select(payment: .cash)
        await legacyModel.save()

        let legacyRequest = try #require(legacyStack.transport.lastRequest("set_alert"))
        #expect(legacyRequest.json["payment_type"] as? String == "cash")
        #expect(legacyRequest.json["minimum_change"] as? Double == 0.05)
        #expect(legacyModel.currentWatch?.payment == .cash)
        #expect(legacyModel.currentWatch?.needsPaymentChoice == false)
    }

    @Test("The sentence under the form follows what is chosen: the price type and the drop size, live")
    func deliveryNote_followsTheForm() async {
        let model = stack.stationModel()
        await model.load()
        #expect(model.deliveryNote.contains("the price falls by 10¢"), "a new alert starts at 10¢ with no price type named")

        model.select(payment: .credit)
        #expect(model.deliveryNote.contains("the Credit price falls by 10¢ or more"))

        model.select(sensitivity: .twentyCents)
        #expect(model.deliveryNote.contains("falls by 20¢ or more"))
        model.select(sensitivity: .fiveCents)
        #expect(model.deliveryNote.contains("falls by 5¢ or more"))

        model.select(sensitivity: .custom)
        model.form.customChangeText = "0.15"
        #expect(model.deliveryNote.contains("falls by 15¢ or more"))
        model.form.customChangeText = "banana"
        #expect(model.deliveryNote.contains("falls by"), "an invalid custom amount leaves the last valid wording, not a crash")

        model.select(.atOrBelow)
        model.select(payment: .cash)
        #expect(model.deliveryNote.contains("the Cash price reaches your target"))
        #expect(model.deliveryNote.contains("aren't instant"))
    }

    @Test("A legacy alert shows the Choose Your Price Type prompt — until the server says it has one; other alerts never do")
    func legacyPrompt_goesAwayOnceTheServerHasAPriceType() async throws {
        let legacyModel = try await stack.relaunchedStationModel(existing: .priceDrop, paymentType: nil)
        await legacyModel.load()
        #expect(legacyModel.paymentChoicePrompt?.title == "Choose Your Price Type")
        #expect(legacyModel.paymentHint == PriceAlertPaymentCopy.chooseHint)
        #expect(legacyModel.canSave == false)

        // Choosing on the form does not remove the prompt: only the SERVER's answer to a save does.
        legacyModel.select(payment: .credit)
        #expect(legacyModel.paymentChoicePrompt != nil)
        #expect(legacyModel.paymentHint == nil)
        #expect(legacyModel.canSave)
        await legacyModel.save()
        #expect(legacyModel.paymentChoicePrompt == nil)

        let typedStack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
        let typedModel = try await typedStack.relaunchedStationModel(existing: .priceDrop, paymentType: .cash)
        await typedModel.load()
        #expect(typedModel.paymentChoicePrompt == nil)
        #expect(typedModel.paymentHint == nil)

        let newModel = stack.stationModel(seed: 2)
        await newModel.load()
        #expect(newModel.paymentChoicePrompt == nil, "a brand-new alert is not a legacy one")
        #expect(newModel.paymentHint == PriceAlertPaymentCopy.chooseHint)
    }

    @Test("Without a chosen price type nothing is sent — Save does nothing, and no payment type is ever invented")
    func noPaymentChosen_sendsNothing() async {
        let model = stack.stationModel()
        await model.load()
        #expect(model.saveBlocker == .choosePayment)
        #expect(model.saveHint == "Choose Cash or Credit first.")
        #expect(model.paymentHint == PriceAlertPaymentCopy.chooseHint)

        await model.save()

        #expect(stack.transport.count(of: "set_alert") == 0)
        #expect(model.hasExistingAlert == false)
        #expect(model.announcement == nil)
    }

    @Test("Each drop size reaches the server exactly: 5¢, 10¢, 20¢, and a Custom amount to the thousandth")
    func dropSizes_reachTheServer() async throws {
        let cases: [(PriceAlertSensitivity, String, Double)] = [
            (.fiveCents, "", 0.05), (.tenCents, "", 0.1), (.twentyCents, "", 0.2), (.custom, "0.15", 0.15), (.custom, "0.075", 0.075), (.custom, "2", 2.0),
        ]
        for (index, (sensitivity, custom, expected)) in cases.enumerated() {
            let seed = UInt8(10 + index)
            let model = PriceAlertsStationModel(target: PriceAlertsStack.target(seed), service: stack.service)
            await model.load()
            model.select(payment: .credit)
            model.select(sensitivity: sensitivity)
            model.form.customChangeText = custom

            await model.save()

            let request = try #require(stack.transport.lastRequest("set_alert"))
            #expect(request.json["minimum_change"] as? Double == expected, "\(sensitivity) \(custom)")
        }
    }

    @Test("A Custom amount outside 0.01–2.00, or malformed, blocks Save and sends nothing")
    func customDropSize_invalid_isNotSent() async {
        let model = stack.stationModel()
        await model.load()
        model.select(payment: .cash)
        model.select(sensitivity: .custom)
        #expect(model.changeFieldHint == PriceAlertMinimumChangeInput.emptyHint)
        #expect(model.canSave == false)
        #expect(model.saveHint == "Enter a custom drop size first.")

        for text in ["0", "0.009", "2.001", "-1", "abc", "0.1234"] {
            model.form.customChangeText = text
            #expect(model.canSave == false, "\(text)")
            #expect(model.changeFieldMessage != nil, "\(text)")
            #expect(model.changeFieldHint == nil, "\(text)")
            await model.save()
        }
        #expect(stack.transport.requests.isEmpty)

        model.form.customChangeText = "0.01"
        #expect(model.canSave)
        #expect(model.changeFieldMessage == nil)
    }

    @Test("Updating sends the alert's FULL state: the preferences it already had are carried forward")
    func update_carriesPreferencesForward() async throws {
        let preferences = PriceAlertPreferences(minimumChange: amount(100), cooldownMinutes: 720)
        let model = try await stack.relaunchedStationModel(existing: .priceDrop, preferences: preferences)
        await model.load()
        model.select(.atOrBelow)
        model.form.priceText = "2.99"

        await model.save()

        let request = try #require(stack.transport.lastRequest("set_alert"))
        #expect(request.json["alert_mode"] as? String == "at_or_below")
        #expect(request.json["threshold_price"] as? Double == 2.99)
        #expect(request.json["minimum_change"] as? Double == 0.1)
        #expect(request.json["cooldown_minutes"] as? Int == 720)
        // The price type it already watched is carried forward, not reset.
        #expect(request.json["payment_type"] as? String == "cash")
        #expect(model.currentSummary == .atOrBelow(amount(2_990)))
        #expect(model.announcement?.text == "Price Alert updated.")
        // The sentence under the form reads the alert's own limits.
        #expect(model.deliveryNote.contains("once every 12 hours"))
    }

    @Test("Switching an At or Below alert to Price Drop keeps the typed price while switching, and sends none")
    func switchToPriceDrop() async throws {
        let model = try await stack.relaunchedStationModel(existing: .atOrBelow(amount(3_250)))
        await model.load()

        model.select(.priceDrop)
        #expect(model.form.priceText == "3.25")
        await model.save()

        let request = try #require(stack.transport.lastRequest("set_alert"))
        #expect(request.json["alert_mode"] as? String == "price_drop")
        #expect(request.json["threshold_price"] as? Double == nil)
        // The alert's own 5¢ and Cash price type are kept — switching kinds does not move it to 10¢.
        #expect(request.json["minimum_change"] as? Double == 0.05)
        #expect(request.json["payment_type"] as? String == "cash")
        #expect(model.currentSummary == .priceDrop)
        // Re-seeded from the server's alert, which has no price.
        #expect(model.form == PriceAlertForm(kind: .priceDrop, priceText: "", payment: .cash, sensitivity: .fiveCents))
    }

    @Test("A double tap cannot save twice")
    func duplicateSubmit_isPrevented() async {
        let model = stack.stationModel()
        await model.load()
        model.select(payment: .cash)
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "set_alert" { await gate.parkFirstCaller() }
        }

        let first = Task { await model.save() }
        #expect(await gate.waitUntilParked())
        #expect(model.isSaving)
        #expect(model.canSave == false)
        #expect(model.saveButtonTitle == "Saving…")

        await model.save()
        await model.save()
        #expect(stack.transport.count(of: "set_alert") == 1)

        gate.release()
        await first.value
        #expect(stack.transport.count(of: "set_alert") == 1)
        #expect(model.isSaving == false)
        #expect(model.hasExistingAlert)
    }

    @Test("An invalid price is explained before saving and nothing is sent; the typed text is never changed")
    func invalidPrice_isNotSent() async {
        let model = stack.stationModel()
        await model.load()
        model.select(.atOrBelow)
        model.select(payment: .cash)

        model.form.priceText = ""
        #expect(model.priceFieldHint == PriceAlertPriceInput.emptyHint)
        #expect(model.priceFieldMessage == nil)
        #expect(model.canSave == false)

        model.form.priceText = "3.2501"
        #expect(model.priceFieldHint == nil)
        #expect(model.priceFieldMessage == PriceAlertPriceInput.message(for: .tooManyDecimals))
        #expect(model.canSave == false)
        await model.save()

        #expect(stack.transport.requests.isEmpty)
        #expect(model.form.priceText == "3.2501")
        #expect(model.announcement == nil)
    }

    @Test("A failed save keeps everything that was typed, says why, and can be retried")
    func failedSave_preservesInput() async {
        let model = stack.stationModel()
        await model.load()
        model.select(.atOrBelow)
        model.form.priceText = "3.25"
        model.select(payment: .credit)
        model.select(sensitivity: .twentyCents)
        stack.transport.enqueue("set_alert", .error(status: 500, code: "internal_error"))

        await model.save()

        #expect(model.visibleSaveFailure == .busy)
        #expect(model.form == PriceAlertForm(kind: .atOrBelow, priceText: "3.25", payment: .credit, sensitivity: .twentyCents))
        #expect(model.isSaving == false)
        #expect(model.hasExistingAlert == false)
        #expect(model.announcement?.isError == true)
        #expect(model.canSave)

        // Editing makes the old failure stale; the same input brings it back; a retry succeeds.
        model.form.priceText = "3.24"
        #expect(model.visibleSaveFailure == nil)
        model.form.priceText = "3.25"
        #expect(model.visibleSaveFailure == .busy)

        await model.save()
        #expect(model.visibleSaveFailure == nil)
        #expect(model.currentSummary == .atOrBelow(amount(3_250)))
    }

    @Test("When the server does not see Pro, the failure is friendly, the form keeps its values, and the sheet stays usable")
    func serverRefusesPro() async throws {
        stack.transport.serverGrantsPro = false
        let model = stack.stationModel()
        await model.load()
        model.select(.atOrBelow)
        model.form.priceText = "3.25"
        model.select(payment: .cash)

        await model.save()

        let failure = try #require(model.visibleSaveFailure)
        #expect(failure.headline == "Couldn't confirm Pro yet")
        #expect(failure.isRetryable)
        assertSafeToShow(failure.headline)
        assertSafeToShow(failure.body)
        #expect(model.form == PriceAlertForm(kind: .atOrBelow, priceText: "3.25", payment: .cash))
        #expect(model.phase == .ready)
        // One refresh of the server's link and one retry, then the server's word is final.
        #expect(stack.transport.count(of: "set_alert") == 2)
    }

    @Test("A station the server does not know is reported as such")
    func stationNotFound() async throws {
        stack.transport.knownStationIDs = []
        let model = stack.stationModel()
        await model.load()
        model.select(payment: .cash)

        await model.save()

        #expect(try #require(model.visibleSaveFailure).headline == "Station not available")
    }

    @Test("An offline save says so and keeps the form")
    func offlineSave() async throws {
        let model = stack.stationModel()
        await model.load()
        model.select(.atOrBelow)
        model.form.priceText = "3.25"
        model.select(payment: .cash)
        stack.transport.enqueue("bootstrap", .failure(URLError(.notConnectedToInternet)))

        await model.save()

        #expect(try #require(model.visibleSaveFailure).headline == "You're offline")
        #expect(model.form.priceText == "3.25")
        #expect(model.isSaving == false)
    }

    @Test("A slow earlier load can never overwrite a newer save")
    func staleLoad_doesNotOverwriteNewerSave() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        await model.load()
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "list_alerts" { await gate.parkFirstCaller() }
        }
        let slowLoad = Task { await model.load() }
        #expect(await gate.waitUntilParked())

        model.select(.atOrBelow)
        model.form.priceText = "3.25"
        let save = Task { await model.save() }
        for _ in 0..<100 { await Task.yield() }
        // The save is queued behind the load: the server has not seen it yet.
        #expect(stack.transport.count(of: "set_alert") == 1)   // only the setup's own save

        gate.release()
        await slowLoad.value
        await save.value

        #expect(model.currentSummary == .atOrBelow(amount(3_250)))
        #expect(model.form == PriceAlertForm(kind: .atOrBelow, priceText: "3.25", payment: .cash, sensitivity: .fiveCents))
        #expect(model.phase == .ready)
    }

    @Test("A slow earlier load cannot put the old alert back in the form while a save is in flight — or after it fails")
    func staleLoad_doesNotClobberTheForm() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        await model.load()
        let listGate = AsyncGate()
        let saveGate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "list_alerts" { await listGate.parkFirstCaller() }
            if request.action == "set_alert" { await saveGate.parkFirstCaller() }
        }
        stack.transport.enqueue("set_alert", .error(status: 500, code: "internal_error"))
        let slowLoad = Task { await model.load() }
        #expect(await listGate.waitUntilParked())

        // The person edits and saves while that older load is still on its way.
        model.select(.atOrBelow)
        model.form.priceText = "3.25"
        let typed = model.form
        let save = Task { await model.save() }

        // The load finishes first (the save is queued behind it), then the save reaches the server.
        listGate.release()
        await slowLoad.value
        #expect(await saveGate.waitUntilParked())

        // The window that matters: the load has completed, the save is in flight. What was typed stays.
        #expect(model.isSaving)
        #expect(model.form == typed)

        saveGate.release()
        await save.value

        // The save failed. Still what was typed — never the old alert's values — and the failure is shown.
        #expect(model.form == typed)
        #expect(model.visibleSaveFailure == .busy)
        #expect(model.currentSummary == .priceDrop)
    }

    @Test("The form is seeded from the server's answer to the save — even if refreshing the list afterwards fails")
    func seededFromTheSaveResponse() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        await model.load()
        model.select(.atOrBelow)
        model.form.priceText = "3.25"
        // The save succeeds on the server; the list refresh that follows it fails, leaving the OLD
        // list in place.
        stack.transport.enqueue("list_alerts", .error(status: 503, code: "internal_error"))

        await model.save()

        #expect(model.form == PriceAlertForm(kind: .atOrBelow, priceText: "3.25", payment: .cash, sensitivity: .fiveCents))
        #expect(model.currentSummary == .priceDrop)               // honest: the list is stale…
        #expect(model.refreshWarning == .busy)                    // …and the sheet says so
        #expect(model.visibleSaveFailure == nil)

        await model.load()
        #expect(model.refreshWarning == nil)
        #expect(model.currentSummary == .atOrBelow(amount(3_250)))
    }

    @Test("Every announcement is new, and none says the alert is paused or shows anything technical")
    func announcements() async {
        let model = stack.stationModel()
        await model.load()
        model.select(payment: .cash)
        var seen: [Int] = []

        await model.save()
        seen.append(model.announcement!.id)
        assertSafeToShow(model.announcement!.text)

        model.select(.atOrBelow)
        model.form.priceText = "3.25"
        await model.save()
        seen.append(model.announcement!.id)
        assertSafeToShow(model.announcement!.text)

        model.requestTurnOff()
        await model.confirmTurnOff()
        seen.append(model.announcement!.id)
        assertSafeToShow(model.announcement!.text)

        #expect(seen == [1, 2, 3])
    }
}

// MARK: - Turning off

struct PriceAlertsStationModelTurnOffTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))

    @Test("The confirmation copy is the product's, and never says paused")
    func copy() {
        #expect(PriceAlertsStationModel.turnOffTitle == "Turn Off Price Alert?")
        #expect(PriceAlertsStationModel.turnOffMessage == "You won't receive Price Alert notifications for this station unless you create a new alert.")
        #expect(PriceAlertsStationModel.turnOffActionTitle == "Turn Off")
        for text in [PriceAlertsStationModel.turnOffTitle, PriceAlertsStationModel.turnOffMessage, PriceAlertsStationModel.turnOffActionTitle] {
            assertSafeToShow(text)
        }
    }

    @Test("Turning off asks first; nothing is sent until confirmed, then the server's alert is deleted")
    func confirmThenDelete() async throws {
        let model = try await stack.relaunchedStationModel(existing: .atOrBelow(amount(3_250)))
        await model.load()

        model.requestTurnOff()
        #expect(model.isConfirmingTurnOff)
        #expect(stack.transport.count(of: "delete_alert") == 0)

        model.cancelTurnOff()
        #expect(model.isConfirmingTurnOff == false)
        #expect(stack.transport.count(of: "delete_alert") == 0)
        #expect(model.hasExistingAlert)

        model.requestTurnOff()
        await model.confirmTurnOff()

        let request = try #require(stack.transport.lastRequest("delete_alert"))
        #expect(request.json["station_id"] as? String == stationOneID.uuidString.lowercased())
        #expect(model.isConfirmingTurnOff == false)
        #expect(model.isTurningOff == false)
        #expect(model.hasExistingAlert == false)
        #expect(model.currentSummary == nil)
        #expect(model.form == PriceAlertForm())
        #expect(model.saveButtonTitle == "Create Alert")
        #expect(model.announcement?.text == "Price Alert turned off.")
        #expect(model.announcement?.isError == false)
        #expect(stack.transport.alerts.values.flatMap { $0.values }.isEmpty)
    }

    @Test("Without an alert there is nothing to turn off")
    func noAlert_noConfirmation() async {
        let model = stack.stationModel()
        await model.load()

        model.requestTurnOff()

        #expect(model.isConfirmingTurnOff == false)
        await model.confirmTurnOff()
        #expect(stack.transport.count(of: "delete_alert") == 0)
    }

    @Test("A failed turn-off leaves the alert exactly as it was, and says why")
    func failure_preservesTheAlert() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        await model.load()
        stack.transport.enqueue("delete_alert", .error(status: 500, code: "internal_error"))

        model.requestTurnOff()
        await model.confirmTurnOff()

        #expect(model.visibleTurnOffFailure == .busy)
        #expect(model.hasExistingAlert)
        #expect(model.currentSummary == .priceDrop)
        #expect(model.isTurningOff == false)
        #expect(model.announcement?.isError == true)
        #expect(stack.transport.alerts.values.flatMap { $0.values }.count == 1)

        // Trying again works, and clears the failure.
        model.requestTurnOff()
        #expect(model.visibleTurnOffFailure == nil)
        await model.confirmTurnOff()
        #expect(model.hasExistingAlert == false)
    }

    @Test("Turning off an alert never unregisters the device: the other alerts keep arriving")
    func delete_doesNotUnregisterTheDevice() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        await model.load()
        _ = await stack.service.enablePushDelivery()
        let record = stack.records.record
        #expect(record != nil)

        model.requestTurnOff()
        await model.confirmTurnOff()

        #expect(model.hasExistingAlert == false)
        #expect(stack.transport.count(of: "unregister_device") == 0)
        #expect(stack.records.clearCount == 0)
        #expect(stack.records.record == record)
        #expect(stack.transport.devices.filter(\.enabled).count == 1)
    }

    @Test("A double tap on Turn Off deletes once")
    func duplicateConfirm_isPrevented() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        await model.load()
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "delete_alert" { await gate.parkFirstCaller() }
        }

        model.requestTurnOff()
        let first = Task { await model.confirmTurnOff() }
        #expect(await gate.waitUntilParked())
        #expect(model.isTurningOff)

        await model.confirmTurnOff()
        model.requestTurnOff()
        #expect(model.isConfirmingTurnOff == false)   // cannot ask again while one is in flight
        #expect(stack.transport.count(of: "delete_alert") == 1)

        gate.release()
        await first.value
        #expect(stack.transport.count(of: "delete_alert") == 1)
        #expect(model.hasExistingAlert == false)
    }

    @Test("Saving and turning off cannot overlap")
    func saveAndTurnOff_areExclusive() async throws {
        let model = try await stack.relaunchedStationModel(existing: .priceDrop)
        await model.load()
        model.select(.atOrBelow)
        model.form.priceText = "3.25"
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "set_alert" { await gate.parkFirstCaller() }
        }

        let save = Task { await model.save() }
        #expect(await gate.waitUntilParked())

        model.requestTurnOff()
        #expect(model.isConfirmingTurnOff == false)
        gate.release()
        await save.value
        #expect(stack.transport.count(of: "delete_alert") == 0)
    }
}
