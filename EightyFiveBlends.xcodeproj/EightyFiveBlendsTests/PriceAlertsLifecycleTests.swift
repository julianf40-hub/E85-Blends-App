//
//  PriceAlertsLifecycleTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B) — the two app-level hooks and the registrar behavior they rely on:
//    - app became active  -> PriceAlertsService.reconcileDeviceRegistrationIfPreviouslyRegistered()
//    - APNs token arrived -> PriceAlertsService.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered(),
//                            gated by PushTokenChange.isNewToken(previous:current:)
//  What must hold: for an install that never opted in, both are complete no-ops (no prompt, no OS
//  call, no network, no installation, nothing recorded); for one that did, they keep the backend's
//  token current — idempotently, with bounded backoff, without ever looping, and without missing a
//  token the OS rotated while a registration was in flight.
//
//  Runs over the Phase 3A fakes (and, for the loop check, the real PushRegistrationService). No
//  network, no Keychain, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private let tokenA = FakePushState.token(0xA1)
private let tokenB = FakePushState.token(0xB2)
private let tokenC = FakePushState.token(0xC3)

private func registeredDeviceTokens(_ transport: FakePriceAlertsTransport) -> [String] {
    transport.requests
        .filter { $0.action == "register_device" }
        .compactMap { $0.json["device_token"] as? String }
}

// MARK: - App became active

struct PriceAlertsAppActiveTests {
    private let stack = PriceAlertsStack(push: .registered(tokenA))
    private var service: PriceAlertsService { stack.service }

    @Test("An install that never opted in: every foreground is a complete no-op — nothing asked, sent, stored or recorded")
    func neverOptedIn_isInert() async {
        for _ in 0..<5 {
            #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .skipped(.notOptedIn))
        }

        #expect(stack.totalSideEffects == 0)
        #expect(stack.credentials.loadCount == 0)
        #expect(stack.push.optInCount == 0)
        #expect(stack.push.refreshCount == 0)
        #expect(service.lastDeviceRegistrationOutcome == nil)
        #expect(service.hasRegisteredDevice == false)
    }

    @Test("Using Price Alerts without opting in to notifications leaves the foreground hook inert")
    func usingAlerts_doesNotMakeTheHookActive() async throws {
        _ = try await service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop)
        let sent = stack.transport.requests.count

        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .skipped(.notOptedIn))

        #expect(stack.transport.requests.count == sent)
        #expect(stack.push.refreshCount == 0)
        #expect(stack.push.optInCount == 0)
    }

    @Test("After opting in, a foreground with the same token asks the OS (never prompting) and sends nothing")
    func optedIn_sameToken_sendsNothing() async {
        #expect(await service.enablePushDelivery() == .registered)
        let sent = stack.transport.requests.count

        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .alreadyRegistered)

        #expect(stack.transport.requests.count == sent)
        #expect(stack.push.refreshCount == 1)
        #expect(stack.push.optInCount == 1)   // the opt-in itself; the foreground never prompts
    }

    @Test("After opting in, a foreground that finds a rotated token registers it, and the old one is retired")
    func optedIn_rotatedToken_registers() async {
        _ = await service.enablePushDelivery()
        stack.push.pushState = .registered(tokenB)

        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .registered)

        #expect(registeredDeviceTokens(stack.transport) == [tokenA.hexString, tokenB.hexString])
        #expect(stack.transport.devices.filter(\.enabled).map(\.tokenHex) == [tokenB.hexString])
        #expect(stack.push.optInCount == 1)
    }

    @Test("Repeated foregrounds are idempotent: one bootstrap, one registration, however often the app comes back")
    func repeatedForegrounds_areIdempotent() async {
        _ = await service.enablePushDelivery()

        for _ in 0..<8 {
            #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .alreadyRegistered)
        }

        #expect(stack.transport.count(of: "bootstrap") == 1)
        #expect(stack.transport.count(of: "register_device") == 1)
        #expect(stack.records.saveCount == 1)
        #expect(stack.push.optInCount == 1)
    }

    @Test("Foregrounds that overlap share one attempt")
    func overlappingForegrounds_shareOneAttempt() async {
        _ = await service.enablePushDelivery()
        stack.push.pushState = .registered(tokenB)
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "register_device" { await gate.parkFirstCaller() }
        }

        let first = Task { await service.reconcileDeviceRegistrationIfPreviouslyRegistered() }
        #expect(await gate.waitUntilParked())
        let second = Task { await service.reconcileDeviceRegistrationIfPreviouslyRegistered() }
        let third = Task { await service.reconcileDeviceRegistrationIfPreviouslyRegistered() }
        for _ in 0..<100 { await Task.yield() }
        #expect(stack.transport.count(of: "register_device") == 2)   // the opt-in's, and the one in flight

        gate.release()
        _ = await first.value
        _ = await second.value
        _ = await third.value

        #expect(registeredDeviceTokens(stack.transport) == [tokenA.hexString, tokenB.hexString])
    }

    @Test("Failures back off: a failed foreground does not hammer the server, and a later one retries when the wait is over")
    func failure_backsOffAndRetries() async {
        _ = await service.enablePushDelivery()
        stack.push.pushState = .registered(tokenB)
        stack.transport.enqueue("register_device", .error(status: 503, code: "internal_error"))

        guard case .failed = await service.reconcileDeviceRegistrationIfPreviouslyRegistered() else {
            Issue.record("expected the first attempt to fail")
            return
        }
        // Within the wait: no network at all.
        for _ in 0..<5 {
            guard case .skipped(.backingOff) = await service.reconcileDeviceRegistrationIfPreviouslyRegistered() else {
                Issue.record("expected the attempt to be skipped while backing off")
                return
            }
        }
        #expect(stack.transport.count(of: "register_device") == 2)   // the opt-in's, and the one that failed

        stack.clock.advance(by: 31)
        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .registered)
        #expect(stack.transport.count(of: "register_device") == 3)
        #expect(stack.transport.devices.filter(\.enabled).map(\.tokenHex) == [tokenB.hexString])
    }

    @Test("A previously registered device whose Pro lapsed and whose credential is gone creates no installation")
    func lapsedWithoutCredential_createsNothing() async {
        let lapsed = PriceAlertsStack(push: .registered(tokenA), entitlement: .inactive)
        lapsed.records.record = PriceAlertsDeviceRegistrationRecord(fingerprint: "stale", registeredAt: lapsed.clock.now)

        let outcome = await lapsed.service.reconcileDeviceRegistrationIfPreviouslyRegistered()

        // Nothing to maintain: an automatic trigger never creates an installation (see PriceAlertsAutomaticTriggerTests).
        #expect(outcome == .skipped(.notOptedIn))
        #expect(lapsed.transport.requests.isEmpty)
        #expect(lapsed.credentials.saveCount == 0)
        #expect(lapsed.push.optInCount == 0)
    }

    @Test("A lapsed subscriber who still has an installation keeps their device registration current")
    func lapsedWithCredential_staysRegistered() async {
        _ = await service.enablePushDelivery()
        stack.entitlement.entitlement = .inactive
        stack.push.pushState = .registered(tokenB)

        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .registered)

        #expect(stack.transport.devices.filter(\.enabled).map(\.tokenHex) == [tokenB.hexString])
    }

    @Test("A user who revoked permission is not registered, not prompted, and the foreground says so")
    func revokedPermission() async {
        _ = await service.enablePushDelivery()
        stack.push.pushState = .denied
        let sent = stack.transport.requests.count

        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .skipped(.notificationsDenied))

        #expect(stack.transport.requests.count == sent)
        #expect(stack.push.optInCount == 1)
        #expect(service.lastDeviceRegistrationOutcome == .skipped(.notificationsDenied))
    }
}

// MARK: - APNs token arrived

struct PriceAlertsTokenChangeTests {
    private let stack = PriceAlertsStack(push: .registered(tokenA))
    private var service: PriceAlertsService { stack.service }

    @Test("An install that never opted in: a token callback does nothing at all")
    func neverOptedIn_isInert() async {
        #expect(await service.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered() == .skipped(.notOptedIn))

        #expect(stack.totalSideEffects == 0)
        #expect(stack.credentials.loadCount == 0)
        #expect(service.lastDeviceRegistrationOutcome == nil)
    }

    @Test("A rotated token is registered — WITHOUT asking the OS again, so the callback cannot start a loop")
    func rotatedToken_registersWithoutAskingTheOS() async {
        _ = await service.enablePushDelivery()
        stack.push.pushState = .registered(tokenB)

        #expect(await service.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered() == .registered)

        #expect(registeredDeviceTokens(stack.transport) == [tokenA.hexString, tokenB.hexString])
        #expect(stack.push.refreshCount == 0)
        #expect(stack.push.optInCount == 1)
    }

    @Test("A token the backend already has causes no network call")
    func sameToken_isANoOp() async {
        _ = await service.enablePushDelivery()
        let sent = stack.transport.requests.count

        #expect(await service.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered() == .alreadyRegistered)

        #expect(stack.transport.requests.count == sent)
        #expect(stack.push.refreshCount == 0)
    }

    @Test("Without a credential and without Pro, a token callback creates no installation")
    func lapsedWithoutCredential_createsNothing() async {
        let lapsed = PriceAlertsStack(push: .registered(tokenA), entitlement: .inactive)
        lapsed.records.record = PriceAlertsDeviceRegistrationRecord(fingerprint: "stale", registeredAt: lapsed.clock.now)

        #expect(await lapsed.service.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered() == .skipped(.notOptedIn))

        #expect(lapsed.transport.requests.isEmpty)
        #expect(lapsed.credentials.saveCount == 0)
    }

    @Test("A denied user is not registered by a token callback")
    func denied() async {
        _ = await service.enablePushDelivery()
        stack.push.pushState = .denied
        let sent = stack.transport.requests.count

        #expect(await service.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered() == .skipped(.notificationsDenied))
        #expect(stack.transport.requests.count == sent)
    }

    @Test("Only a token that differs from the one held counts as news")
    func isNewToken() {
        #expect(PushTokenChange.isNewToken(previous: nil, current: tokenA))
        #expect(PushTokenChange.isNewToken(previous: tokenA, current: tokenB))
        #expect(PushTokenChange.isNewToken(previous: tokenA, current: tokenA) == false)
        #expect(PushTokenChange.isNewToken(previous: nil, current: nil) == false)
        // A callback that left no token (an invalid payload, a denial) is never news.
        #expect(PushTokenChange.isNewToken(previous: tokenA, current: nil) == false)
    }
}

// MARK: - A token that rotates mid-registration

struct PriceAlertsConvergenceTests {
    private let stack = PriceAlertsStack(push: .registered(tokenA))
    private var service: PriceAlertsService { stack.service }

    @Test("A token that arrives while the first registration is in flight is registered right after it")
    func rotationDuringFirstRegistration() async throws {
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "register_device" { await gate.parkFirstCaller() }
        }
        let first = Task { await service.reconcileDeviceRegistration() }
        #expect(await gate.waitUntilParked())

        stack.push.pushState = .registered(tokenB)
        gate.release()
        let outcome = await first.value

        #expect(outcome == .registered)
        #expect(registeredDeviceTokens(stack.transport) == [tokenA.hexString, tokenB.hexString])
        #expect(stack.transport.devices.filter(\.enabled).map(\.tokenHex) == [tokenB.hexString])
        let installationID = try #require(stack.credentials.stored).installationID
        let expected = PriceAlertsDeviceFingerprint.make(
            installationID: installationID, token: tokenB, metadata: try #require(stack.metadata.metadata)
        )
        #expect(stack.records.record?.fingerprint == expected)
    }

    @Test("A token callback that joins an attempt in flight is not lost: the newest token ends up registered")
    func callbackJoiningAnAttemptInFlight() async {
        _ = await service.enablePushDelivery()
        stack.push.pushState = .registered(tokenB)
        let gate = AsyncGate()
        stack.transport.beforeResponding = { request in
            if request.action == "register_device" { await gate.parkFirstCaller() }
        }
        let inFlight = Task { await service.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered() }
        #expect(await gate.waitUntilParked())

        stack.push.pushState = .registered(tokenC)
        let joiner = Task { await service.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered() }
        for _ in 0..<50 { await Task.yield() }
        gate.release()
        _ = await inFlight.value
        _ = await joiner.value

        #expect(registeredDeviceTokens(stack.transport) == [tokenA.hexString, tokenB.hexString, tokenC.hexString])
        #expect(stack.transport.devices.filter(\.enabled).map(\.tokenHex) == [tokenC.hexString])
        #expect(stack.push.refreshCount == 0)
    }

    @Test("Chasing a token is bounded: a token that never stops changing cannot keep the registrar busy")
    func convergence_isBounded() async {
        let flips = Box(0)
        let push = stack.push
        stack.transport.beforeResponding = { request in
            guard request.action == "register_device" else { return }
            await MainActor.run {
                flips.value += 1
                push.pushState = .registered(flips.value % 2 == 1 ? tokenB : tokenA)
            }
        }

        let outcome = await service.reconcileDeviceRegistration()

        #expect(outcome == .registered)
        #expect(stack.transport.count(of: "register_device") == 1 + PriceAlertsDeviceRegistrar.maximumConvergenceRounds)
    }

    @Test("A failure is not chased: a failed attempt is left to the backoff, even if the token has changed")
    func failure_isNotChased() async {
        stack.transport.enqueue("register_device", .error(status: 500, code: "internal_error"))
        let push = stack.push
        stack.transport.beforeResponding = { request in
            if request.action == "register_device" { await MainActor.run { push.pushState = .registered(tokenB) } }
        }

        let outcome = await service.reconcileDeviceRegistration()

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(stack.transport.count(of: "register_device") == 1)
    }

    @Test("When nothing changed during the attempt there is no second one")
    func noChange_noSecondAttempt() async {
        #expect(await service.reconcileDeviceRegistration() == .registered)
        #expect(stack.transport.count(of: "register_device") == 1)
        #expect(stack.transport.count(of: "bootstrap") == 1)
    }
}

// MARK: - The real push service: no callback loop

/// Plays the OS and the AppDelegate for the REAL PushRegistrationService: every
/// `registerForRemoteNotifications()` is answered with the current token, and the AppDelegate's rule
/// (PushTokenChange) decides whether that is news worth a reconcile.
@MainActor
private final class LoopingOS: PushRegistrationSystem {
    var token = Data(repeating: 0x01, count: 32)
    weak var push: PushRegistrationService?
    private(set) var registerCount = 0
    private(set) var newTokenCallbacks = 0
    private(set) var pendingReconciles: [Task<Void, Never>] = []
    var onNewToken: (() -> Task<Void, Never>)?

    func authorizationStatus() async -> PushAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }

    func registerForRemoteNotifications() {
        registerCount += 1
        guard let push else { return }
        let previous = push.currentToken
        push.handleDeviceToken(token)
        if PushTokenChange.isNewToken(previous: previous, current: push.currentToken) {
            newTokenCallbacks += 1
            if let task = onNewToken?() { pendingReconciles.append(task) }
        }
    }
}

struct PriceAlertsCallbackLoopTests {
    private let transport = FakePriceAlertsTransport()
    private let os: LoopingOS
    private let push: PushRegistrationService
    private let service: PriceAlertsService

    init() {
        let os = LoopingOS()
        let push = PushRegistrationService(system: os)
        os.push = push
        self.os = os
        self.push = push
        service = PriceAlertsService.make(
            transport: transport,
            credentialStore: InMemoryPriceAlertsCredentialStore(),
            revenueCatIdentity: FakeIdentityProvider(),
            push: push,
            metadata: FakeMetadataProvider(),
            registrationRecords: InMemoryRegistrationRecordStore(),
            entitlement: FakeEntitlement(.active),
            sleep: { _ in await Task.yield() }
        )
        let service = self.service
        os.onNewToken = {
            // What AppDelegate does: don't block the callback; reconcile on a task.
            Task { _ = await service.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered() }
        }
    }

    @Test("Foreground after foreground, the OS answers with the same token and no callback starts another reconcile")
    func sameTokenRedelivery_doesNotLoop() async {
        #expect(await service.enablePushDelivery() == .registered)
        for task in os.pendingReconciles { await task.value }
        let callbacksAfterOptIn = os.newTokenCallbacks

        for _ in 0..<6 {
            #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .alreadyRegistered)
        }
        for task in os.pendingReconciles { await task.value }

        // Each foreground asked the OS once (that is the point of it), and none of the answers was news.
        #expect(os.registerCount == 1 + 6)
        #expect(os.newTokenCallbacks == callbacksAfterOptIn)
        #expect(transport.count(of: "register_device") == 1)
    }

    @Test("A rotated token is noticed on the next foreground, registered once, and then everything settles")
    func rotation_settles() async {
        _ = await service.enablePushDelivery()
        for task in os.pendingReconciles { await task.value }

        os.token = Data(repeating: 0x02, count: 32)
        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .registered)
        for task in os.pendingReconciles { await task.value }
        let registrationsAfterRotation = transport.count(of: "register_device")

        for _ in 0..<4 {
            #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .alreadyRegistered)
        }
        for task in os.pendingReconciles { await task.value }

        #expect(registrationsAfterRotation == 2)
        #expect(transport.count(of: "register_device") == 2)
        #expect(transport.devices.filter(\.enabled).map(\.tokenHex) == [String(repeating: "02", count: 32)])
    }

    @Test("A first-time opt-in: the token callback arrives before any registration exists, and changes nothing by itself")
    func firstOptIn_callbackIsInert() async {
        // Only the OS callback, as at a cold launch where nothing has been registered yet.
        os.registerForRemoteNotifications()
        for task in os.pendingReconciles { await task.value }

        #expect(os.newTokenCallbacks == 1)
        #expect(transport.requests.isEmpty)
        #expect(service.hasRegisteredDevice == false)
        #expect(service.lastDeviceRegistrationOutcome == nil)
    }
}
