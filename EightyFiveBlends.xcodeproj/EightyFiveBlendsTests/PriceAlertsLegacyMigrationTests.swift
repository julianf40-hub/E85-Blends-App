//
//  PriceAlertsLegacyMigrationTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts (Phase 3C.1) — moving an alert that was made before Cash and Credit prices were reported separately
//  (payment type `unknown`) to one of them. Two screens carry it: the Price Alert sheet (PriceAlertsStationModel) and the
//  central list (PriceAlertsOverviewModel); both read the SAME alert the server holds, through the REAL PriceAlertsService
//  over the Phase 3A fakes.
//
//  What these tests protect:
//    - the prompt appears for exactly the alerts the server says have no payment type, and goes away when the server's
//      answer to a save says otherwise (there is no local flag to disagree with it);
//    - nothing is chosen for the person and nothing is written by looking: the only write is their own Save;
//    - a save changes the price type and NOTHING else — the rule, target, drop size and cooldown the alert had are sent
//      back as they were, a rule the sheet has no card for (any change) is carried instead of being rewritten;
//    - Free, Pro and still-checking people keep the behavior they always had, and nothing is ever deleted;
//    - the words are the ones the product asked for, and promise no notification.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private func amount(_ thousandths: Int) -> PriceAlertAmount {
    PriceAlertAmount(thousandths: thousandths)
}

private func wire(_ seed: UInt8) -> String {
    PriceAlertsStack.stationID(seed).uuidString.lowercased()
}

/// What the simulated server holds for the station `seed`, if anything.
@MainActor
private func serverAlert(_ stack: PriceAlertsStack, station seed: UInt8) -> [String: Any]? {
    guard let installationID = stack.transport.installations.keys.first else { return nil }
    return stack.transport.alerts[installationID]?[wire(seed)]
}

/// Leaves the simulated server holding, for the station `seed`, a LEGACY alert (no payment type) in a mode this build has
/// never heard of - the way a newer backend could.
@MainActor
private func overwriteWithUnreadableLegacyAlert(_ stack: PriceAlertsStack, station seed: UInt8, mode: String = "percent_drop") {
    let installationID = stack.transport.installations.keys.first!
    stack.transport.alerts[installationID, default: [:]][wire(seed)] =
        BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(seed), mode: mode, paymentType: "unknown")
}

/// Words that would promise a notification now. None of the migration copy may contain one.
private let promisesOfImmediacy = ["immediately", "right away", "instantly", "as soon as", "guarantee", "within minutes", "at once"]

// MARK: - The sheet

struct PriceAlertsLegacyMigrationSheetTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))

    /// A model for a legacy alert (made without a payment type) that has loaded nothing yet.
    private func legacyModel(
        seed: UInt8 = 1,
        rule: PriceAlertRule = .priceDrop,
        preferences: PriceAlertPreferences = .defaults
    ) async throws -> PriceAlertsStationModel {
        try await stack.relaunchedStationModel(seed: seed, existing: rule, preferences: preferences, paymentType: nil)
    }

    // MARK: the prompt

    @Test("A legacy alert shows Choose Your Price Type, in the product's words, with its existing configuration displayed and nothing chosen")
    func prompt_isShown() async throws {
        let model = try await legacyModel(preferences: PriceAlertPreferences(minimumChange: amount(70), cooldownMinutes: 480))

        await model.load()

        let prompt = try #require(model.paymentChoicePrompt)
        #expect(prompt.title == "Choose Your Price Type")
        #expect(prompt.message == "Price reports now distinguish Cash and Credit prices. Choose which price you want to watch to keep your alerts up to date.")
        #expect(prompt.settingsNote == "Your alert type and settings stay the same.")
        #expect(prompt.referenceNote == nil, "nothing is said about a starting point until a price is chosen")
        // The existing configuration is displayed...
        #expect(model.currentSummary == .priceDrop)
        #expect(model.currentWatch?.paymentLine == "Payment type not set")
        #expect(model.currentWatch?.needsPaymentChoice == true)
        #expect(model.currentWatch?.dropLine == "Notifies on a drop of 7¢ or more")
        // ...and the form holds it too, with the price type not chosen.
        #expect(model.form.payment == nil)
        #expect(model.form.sensitivity == .custom)
        #expect(model.form.customChangeText == "0.07")
        #expect(model.phase == .ready)
    }

    @Test("The prompt is for alerts the server says have no payment type — never a Cash or Credit alert, never a brand-new one")
    func prompt_isOnlyForLegacyAlerts() async throws {
        for payment in [PriceAlertPayment.cash, .credit] {
            let typedStack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
            let typed = try await typedStack.relaunchedStationModel(existing: .priceDrop, paymentType: payment)
            await typed.load()
            #expect(typed.paymentChoicePrompt == nil, "\(payment)")
            #expect(typed.currentWatch?.needsPaymentChoice == false)
        }
        let brandNew = stack.stationModel(seed: 9)
        await brandNew.load()
        #expect(brandNew.paymentChoicePrompt == nil)
        #expect(brandNew.hasExistingAlert == false)
    }

    @Test("Only Cash and Credit can be chosen — Same for Both belongs to a report, and Unknown is never a choice")
    func onlyCashAndCredit() async throws {
        #expect(PriceAlertPayment.choices == [.cash, .credit])
        let model = try await legacyModel()
        await model.load()

        model.select(payment: .unknown)

        #expect(model.form.payment == nil, "selecting Unknown is ignored")
        #expect(model.canSave == false)
    }

    @Test("Nothing is preselected: Save is off, says why, and sends nothing until Cash or Credit is chosen")
    func noPreselection() async throws {
        let model = try await legacyModel()
        await model.load()
        let before = stack.transport.count(of: "set_alert")

        #expect(model.form.payment == nil)
        #expect(model.canSave == false)
        #expect(model.saveBlocker == .choosePayment)
        #expect(model.saveHint == "Choose Cash or Credit first.")
        #expect(model.paymentHint == PriceAlertPaymentCopy.chooseHint)
        await model.save()

        #expect(stack.transport.count(of: "set_alert") == before)
        #expect(model.announcement == nil)
        #expect(model.currentWatch?.needsPaymentChoice == true)
        #expect(serverAlert(stack, station: 1)?["payment_type"] as? String == "unknown", "the server still holds the legacy alert")
    }

    @Test("Opening the sheet writes nothing: the only request it makes is the read of the list")
    func openingWritesNothing() async throws {
        let model = try await legacyModel()
        let setUp = stack.transport.requests.count

        await model.load()
        // Looking at everything the view reads changes nothing either.
        _ = (model.paymentChoicePrompt, model.deliveryNote, model.currentWatch, model.noComparablePriceNote, model.saveHint)

        // Exactly the read of the list: no set_alert, delete_alert, bootstrap or device call.
        let added = stack.transport.requests.dropFirst(setUp).map(\.action)
        #expect(added == ["list_alerts"])
        #expect(serverAlert(stack, station: 1)?["payment_type"] as? String == "unknown")
    }

    // MARK: choosing

    @Test("Choosing Cash or Credit updates the intended alert only, through the existing service — the other station's legacy alert is untouched",
          arguments: [PriceAlertPayment.cash, PriceAlertPayment.credit])
    func choosing_updatesTheIntendedAlert(payment: PriceAlertPayment) async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(2), rule: .priceDrop, preferences: .defaults, paymentType: nil)
        let model = try await legacyModel(seed: 1)
        await model.load()
        let idBefore = model.existingListing?.alert.id

        model.select(payment: payment)
        #expect(model.canSave)
        await model.save()

        let request = try #require(stack.transport.lastRequest("set_alert"))
        #expect(request.json["station_id"] as? String == wire(1), "the alert being edited, not another")
        #expect(request.json["payment_type"] as? String == payment.wireValue)
        #expect(model.existingListing?.alert.id == idBefore, "the same alert: not deleted and recreated")
        #expect(model.currentWatch?.payment == payment)
        #expect(model.paymentChoicePrompt == nil, "the prompt goes once the server says the alert has a price type")
        #expect(model.announcement == PriceAlertsStationModel.Announcement(id: 1, isError: false, text: "Price Alert updated."))
        #expect(stack.transport.count(of: "delete_alert") == 0, "no delete-and-recreate")
        // The other station's alert is still a legacy one.
        #expect(serverAlert(stack, station: 2)?["payment_type"] as? String == "unknown")
        #expect(serverAlert(stack, station: 1)?["payment_type"] as? String == payment.wireValue)
    }

    @Test("Choosing a price type sends the alert's own rule, target, drop size and cooldown back unchanged — for every kind of legacy alert")
    func choosing_preservesEverythingElse() async throws {
        struct Case {
            let name: String
            let rule: PriceAlertRule
            let drop: Int
            let cooldown: Int
        }
        let cases = [
            Case(name: "price drop, the legacy 5¢", rule: .priceDrop, drop: 50, cooldown: 360),
            Case(name: "price drop, 10¢ and a 12 hour cooldown", rule: .priceDrop, drop: 100, cooldown: 720),
            Case(name: "price drop, 20¢", rule: .priceDrop, drop: 200, cooldown: 360),
            Case(name: "price drop, an odd 7¢", rule: .priceDrop, drop: 70, cooldown: 480),
            Case(name: "price drop, 1.5¢ (sub-cent)", rule: .priceDrop, drop: 15, cooldown: 360),
            Case(name: "price drop, the 2.00 maximum", rule: .priceDrop, drop: 2_000, cooldown: 10_080),
            Case(name: "at or below $3.499", rule: .atOrBelow(amount(3_499)), drop: 70, cooldown: 1_440),
            Case(name: "at or below $1.000, the minimum target", rule: .atOrBelow(amount(1_000)), drop: 10, cooldown: 60),
            Case(name: "at or below $8.000, the maximum target", rule: .atOrBelow(amount(8_000)), drop: 50, cooldown: 360),
        ]
        for (index, entry) in cases.enumerated() {
            let seed = UInt8(20 + index)
            let preferences = PriceAlertPreferences(minimumChange: amount(entry.drop), cooldownMinutes: entry.cooldown)
            let model = try await legacyModel(seed: seed, rule: entry.rule, preferences: preferences)
            await model.load()
            #expect(model.paymentChoicePrompt != nil, "\(entry.name)")
            let payment: PriceAlertPayment = index.isMultiple(of: 2) ? .cash : .credit

            model.select(payment: payment)
            await model.save()

            let request = try #require(stack.transport.lastRequest("set_alert"), "\(entry.name)")
            #expect(request.json["station_id"] as? String == wire(seed), "\(entry.name)")
            #expect(request.json["alert_mode"] as? String == entry.rule.mode.wireValue, "\(entry.name): the mode is the alert's own")
            #expect(request.json["threshold_price"] as? Double == entry.rule.thresholdPrice?.dollars, "\(entry.name): the target is exact")
            #expect(request.json["minimum_change"] as? Double == amount(entry.drop).dollars, "\(entry.name): the drop size is exact")
            #expect(request.json["cooldown_minutes"] as? Int == entry.cooldown, "\(entry.name): the cooldown is the alert's own")
            #expect(request.json["payment_type"] as? String == payment.wireValue, "\(entry.name)")
            #expect(request.json["alert_contract_version"] as? Int == 2, "\(entry.name): the drop size is declared as chosen")
            let stored = try #require(serverAlert(stack, station: seed), "\(entry.name)")
            #expect(stored["alert_mode"] as? String == entry.rule.mode.wireValue)
            #expect(model.existingListing?.alert.preferences == preferences, "\(entry.name): nothing about the alert's limits moved")
            #expect(model.existingListing?.alert.rule == entry.rule, "\(entry.name)")
        }
    }

    @Test("A legacy alert of a type the sheet has no card for (any change) keeps that type when a price type is chosen")
    func anyChange_isCarried() async throws {
        let model = try await legacyModel(rule: .anyChange, preferences: PriceAlertPreferences(minimumChange: amount(200), cooldownMinutes: 720))
        await model.load()

        // No card is shown as selected, no drop size or target is offered, and the reassurance is true.
        #expect(model.form.selectedKind == nil)
        #expect(model.form.showsSensitivity == false)
        #expect(model.form.showsPriceField == false)
        #expect(model.paymentChoicePrompt?.settingsNote == "Your alert type and settings stay the same.")
        model.select(payment: .cash)
        #expect(model.canSave)
        #expect(model.deliveryNote.contains("the Cash price changes by 20¢ or more"))

        await model.save()

        let request = try #require(stack.transport.lastRequest("set_alert"))
        #expect(request.json["alert_mode"] as? String == "any_change", "it was not turned into a Price Drop")
        #expect(request.json["threshold_price"] == nil)
        #expect(request.json["minimum_change"] as? Double == 0.2)
        #expect(request.json["cooldown_minutes"] as? Int == 720)
        #expect(request.json["payment_type"] as? String == "cash")
        #expect(model.currentSummary == .anyChange)
        #expect(model.paymentChoicePrompt == nil)
    }

    @Test("Picking an alert type on purpose replaces a carried rule — and then the reassurance is no longer made")
    func anyChange_chosenKindReplacesIt() async throws {
        let model = try await legacyModel(rule: .anyChange, preferences: PriceAlertPreferences(minimumChange: amount(200), cooldownMinutes: 720))
        await model.load()

        model.select(.priceDrop)
        model.select(payment: .credit)

        #expect(model.form.selectedKind == .priceDrop)
        #expect(model.form.carriedRule == nil)
        let changedPrompt = try #require(model.paymentChoicePrompt, "the prompt is still there")
        #expect(changedPrompt.settingsNote == nil, "the form no longer matches the alert")
        await model.save()
        let request = try #require(stack.transport.lastRequest("set_alert"))
        #expect(request.json["alert_mode"] as? String == "price_drop")
        #expect(request.json["minimum_change"] as? Double == 0.2, "the alert's own drop size is still the starting choice")
        #expect(model.currentSummary == .priceDrop)
    }

    @Test("A legacy alert in a mode this build cannot read is never rewritten by the price type alone: Save waits for an alert type")
    func unreadableRule_isNotConvertedByChoosingAPriceType() async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop, paymentType: nil)
        overwriteWithUnreadableLegacyAlert(stack, station: 1)
        let model = stack.stationModel(service: stack.relaunchedService())
        await model.load()

        // The prompt is there, but the reassurance is NOT: nothing about this alert can be kept as it was.
        let prompt = try #require(model.paymentChoicePrompt)
        #expect(prompt.settingsNote == nil)
        #expect(model.form.selectedKind == nil, "no alert type looks selected")
        #expect(model.currentSummary == .unrecognized)

        model.select(payment: .credit)
        #expect(model.canSave == false)
        #expect(model.saveBlocker == .chooseKind)
        #expect(model.saveHint == "Choose an alert type first.")
        let before = stack.transport.count(of: "set_alert")
        await model.save()
        #expect(stack.transport.count(of: "set_alert") == before, "nothing is sent")
        #expect(serverAlert(stack, station: 1)?["alert_mode"] as? String == "percent_drop", "the alert is as it was")
        #expect(serverAlert(stack, station: 1)?["payment_type"] as? String == "unknown")

        // Picking a type is the person's decision to replace it.
        model.select(.priceDrop)
        #expect(model.canSave)
        await model.save()
        #expect(serverAlert(stack, station: 1)?["alert_mode"] as? String == "price_drop")
        #expect(serverAlert(stack, station: 1)?["payment_type"] as? String == "credit")
        #expect(model.paymentChoicePrompt == nil)
    }

    @Test("The reassurance is made only while it is true: change the alert type or the drop size and it goes")
    func settingsNote_followsTheForm() async throws {
        let model = try await legacyModel(rule: .atOrBelow(amount(3_250)), preferences: PriceAlertPreferences(minimumChange: amount(100), cooldownMinutes: 360))
        await model.load()
        #expect(model.paymentChoicePrompt?.settingsNote == "Your alert type and settings stay the same.")

        model.select(payment: .cash)
        #expect(try #require(model.paymentChoicePrompt).settingsNote != nil, "choosing a price type alone leaves the rest as it was")

        model.form.priceText = "3.20"
        #expect(try #require(model.paymentChoicePrompt).settingsNote == nil)
        model.form.priceText = "3.25"
        #expect(try #require(model.paymentChoicePrompt).settingsNote != nil)

        model.select(.priceDrop)
        #expect(try #require(model.paymentChoicePrompt).settingsNote == nil)
    }

    // MARK: no comparable price

    @Test("When the station has no price of the chosen kind yet, the sheet says the next report sets the starting point — and promises nothing")
    func noComparablePrice_isExplained() async throws {
        stack.transport.comparablePricesAvailable = false
        let model = try await legacyModel()
        await model.load()
        #expect(model.noComparablePriceNote == nil, "a legacy alert has no price type to be missing a price for")

        // Before saving: how the comparison will work for the price type being chosen.
        model.select(payment: .cash)
        let prompt = try #require(model.paymentChoicePrompt)
        #expect(prompt.referenceNote == PriceAlertPaymentMigrationCopy.referenceNote(for: .cash))
        model.select(payment: .credit)
        #expect(try #require(model.paymentChoicePrompt).referenceNote == PriceAlertPaymentMigrationCopy.referenceNote(for: .credit))

        // After saving: the server's own list says no Credit price is known.
        await model.save()
        #expect(model.paymentChoicePrompt == nil)
        let note = try #require(model.noComparablePriceNote)
        #expect(note == "No Credit price has been reported for this station yet. The next one — or one reported as the same for both — sets the starting point for price drops.")

        let words = [note, prompt.referenceNote ?? "", PriceAlertPaymentMigrationCopy.message, model.deliveryNote].joined(separator: " ").lowercased()
        for promise in promisesOfImmediacy {
            #expect(words.contains(promise) == false, "must not promise “\(promise)”")
        }
        #expect(model.deliveryNote.contains("aren't instant"), "the sentence under Save says alerts follow community reports")
    }

    @Test("When the station does have a price of that kind, the sheet claims nothing about a missing one")
    func comparablePrice_present_noNote() async throws {
        stack.transport.comparablePricesAvailable = true
        let model = try await legacyModel()
        await model.load()
        model.select(payment: .cash)
        await model.save()

        #expect(model.currentWatch?.payment == .cash)
        #expect(model.noComparablePriceNote == nil)
    }

    @Test("The starting-point note is for Price Drop alerts only: At or Below has none")
    func noComparablePrice_notForAtOrBelow() async throws {
        stack.transport.comparablePricesAvailable = false
        let model = try await legacyModel(rule: .atOrBelow(amount(3_100)))
        await model.load()
        model.select(payment: .cash)
        #expect(try #require(model.paymentChoicePrompt).referenceNote == nil)

        await model.save()

        #expect(model.currentSummary == .atOrBelow(amount(3_100)))
        #expect(model.noComparablePriceNote == nil)
    }

    // MARK: entitlement

    @Test("When Pro lapses or is being re-checked while the alert is on screen, the prompt goes and nothing is sent or deleted; when Pro answers, it returns")
    func entitlements_gateThePrompt() async throws {
        let model = try await legacyModel()          // made while Pro
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.paymentChoicePrompt != nil)
        let setUp = stack.transport.requests.count

        // The subscription lapses with the alert list ALREADY loaded: the sheet shows the Pro card, not the prompt.
        stack.entitlement.entitlement = .inactive
        #expect(model.existingListing != nil, "the alert is still in the list the screen holds")
        #expect(model.phase == .proRequired)
        #expect(model.paymentChoicePrompt == nil)
        #expect(model.canSave == false)
        model.select(payment: .cash)
        await model.save()
        await model.load()

        // RevenueCat has not answered (again): that is "checking", never Free, and still no prompt.
        stack.entitlement.entitlement = .unresolved
        #expect(model.phase == .resolvingEntitlement, "unresolved is not Free")
        #expect(model.paymentChoicePrompt == nil)
        await model.save()

        #expect(stack.transport.requests.count == setUp, "neither Free nor checking made a single request")

        // Pro answers: the same alert, still there, asks again — and what the person had picked is still on screen.
        stack.entitlement.entitlement = .active
        #expect(model.phase == .ready)
        #expect(model.paymentChoicePrompt != nil)
        #expect(model.form.payment == .cash, "what the person had picked is still on screen")
        #expect(stack.transport.count(of: "delete_alert") == 0, "nothing was deleted while the person was not Pro")
        #expect(serverAlert(stack, station: 1)?["payment_type"] as? String == "unknown", "the legacy alert was preserved as it was")

        // A fresh sheet for a Free person (nothing loaded for them) shows the Pro card and sends nothing either.
        stack.entitlement.entitlement = .inactive
        let free = stack.stationModel(service: stack.relaunchedService())
        await free.load()
        #expect(free.phase == .proRequired)
        #expect(free.paymentChoicePrompt == nil)
        #expect(stack.transport.requests.count == setUp)
    }

    @Test("The server's Pro gate still applies: a save refused with pro_required leaves the alert as it was and is explained in plain words")
    func serverProGate_stillApplies() async throws {
        let model = try await legacyModel()
        await model.load()
        model.select(payment: .cash)
        stack.transport.enqueue("set_alert", .error(status: 403, code: "pro_required"), .error(status: 403, code: "pro_required"))

        await model.save()

        #expect(model.visibleSaveFailure != nil)
        #expect(model.announcement?.isError == true)
        #expect(model.paymentChoicePrompt != nil, "still a legacy alert")
        #expect(model.form.payment == .cash, "the choice stays on screen for another try")
        #expect(serverAlert(stack, station: 1)?["payment_type"] as? String == "unknown")
    }

    // MARK: honesty about the result

    @Test("If the server does not apply the chosen price type, the sheet says so and keeps the choice; it does not announce an update")
    func notApplied_isReported() async throws {
        stack.transport.backendPredatesPaymentTypes = true
        let model = try await legacyModel()
        await model.load()
        model.select(payment: .cash)

        await model.save()

        #expect(model.visibleSaveFailure == PriceAlertsUserMessage.paymentChoiceNotSaved)
        #expect(model.announcement?.isError == true)
        #expect(model.announcement?.text != "Price Alert updated.")
        #expect(model.visibleSuccessNotice == nil)
        #expect(model.form.payment == .cash, "what the person chose stays on screen")
        #expect(model.paymentChoicePrompt != nil, "the server still holds an alert with no price type")
        assertSafeToShow(PriceAlertsUserMessage.paymentChoiceNotSaved.headline)
        assertSafeToShow(PriceAlertsUserMessage.paymentChoiceNotSaved.body)

        // The backend catches up: the same tap now works.
        stack.transport.backendPredatesPaymentTypes = false
        #expect(model.canSave)
        await model.save()
        #expect(model.paymentChoicePrompt == nil)
        #expect(model.currentWatch?.payment == .cash)
        #expect(model.announcement?.text == "Price Alert updated.")
        #expect(model.visibleSaveFailure == nil)
    }

    @Test("A NEW alert saved against a backend that ignores the price type is reported as created without one - not as 'unchanged'")
    func notApplied_onCreate_isReportedAsCreatedWithoutAPriceType() async throws {
        stack.transport.backendPredatesPaymentTypes = true
        let model = stack.stationModel()
        await model.load()
        #expect(model.hasExistingAlert == false)
        model.select(payment: .credit)

        await model.save()

        #expect(model.visibleSaveFailure == PriceAlertsUserMessage.paymentChoiceNotSavedOnCreate)
        #expect(model.visibleSaveFailure?.body.contains("unchanged") == false, "the alert WAS created, so 'unchanged' would be untrue")
        #expect(model.announcement?.isError == true)
        #expect(model.announcement?.text != "Price Alert created.")
        #expect(model.hasExistingAlert, "the alert exists on the server, without a price type")
        #expect(serverAlert(stack, station: 1) != nil)
        #expect(serverAlert(stack, station: 1)?["payment_type"] == nil, "that backend stored no price type at all")
        #expect(model.form.payment == .credit, "the choice stays on screen")
        assertSafeToShow(PriceAlertsUserMessage.paymentChoiceNotSavedOnCreate.headline)
        assertSafeToShow(PriceAlertsUserMessage.paymentChoiceNotSavedOnCreate.body)
        // The prompt now offers the same choice for the alert that was created.
        #expect(model.paymentChoicePrompt != nil)

        // The backend catches up: the same choice now saves, as an UPDATE of the alert that was created.
        stack.transport.backendPredatesPaymentTypes = false
        #expect(model.canSave)
        await model.save()
        #expect(model.currentWatch?.payment == .credit)
        #expect(model.paymentChoicePrompt == nil)
        #expect(model.announcement?.text == "Price Alert updated.")
    }

    @Test("A double tap on Save sends one request")
    func doubleTap_isOneRequest() async throws {
        let model = try await legacyModel()
        await model.load()
        model.select(payment: .credit)
        let before = stack.transport.count(of: "set_alert")
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "set_alert" { await gate.parkFirstCaller() }
        }

        let first = Task { await model.save() }
        #expect(await gate.waitUntilParked())
        await model.save()
        gate.release()
        await first.value

        #expect(stack.transport.count(of: "set_alert") == before + 1)
        #expect(model.currentWatch?.payment == .credit)
    }

    // MARK: words

    @Test("Every word of the migration is plain, free of technical detail, and promises no notification")
    func copy_isSafeAndPromisesNothing() {
        let pieces = [
            PriceAlertPaymentMigrationCopy.title,
            PriceAlertPaymentMigrationCopy.message,
            PriceAlertPaymentMigrationCopy.rowTitle,
            PriceAlertPaymentMigrationCopy.rowMessage,
            PriceAlertPaymentMigrationCopy.editActionTitle,
            PriceAlertPaymentMigrationCopy.editAccessibilityHint,
            PriceAlertPaymentMigrationCopy.settingsStayTheSame,
            PriceAlertPaymentMigrationCopy.carriedRuleNote,
            PriceAlertPaymentMigrationCopy.unreadableRuleNote,
            PriceAlertPaymentMigrationCopy.referenceNote(for: .cash),
            PriceAlertPaymentMigrationCopy.referenceNote(for: .credit),
            PriceAlertPaymentMigrationCopy.noPriceYet(for: .cash),
            PriceAlertPaymentMigrationCopy.noPriceYet(for: .credit),
            PriceAlertPaymentChoiceBanner(stationName: "Corner Pump").editAccessibilityLabel,
        ]
        for text in pieces {
            assertSafeToShow(text)
            let lowered = text.lowercased()
            for promise in promisesOfImmediacy {
                #expect(lowered.contains(promise) == false, "“\(text)” must not promise “\(promise)”")
            }
        }
        // The starting point is only taken from a price reported in the past week (the server's reference horizon).
        #expect(PriceAlertPaymentMigrationCopy.referenceNote(for: .cash).contains("in the past week"))
        #expect(PriceAlertPaymentMigrationCopy.rowTitle == "Payment type needed")
        #expect(PriceAlertPaymentMigrationCopy.rowMessage == "Choose Cash or Credit to continue watching this station's prices.")
        #expect(PriceAlertPaymentMigrationCopy.editActionTitle == "Edit")
    }
}

// MARK: - The central list

struct PriceAlertsLegacyMigrationOverviewTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))

    private func makeAlerts() async throws {
        // 1: legacy Price Drop, 2: legacy At or Below, 3: Cash, 4: Credit
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop, preferences: .defaults, paymentType: nil)
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(2), rule: .atOrBelow(amount(3_100)), preferences: .defaults, paymentType: nil)
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(3), rule: .priceDrop, preferences: .newAlertDefaults, paymentType: .cash)
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(4), rule: .priceDrop, preferences: .newAlertDefaults, paymentType: .credit)
    }

    @Test("Each legacy alert gets the Payment type needed banner with an Edit action; the others get none")
    func banners_forLegacyAlertsOnly() async throws {
        try await makeAlerts()
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())

        await model.load()

        #expect(model.phase == .list)
        let byStation = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        for seed in [UInt8(1), 2] {
            let row = try #require(byStation[PriceAlertsStack.stationID(seed)])
            #expect(row.needsPaymentChoice)
            let banner = try #require(row.paymentChoiceBanner)
            #expect(banner.title == "Payment type needed")
            #expect(banner.message == "Choose Cash or Credit to continue watching this station's prices.")
            #expect(banner.editTitle == "Edit")
            #expect(banner.editAccessibilityLabel == "Edit alert for Corner Pump")
            #expect(banner.editAccessibilityHint == "Opens this alert so you can choose Cash or Credit.")
            // The banner is its own VoiceOver element (with the Edit button): its sentence is not repeated in the row's label.
            #expect(row.accessibilityLabel.contains("Payment type not set"))
            #expect(row.accessibilityLabel.contains("Payment type needed") == false)
            #expect(row.accessibilityHint == "Opens this alert so you can choose Cash or Credit.")
            #expect(row.watchText.contains("Payment type not set"))
        }
        for seed in [UInt8(3), 4] {
            let row = try #require(byStation[PriceAlertsStack.stationID(seed)])
            #expect(row.needsPaymentChoice == false)
            #expect(row.paymentChoiceBanner == nil, "an alert that already watches Cash or Credit has no banner")
            #expect(row.accessibilityLabel.contains("Payment type needed") == false)
            #expect(row.accessibilityHint == "Opens this alert so you can change it or turn it off.")
        }
        #expect(model.alertsNeedingPaymentChoice == 2)
    }

    @Test("One explanation heads the list while any alert needs a price type — and is gone when none does")
    func explainer_isOnceAndConditional() async throws {
        try await makeAlerts()
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())
        #expect(model.paymentChoicePrompt == nil, "nothing is shown before the server has been asked")
        await model.load()

        let prompt = try #require(model.paymentChoicePrompt)
        #expect(prompt.title == "Choose Your Price Type")
        #expect(prompt.message == "Price reports now distinguish Cash and Credit prices. Choose which price you want to watch to keep your alerts up to date.")

        // Only typed alerts: no explanation.
        let typedStack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
        _ = try await typedStack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop, paymentType: .cash)
        let typed = PriceAlertsOverviewModel(service: typedStack.relaunchedService())
        await typed.load()
        #expect(typed.phase == .list)
        #expect(typed.paymentChoicePrompt == nil)
        #expect(typed.alertsNeedingPaymentChoice == 0)
    }

    @Test("Opening the list writes nothing: the only request is the read")
    func openingTheList_writesNothing() async throws {
        try await makeAlerts()
        let setUp = stack.transport.requests.count
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())

        await model.load()
        _ = (model.rows, model.paymentChoicePrompt, model.alertsNeedingPaymentChoice)

        let added = stack.transport.requests.dropFirst(setUp).map(\.action)
        #expect(added == ["list_alerts"], "exactly the read of the list: nothing is written by looking")
        #expect(model.rows.filter(\.needsPaymentChoice).count == 2)
    }

    @Test("The list and the sheet agree, alert by alert, about which alerts need a price type — before and after one is chosen")
    func listAndSheet_agree() async throws {
        try await makeAlerts()
        let service = stack.relaunchedService()
        let overview = PriceAlertsOverviewModel(service: service)
        await overview.load()

        for row in overview.rows {
            let sheet = PriceAlertsStationModel(target: row.target, service: service)
            await sheet.load()
            #expect(row.needsPaymentChoice == (sheet.paymentChoicePrompt != nil), "station \(row.id)")
            #expect((row.paymentChoiceBanner != nil) == (sheet.paymentChoicePrompt != nil), "station \(row.id)")
            #expect(sheet.currentWatch?.needsPaymentChoice == row.needsPaymentChoice)
        }
        #expect(overview.alertsNeedingPaymentChoice == 2)

        // Edit opens the same sheet for the same alert; choosing there changes the list with no signalling.
        let editedRow = try #require(overview.rows.first { $0.id == PriceAlertsStack.stationID(1) })
        let sheet = PriceAlertsStationModel(target: editedRow.target, service: service)
        #expect(sheet.phase == .ready, "opened from the list, the alert is shown at once")
        #expect(sheet.paymentChoicePrompt != nil)
        sheet.select(payment: .credit)
        await sheet.save()
        #expect(overview.alertsNeedingPaymentChoice == 1)
        #expect(overview.rows.first { $0.id == PriceAlertsStack.stationID(1) }?.paymentChoiceBanner == nil)
        #expect(overview.rows.first { $0.id == PriceAlertsStack.stationID(2) }?.paymentChoiceBanner != nil)
        #expect(overview.paymentChoicePrompt != nil, "one alert still needs a choice")

        // The last one.
        let second = PriceAlertsStationModel(target: PriceAlertsStack.target(2), service: service)
        await second.load()
        second.select(payment: .cash)
        await second.save()
        #expect(overview.alertsNeedingPaymentChoice == 0)
        #expect(overview.paymentChoicePrompt == nil)
    }

    @Test("There is no local flag: a new model over the same server sees the same banners, and a failed refresh keeps what the server last said")
    func bannersAreTheServers() async throws {
        try await makeAlerts()
        let first = PriceAlertsOverviewModel(service: stack.relaunchedService())
        await first.load()
        let second = PriceAlertsOverviewModel(service: stack.relaunchedService())
        await second.load()
        #expect(first.rows.map(\.needsPaymentChoice) == second.rows.map(\.needsPaymentChoice))

        stack.transport.enqueue("list_alerts", .error(status: 503, code: "internal_error"))
        await second.load()
        #expect(second.phase == .list)
        #expect(second.refreshWarning == .busy)
        #expect(second.alertsNeedingPaymentChoice == 2, "the last good list is what is shown")
    }

    @Test("When Pro lapses or is being re-checked with the list on screen, the banners and the explanation go with it — and nothing is deleted")
    func entitlements_gateTheList() async throws {
        try await makeAlerts()
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())
        await model.load()
        #expect(model.phase == .list)
        #expect(model.alertsNeedingPaymentChoice == 2)
        #expect(model.paymentChoicePrompt != nil)
        let setUp = stack.transport.requests.count

        // The list the model holds still has the legacy alerts in it; the screen must show the Pro card instead.
        stack.entitlement.entitlement = .inactive
        #expect(model.rows.count == 4, "the alerts are all still known")
        #expect(model.phase == .proRequired)
        #expect(model.paymentChoicePrompt == nil, "no explanation above a list that is not shown")
        await model.load()

        stack.entitlement.entitlement = .unresolved
        #expect(model.phase == .resolvingEntitlement, "unresolved is not Free")
        #expect(model.paymentChoicePrompt == nil)
        await model.load()
        #expect(stack.transport.requests.count == setUp, "no request was made while the person was not Pro")

        stack.entitlement.entitlement = .active
        #expect(model.phase == .list)
        #expect(model.alertsNeedingPaymentChoice == 2, "the alerts were all still there")
        #expect(model.paymentChoicePrompt != nil)
        #expect(stack.transport.count(of: "delete_alert") == 0)

        // A fresh screen for a Free person (nothing loaded) shows the lock and sends nothing.
        stack.entitlement.entitlement = .inactive
        let fresh = PriceAlertsOverviewModel(service: stack.relaunchedService())
        await fresh.load()
        #expect(fresh.phase == .proRequired)
        #expect(fresh.paymentChoicePrompt == nil)
        #expect(stack.transport.requests.count == setUp)
    }
}
