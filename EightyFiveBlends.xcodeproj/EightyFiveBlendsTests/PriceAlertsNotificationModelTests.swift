//
//  PriceAlertsNotificationModelTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B) — the "Notifications" card's model (PriceAlertsNotificationModel.swift):
//  what each outcome of turning notifications on looks like to a person, and — the property that
//  matters most — that NOTHING but a tap ever starts it. Opening a sheet, loading, saving an alert
//  and turning one off never prompt, never register and never talk to the OS about notifications.
//
//  Runs through the REAL PriceAlertsService over the Phase 3A fakes. No network, no Keychain, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private let tokenA = FakePushState.token(0xA1)
private let tokenB = FakePushState.token(0xB2)

struct PriceAlertsNotificationModelTests {
    private let stack = PriceAlertsStack(push: .notRequested)

    private func makeModel() -> PriceAlertsNotificationModel {
        PriceAlertsNotificationModel(service: stack.service)
    }

    /// The OS grants permission and delivers `token` when asked, as it does after a tap.
    private func osDelivers(_ token: PushDeviceToken) {
        let push = stack.push
        push.onOptIn = { push.pushState = .registered(token) }
    }

    // MARK: Starting point

    @Test("Before anything is asked, the card offers to turn notifications on — and nothing has happened")
    func startingPoint() {
        let model = makeModel()

        #expect(model.presentation.kind == .notEnabled)
        #expect(model.presentation.action == .turnOn)
        #expect(model.isEnabling == false)
        #expect(stack.totalSideEffects == 0)
        #expect(stack.service.hasRegisteredDevice == false)
    }

    // MARK: Outcomes

    @Test("Registered: notifications are on, the opt-in ran once, and the device was registered with the backend")
    func registered() async {
        osDelivers(tokenA)
        let model = makeModel()

        await model.turnOnNotifications()

        #expect(model.presentation.kind == .enabled)
        #expect(model.presentation.title == "Notifications are on")
        #expect(model.isEnabling == false)
        #expect(stack.push.optInCount == 1)
        #expect(stack.transport.actions == ["bootstrap", "register_device"])
        #expect(stack.service.hasRegisteredDevice)
    }

    @Test("Already registered: a second tap changes nothing on the server and still reads as on")
    func alreadyRegistered() async {
        osDelivers(tokenA)
        let model = makeModel()
        await model.turnOnNotifications()

        await model.turnOnNotifications()

        #expect(stack.service.lastDeviceRegistrationOutcome == .alreadyRegistered)
        #expect(model.presentation.kind == .enabled)
        #expect(stack.transport.count(of: "register_device") == 1)
    }

    @Test("A returning device shows notifications on straight away, without asking the system anything")
    func returningDevice() async {
        osDelivers(tokenA)
        await makeModel().turnOnNotifications()
        let relaunched = stack.relaunchedService()
        let sent = stack.transport.requests.count
        let refreshes = stack.push.refreshCount

        let model = PriceAlertsNotificationModel(service: relaunched)

        #expect(model.presentation.kind == .enabled)
        #expect(stack.transport.requests.count == sent)
        #expect(stack.push.refreshCount == refreshes)
    }

    @Test("Denied: the card says so and points to Settings; nothing is sent")
    func denied() async {
        let push = stack.push
        push.onOptIn = { push.pushState = .denied }
        let model = makeModel()

        await model.turnOnNotifications()

        #expect(model.presentation.kind == .denied)
        #expect(model.presentation.action == .openSettings)
        #expect(stack.transport.requests.isEmpty)
        #expect(stack.service.hasRegisteredDevice == false)
    }

    @Test("No device token — the OS could not register (no Push capability, a simulator) — is 'not ready', retryable, and sends nothing")
    func noDeviceToken_osFailure() async {
        let push = stack.push
        push.onOptIn = { push.pushState = .failed(.registrationFailed(domain: "NSCocoaErrorDomain", code: 3000)) }
        let model = makeModel()

        await model.turnOnNotifications()

        #expect(model.presentation.kind == .notReady)
        #expect(model.presentation.action == .tryAgain)
        assertSafeToShow(model.presentation.title)
        assertSafeToShow(model.presentation.detail)
        #expect(stack.transport.requests.isEmpty)
    }

    @Test("No device token because the OS never answered: the wait is bounded, then it is 'not ready'")
    func noDeviceToken_neverArrives() async {
        let push = stack.push
        push.onOptIn = { push.pushState = .authorizedAwaitingToken }
        let model = makeModel()

        await model.turnOnNotifications()

        #expect(model.presentation.kind == .notReady)
        #expect(stack.sleeper.count == PriceAlertsDeviceRegistrar.maximumTokenPolls)
        #expect(stack.transport.requests.isEmpty)
    }

    @Test("An unresolved push environment is reported as unavailable and nothing is registered")
    func pushEnvironmentUnresolved() async {
        osDelivers(tokenA)
        stack.metadata.metadata = nil
        let model = makeModel()

        await model.turnOnNotifications()

        #expect(model.presentation.kind == .unavailable)
        #expect(model.presentation.action == .none)
        #expect(stack.transport.count(of: "register_device") == 0)
    }

    @Test("A failed registration shows a friendly reason and offers a retry that works")
    func failure_thenRetry() async {
        osDelivers(tokenA)
        stack.transport.enqueue("register_device", .error(status: 500, code: "internal_error"))
        let model = makeModel()

        await model.turnOnNotifications()

        #expect(model.presentation.kind == .failed)
        #expect(model.presentation.title == PriceAlertsUserMessage.busy.headline)
        #expect(model.presentation.action == .tryAgain)
        assertSafeToShow(model.presentation.detail)

        await model.turnOnNotifications()
        #expect(model.presentation.kind == .enabled)
    }

    @Test("Offline says so")
    func offline() async {
        osDelivers(tokenA)
        stack.transport.enqueue("bootstrap", .failure(URLError(.notConnectedToInternet)))
        let model = makeModel()

        await model.turnOnNotifications()

        #expect(model.presentation.kind == .failed)
        #expect(model.presentation.title == "You're offline")
    }

    @Test("Backing off: after a failed automatic attempt the card says it will retry, and 'Try Again' goes straight through")
    func backingOff() async {
        osDelivers(tokenA)
        let model = makeModel()
        await model.turnOnNotifications()
        #expect(model.presentation.kind == .enabled)

        // The OS rotates the token; the app-level reconcile fails once, then waits.
        stack.push.pushState = .registered(tokenB)
        stack.transport.enqueue("register_device", .error(status: 500, code: "internal_error"))
        _ = await stack.service.reconcileDeviceRegistrationIfPreviouslyRegistered()
        #expect(model.presentation.kind == .failed)

        _ = await stack.service.reconcileDeviceRegistrationIfPreviouslyRegistered()
        #expect(model.presentation.kind == .retryScheduled)
        #expect(model.presentation.action == .tryAgain)

        // A tap bypasses the wait. (The OS now simply keeps answering with the rotated token.)
        stack.push.onOptIn = nil
        await model.turnOnNotifications()
        #expect(model.presentation.kind == .enabled)
        #expect(stack.transport.devices.filter(\.enabled).map(\.tokenHex) == [tokenB.hexString])
    }

    @Test("Coming back from Settings after revoking permission flips the card, with no help from the model")
    func revokedInSettings() async {
        osDelivers(tokenA)
        let model = makeModel()
        await model.turnOnNotifications()
        #expect(model.presentation.kind == .enabled)

        stack.push.pushState = .denied
        _ = await stack.service.reconcileDeviceRegistrationIfPreviouslyRegistered()

        #expect(model.presentation.kind == .denied)
        #expect(model.presentation.action == .openSettings)
    }

    @Test("A Free user who somehow taps is told Pro is needed — and nothing is created")
    func free_isToldProIsNeeded() async {
        let free = PriceAlertsStack(push: .notRequested, entitlement: .inactive)
        let model = PriceAlertsNotificationModel(service: free.service)

        await model.turnOnNotifications()

        #expect(model.presentation.kind == .needsPro)
        #expect(free.push.optInCount == 0)
        #expect(free.transport.requests.isEmpty)
        #expect(free.credentials.saveCount == 0)
    }

    @Test("While the subscription is unresolved the answer is 'checking', not 'Pro required'")
    func unresolved_isChecking() async {
        let unresolved = PriceAlertsStack(push: .notRequested, entitlement: .unresolved)
        let model = PriceAlertsNotificationModel(service: unresolved.service)

        await model.turnOnNotifications()

        #expect(model.presentation.kind == .checkingSubscription)
        #expect(model.presentation.kind != .needsPro)
        #expect(unresolved.push.optInCount == 0)
    }

    // MARK: Only a tap starts it

    @Test("Opening the sheet, loading, saving and turning an alert off never prompt or register; only a tap does")
    func optIn_isUserInitiatedOnly() async {
        // Notification permission is already granted — say, for pump arrival alerts — and a token is held.
        let granted = PriceAlertsStack(push: .registered(tokenA))
        let station = granted.stationModel()
        let overview = PriceAlertsOverviewModel(service: granted.service)

        await station.load()
        await overview.load()
        _ = station.notifications.presentation
        _ = overview.notifications.presentation
        await station.save()
        station.select(.atOrBelow)
        station.form.priceText = "3.25"
        await station.save()
        station.requestTurnOff()
        await station.confirmTurnOff()

        #expect(granted.push.optInCount == 0)
        #expect(granted.push.refreshCount == 0)
        #expect(granted.transport.count(of: "register_device") == 0)
        #expect(granted.records.saveCount == 0)
        #expect(granted.service.lastDeviceRegistrationOutcome == nil)
        #expect(station.notifications.presentation.kind == .notEnabled)

        await station.notifications.turnOnNotifications()

        #expect(granted.push.optInCount == 1)
        #expect(granted.transport.count(of: "register_device") == 1)
        #expect(station.notifications.presentation.kind == .enabled)
    }

    @Test("A double tap starts one opt-in")
    func doubleTap_startsOnce() async {
        osDelivers(tokenA)
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "register_device" { await gate.parkFirstCaller() }
        }
        let model = makeModel()

        let first = Task { await model.turnOnNotifications() }
        #expect(await gate.waitUntilParked())
        #expect(model.isEnabling)
        #expect(model.presentation.kind == .enabling)
        #expect(model.presentation.action == .none)

        await model.turnOnNotifications()
        gate.release()
        await first.value

        #expect(stack.push.optInCount == 1)
        #expect(stack.transport.count(of: "register_device") == 1)
        #expect(model.isEnabling == false)
    }
}
