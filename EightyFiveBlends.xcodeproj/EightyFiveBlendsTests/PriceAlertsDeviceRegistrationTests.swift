//
//  PriceAlertsDeviceRegistrationTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts client integration (Phase 3A) — keeping price-alerts-api's record of THIS device in step
//  with what the OS holds (PriceAlertsDeviceRegistration.swift, PushDeviceRegistrationMetadata.swift):
//  the APNs environment and bundle-identifier mapping, idempotent registration, token rotation, the
//  denied / no-token / unknown-environment paths that must not reach the network, failure containment
//  and bounded backoff, and the explicit opt-in flow. The final suite drives the REAL
//  PushRegistrationService (Phase 2) through a fake system, end to end.
//

import Foundation
import Testing
@testable import EightyFiveBlends

// MARK: - APNs environment and bundle id

private struct FakeProfileReader: ProvisioningProfileReading {
    let info: ProvisioningProfileInfo
    func read() -> ProvisioningProfileInfo { info }
}

private func profileBlob(entitlements: [String: Any]?, wrapped: Bool = true) throws -> Data {
    var plist: [String: Any] = ["Name": "Test Profile", "TeamName": "Example Team", "UUID": "0000"]
    if let entitlements { plist["Entitlements"] = entitlements }
    let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    guard wrapped else { return xml }
    // A real embedded.mobileprovision is a CMS envelope around the XML property list; the bytes
    // before and after are binary.
    return Data([0x30, 0x82, 0x0A, 0xFF, 0x06, 0x09, 0x2A, 0x86]) + xml + Data([0x00, 0x01, 0xFF, 0x30, 0x82, 0x04])
}

struct APNsEnvironmentTests {
    private let internalBundle = "com.e85blends.app.ios.internal"
    private let productionBundle = "com.e85blends.app.ios"

    private func metadata(bundle: String, profile: ProvisioningProfileInfo, simulator: Bool = false) -> PushDeviceRegistrationMetadata? {
        BundlePushDeviceRegistrationMetadataProvider(
            bundleIdentifier: bundle,
            profileReader: FakeProfileReader(info: profile),
            isSimulator: simulator
        ).currentMetadata()
    }

    @Test("Internal: delivered through TestFlight (no embedded profile) it is PRODUCTION with the internal topic; run from Xcode it is SANDBOX")
    func internalBuild_mapping() {
        let testFlight = metadata(bundle: internalBundle, profile: .absent)
        #expect(testFlight == PushDeviceRegistrationMetadata(bundleIdentifier: internalBundle, apnsEnvironment: .production))

        let xcodeRun = metadata(bundle: internalBundle, profile: .present(apsEnvironment: "development"))
        #expect(xcodeRun == PushDeviceRegistrationMetadata(bundleIdentifier: internalBundle, apnsEnvironment: .sandbox))
    }

    @Test("Production bundle: App Store / Ad Hoc is PRODUCTION, a development-signed run is SANDBOX — decided without running Production")
    func productionBuild_mapping() {
        let appStore = metadata(bundle: productionBundle, profile: .absent)
        #expect(appStore == PushDeviceRegistrationMetadata(bundleIdentifier: productionBundle, apnsEnvironment: .production))

        let adHoc = metadata(bundle: productionBundle, profile: .present(apsEnvironment: "production"))
        #expect(adHoc == PushDeviceRegistrationMetadata(bundleIdentifier: productionBundle, apnsEnvironment: .production))

        let debugOnDevice = metadata(bundle: productionBundle, profile: .present(apsEnvironment: "development"))
        #expect(debugOnDevice == PushDeviceRegistrationMetadata(bundleIdentifier: productionBundle, apnsEnvironment: .sandbox))
    }

    @Test("The bundle identifier is passed through verbatim — the Production and Internal identifiers can never be swapped by this code")
    func bundleIdentifier_isNeverRewritten() {
        for bundle in [internalBundle, productionBundle, "com.example.other"] {
            #expect(metadata(bundle: bundle, profile: .absent)?.bundleIdentifier == bundle)
        }
        // And the live provider reads the running bundle, not a constant.
        #expect(BundlePushDeviceRegistrationMetadataProvider().bundleIdentifier == Bundle.main.bundleIdentifier)
    }

    @Test("When the environment cannot be established nothing is guessed")
    func unresolvable_isNil() {
        #expect(metadata(bundle: productionBundle, profile: .unreadable) == nil)
        #expect(metadata(bundle: productionBundle, profile: .present(apsEnvironment: nil)) == nil)
        #expect(metadata(bundle: productionBundle, profile: .present(apsEnvironment: "staging")) == nil)
        #expect(metadata(bundle: productionBundle, profile: .present(apsEnvironment: "")) == nil)
    }

    @Test("The Simulator reports sandbox whatever it finds — its tokens can never be delivered to anyway")
    func simulator_isSandbox() {
        for profile in [ProvisioningProfileInfo.absent, .unreadable, .present(apsEnvironment: "production"), .present(apsEnvironment: nil)] {
            #expect(APNsEnvironmentResolver.resolve(profile: profile, isSimulator: true) == .sandbox)
        }
    }

    @Test("Bundle identifiers the backend would reject produce no metadata")
    func metadata_validation() {
        #expect(PushDeviceRegistrationMetadata(bundleIdentifier: nil, apnsEnvironment: .production) == nil)
        #expect(PushDeviceRegistrationMetadata(bundleIdentifier: "", apnsEnvironment: .production) == nil)
        #expect(PushDeviceRegistrationMetadata(bundleIdentifier: "ab", apnsEnvironment: .production) == nil)
        #expect(PushDeviceRegistrationMetadata(bundleIdentifier: "abc", apnsEnvironment: .production) != nil)
        #expect(PushDeviceRegistrationMetadata(bundleIdentifier: String(repeating: "a", count: 255), apnsEnvironment: .production) != nil)
        #expect(PushDeviceRegistrationMetadata(bundleIdentifier: String(repeating: "a", count: 256), apnsEnvironment: .production) == nil)
        #expect(PushDeviceRegistrationMetadata(bundleIdentifier: " com.example.app", apnsEnvironment: .production) == nil)
        #expect(PushDeviceRegistrationMetadata(bundleIdentifier: "com.example\n.app", apnsEnvironment: .production) == nil)
    }

    @Test("The provisioning profile's aps-environment is read from inside its CMS envelope")
    func profileParser_readsEntitlement() throws {
        #expect(ProvisioningProfileParser.parse(try profileBlob(entitlements: ["aps-environment": "development"])) == .present(apsEnvironment: "development"))
        #expect(ProvisioningProfileParser.parse(try profileBlob(entitlements: ["aps-environment": "production", "get-task-allow": false])) == .present(apsEnvironment: "production"))
        // A bare XML plist (no envelope) parses too.
        #expect(ProvisioningProfileParser.parse(try profileBlob(entitlements: ["aps-environment": "development"], wrapped: false)) == .present(apsEnvironment: "development"))
    }

    @Test("A profile without the push entitlement is present but has no environment")
    func profileParser_noPushEntitlement() throws {
        #expect(ProvisioningProfileParser.parse(try profileBlob(entitlements: ["get-task-allow": true])) == .present(apsEnvironment: nil))
        #expect(ProvisioningProfileParser.parse(try profileBlob(entitlements: nil)) == .present(apsEnvironment: nil))
        #expect(ProvisioningProfileParser.parse(try profileBlob(entitlements: ["aps-environment": 7])) == .present(apsEnvironment: nil))
    }

    @Test("Garbage, truncated or hostile profile bytes are 'unreadable' — never a trap")
    func profileParser_isTotal() throws {
        #expect(ProvisioningProfileParser.parse(Data()) == .unreadable)
        #expect(ProvisioningProfileParser.parse(Data(repeating: 0xFF, count: 4_096)) == .unreadable)
        #expect(ProvisioningProfileParser.parse(Data("<?xml version=\"1.0\"?><plist><dict>".utf8)) == .unreadable)
        #expect(ProvisioningProfileParser.parse(Data("</plist><?xml".utf8)) == .unreadable)
        #expect(ProvisioningProfileParser.parse(Data("<?xml version=\"1.0\"?><plist><array/></plist>".utf8)) == .unreadable)
        #expect(ProvisioningProfileParser.parse(Data("<?xml version=\"1.0\"?><plist><dict><key>Entitlements".utf8) + Data("</plist>".utf8)) == .unreadable)
        var noise = Data()
        for index in 0..<2_000 { noise.append(UInt8(truncatingIfNeeded: index &* 31 &+ 7)) }
        #expect(ProvisioningProfileParser.parse(noise) == .unreadable)
    }
}

// MARK: - Fingerprint and backoff

struct PriceAlertsFingerprintAndBackoffTests {
    private let installation = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
    private let metadata = PushDeviceRegistrationMetadata(bundleIdentifier: "com.example.app", apnsEnvironment: .production)!

    @Test("The fingerprint is stable, 64 lowercase hex characters, and moves with every component")
    func fingerprint_components() throws {
        let token = FakePushState.token(1)
        let base = PriceAlertsDeviceFingerprint.make(installationID: installation, token: token, metadata: metadata)

        #expect(base == PriceAlertsDeviceFingerprint.make(installationID: installation, token: token, metadata: metadata))
        #expect(base.count == 64)
        #expect(base.allSatisfy { "0123456789abcdef".contains($0) })

        let otherInstallation = PriceAlertsDeviceFingerprint.make(installationID: UUID(), token: token, metadata: metadata)
        let otherToken = PriceAlertsDeviceFingerprint.make(installationID: installation, token: FakePushState.token(2), metadata: metadata)
        let otherEnvironment = PriceAlertsDeviceFingerprint.make(installationID: installation, token: token, metadata: PushDeviceRegistrationMetadata(bundleIdentifier: "com.example.app", apnsEnvironment: .sandbox)!)
        let otherBundle = PriceAlertsDeviceFingerprint.make(installationID: installation, token: token, metadata: PushDeviceRegistrationMetadata(bundleIdentifier: "com.example.app.internal", apnsEnvironment: .production)!)
        #expect(Set([base, otherInstallation, otherToken, otherEnvironment, otherBundle]).count == 5)
    }

    @Test("The fingerprint is one-way: neither the token nor the installation id appears in it")
    func fingerprint_revealsNothing() {
        let token = FakePushState.token(0xAB)
        let fingerprint = PriceAlertsDeviceFingerprint.make(installationID: installation, token: token, metadata: metadata)
        #expect(fingerprint.contains(token.hexString) == false)
        #expect(fingerprint.contains("abababab") == false)
        #expect(fingerprint.contains(installation.uuidString.lowercased()) == false)
    }

    @Test("Backoff waits 30 s, 2 min, 10 min, then 30 min between automatic attempts, and success clears it")
    func backoff_schedule() {
        var backoff = PriceAlertsRetryBackoff()
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(backoff.blockedUntil(now: start) == nil)

        var observed: [TimeInterval] = []
        for _ in 0..<6 {
            backoff.recordFailure(at: start)
            observed.append(backoff.blockedUntil(now: start)!.timeIntervalSince(start))
        }
        #expect(observed == [30, 120, 600, 1_800, 1_800, 1_800])
        #expect(backoff.consecutiveFailures == 6)

        // The wait ends exactly at its deadline.
        #expect(backoff.blockedUntil(now: start.addingTimeInterval(1_799)) != nil)
        #expect(backoff.blockedUntil(now: start.addingTimeInterval(1_800)) == nil)

        backoff.recordSuccess()
        #expect(backoff.consecutiveFailures == 0)
        #expect(backoff.blockedUntil(now: start) == nil)
    }
}

// MARK: - Registration

struct PriceAlertsDeviceRegistrarTests {
    private let stack: PriceAlertsStack
    private let tokenA = FakePushState.token(0xA1)
    private let tokenB = FakePushState.token(0xB2)

    init() {
        stack = PriceAlertsStack(push: .registered(FakePushState.token(0xA1)))
    }

    private var service: PriceAlertsService { stack.service }
    private var transport: FakePriceAlertsTransport { stack.transport }

    // MARK: Registering

    @Test("A valid token registers once: bootstrap first, then register_device with the token, bundle id and environment")
    func validToken_registersOnce() async throws {
        stack.metadata.metadata = PushDeviceRegistrationMetadata(bundleIdentifier: "com.e85blends.app.ios.internal", apnsEnvironment: .production)

        let outcome = await service.reconcileDeviceRegistration()

        #expect(outcome == .registered)
        #expect(transport.actions == ["bootstrap", "register_device"])
        let request = try #require(transport.lastRequest("register_device"))
        #expect(request.json["device_token"] as? String == tokenA.hexString)
        #expect(request.json["bundle_id"] as? String == "com.e85blends.app.ios.internal")
        #expect(request.json["apns_environment"] as? String == "production")
        #expect(request.json["platform"] as? String == "ios")
        #expect(stack.records.saveCount == 1)
        #expect(service.lastDeviceRegistrationOutcome == .registered)
    }

    @Test("An identical token causes no further calls — however often it is reconciled")
    func identicalToken_isIdempotent() async {
        let outcomes = [
            await service.reconcileDeviceRegistration(),
            await service.reconcileDeviceRegistration(),
            await service.reconcileDeviceRegistration(),
        ]

        #expect(outcomes == [.registered, .alreadyRegistered, .alreadyRegistered])
        #expect(transport.count(of: "register_device") == 1)
        #expect(transport.count(of: "bootstrap") == 1)
        #expect(transport.devices.filter(\.enabled).count == 1)
        #expect(stack.records.saveCount == 1)
    }

    @Test("A rotated token is sent, and the server retires the old one")
    func tokenRotation_sendsUpdate() async throws {
        _ = await service.reconcileDeviceRegistration()

        stack.push.pushState = .registered(tokenB)
        let outcome = await service.reconcileDeviceRegistration()

        #expect(outcome == .registered)
        #expect(transport.count(of: "register_device") == 2)
        #expect(transport.lastRequest("register_device")?.json["device_token"] as? String == tokenB.hexString)
        let enabled = transport.devices.filter(\.enabled)
        #expect(enabled.count == 1)
        #expect(enabled.first?.tokenHex == tokenB.hexString)
        #expect(transport.devices.contains { $0.tokenHex == tokenA.hexString && $0.enabled == false })
        // Still only one bootstrap: the installation was not recreated.
        #expect(transport.count(of: "bootstrap") == 1)
    }

    @Test("A changed environment or bundle identifier is a new registration")
    func changedMetadata_registersAgain() async {
        _ = await service.reconcileDeviceRegistration()
        stack.metadata.metadata = PushDeviceRegistrationMetadata(bundleIdentifier: "com.example.app", apnsEnvironment: .sandbox)
        #expect(await service.reconcileDeviceRegistration() == .registered)
        stack.metadata.metadata = PushDeviceRegistrationMetadata(bundleIdentifier: "com.example.app.internal", apnsEnvironment: .sandbox)
        #expect(await service.reconcileDeviceRegistration() == .registered)
        #expect(transport.count(of: "register_device") == 3)
    }

    @Test("A recreated installation (new id) registers the same token again")
    func recreatedInstallation_registersAgain() async {
        _ = await service.reconcileDeviceRegistration()
        stack.credentials.stored = PriceAlertsInstallationCredential.generate()

        let outcome = await service.reconcileDeviceRegistration()

        #expect(outcome == .registered)
        #expect(transport.count(of: "register_device") == 2)
    }

    @Test("An unchanged registration is repeated after 24 hours, which also revives a device the worker invalidated")
    func staleRecord_isRefreshed() async {
        _ = await service.reconcileDeviceRegistration()

        stack.clock.advance(by: PriceAlertsDeviceRegistrar.refreshInterval - 60)
        #expect(await service.reconcileDeviceRegistration() == .alreadyRegistered)

        stack.clock.advance(by: 120)
        #expect(await service.reconcileDeviceRegistration() == .registered)
        #expect(transport.count(of: "register_device") == 2)
    }

    @Test("A record dated in the future (the clock moved back) is not trusted")
    func futureRecord_isNotTrusted() async throws {
        _ = await service.reconcileDeviceRegistration()
        let record = try #require(stack.records.record)
        stack.records.record = PriceAlertsDeviceRegistrationRecord(fingerprint: record.fingerprint, registeredAt: stack.clock.now.addingTimeInterval(3_600))

        #expect(await service.reconcileDeviceRegistration() == .registered)
    }

    // MARK: Paths that must not reach the network

    @Test("A user who denied notifications is not registered, and no installation is created for them")
    func denied_doesNotRegister() async {
        stack.push.pushState = .denied

        let outcome = await service.reconcileDeviceRegistration()

        #expect(outcome == .skipped(.notificationsDenied))
        #expect(transport.requests.isEmpty)
        #expect(stack.credentials.saveCount == 0)
        #expect(stack.records.saveCount == 0)
    }

    @Test("No token — not requested, awaiting the OS, or the OS failed — means nothing to register, and no crash")
    func missingToken_doesNotRegister() async {
        let states: [PushRegistrationState] = [
            .notRequested,
            .authorizedAwaitingToken,
            .failed(.registrationFailed(domain: "NSCocoaErrorDomain", code: 3000)),
            .failed(.invalidToken),
            .failed(.authorizationRequestFailed),
        ]
        for state in states {
            stack.push.pushState = state
            // Neither refresh nor the OS gives a token here.
            #expect(await service.reconcileDeviceRegistration() == .skipped(.noDeviceToken), "\(state)")
        }
        #expect(transport.requests.isEmpty)
        #expect(stack.credentials.saveCount == 0)
    }

    @Test("An APNs environment that cannot be established is never guessed: nothing is registered")
    func unresolvedEnvironment_skips() async {
        stack.metadata.metadata = nil

        let outcome = await service.reconcileDeviceRegistration()

        #expect(outcome == .skipped(.pushEnvironmentUnresolved))
        #expect(transport.requests.isEmpty)
        #expect(stack.credentials.saveCount == 0)
    }

    // MARK: Failure containment and backoff

    @Test("A backend failure leaves the push token, the push state and the previous record untouched")
    func backendFailure_preservesGoodLocalState() async throws {
        #expect(await service.reconcileDeviceRegistration() == .registered)
        let goodRecord = try #require(stack.records.record)

        stack.push.pushState = .registered(tokenB)
        transport.enqueue("register_device", .error(status: 500, code: "internal_error"))
        let outcome = await service.reconcileDeviceRegistration()

        #expect(outcome == .failed(.api(.api(code: .internalError, statusCode: 500))))
        // The token the OS gave us is still held, exactly as it was.
        #expect(stack.push.pushState == .registered(tokenB))
        // The previous good registration is still on record (so the new token is retried), not erased.
        #expect(stack.records.record == goodRecord)
        #expect(stack.records.clearCount == 0)
        #expect(service.lastDeviceRegistrationOutcome == outcome)
    }

    @Test("After a failure, automatic attempts wait; an explicit action does not; success resets the wait")
    func failure_startsBoundedBackoff() async throws {
        _ = await service.reconcileDeviceRegistration()
        stack.push.pushState = .registered(tokenB)
        transport.enqueue("register_device", .error(status: 503, code: "server_not_configured"))
        let failedAt = stack.clock.now
        _ = await service.reconcileDeviceRegistration()
        let callsAfterFailure = transport.requests.count

        // Automatic: held off, with no network call.
        let held = await service.reconcileDeviceRegistrationIfPreviouslyRegistered()
        #expect(held == .skipped(.backingOff(until: failedAt.addingTimeInterval(30))))
        #expect(transport.requests.count == callsAfterFailure)

        // Once the wait has passed, an automatic attempt goes through.
        stack.clock.advance(by: 31)
        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .registered)
        #expect(transport.lastRequest("register_device")?.json["device_token"] as? String == tokenB.hexString)
    }

    @Test("An explicit user action bypasses the wait but still makes exactly one attempt")
    func userInitiated_bypassesBackoff() async {
        _ = await service.reconcileDeviceRegistration()
        stack.push.pushState = .registered(tokenB)
        transport.enqueue("register_device", .error(status: 503, code: "server_not_configured"))
        _ = await service.reconcileDeviceRegistration()
        let registerCallsBefore = transport.count(of: "register_device")

        let outcome = await service.reconcileDeviceRegistration()

        #expect(outcome == .registered)
        #expect(transport.count(of: "register_device") == registerCallsBefore + 1)
    }

    @Test("Repeated failures lengthen the wait: 30 s, 2 min, 10 min, then 30 min — and never retry by themselves")
    func repeatedFailures_escalate() async {
        _ = await service.reconcileDeviceRegistration()
        stack.push.pushState = .registered(tokenB)
        var observedWaits: [TimeInterval] = []

        for _ in 0..<5 {
            transport.enqueue("register_device", .error(status: 500, code: "internal_error"))
            let before = stack.clock.now
            _ = await service.reconcileDeviceRegistration()
            if case .skipped(.backingOff(let until)) = await service.reconcileDeviceRegistrationIfPreviouslyRegistered() {
                observedWaits.append(until.timeIntervalSince(before))
            }
            stack.clock.advance(by: 3_600)
        }

        #expect(observedWaits == [30, 120, 600, 1_800, 1_800])
        // 1 initial success + 5 explicit failing attempts; nothing else ever called the server.
        #expect(transport.count(of: "register_device") == 6)
    }

    @Test("Concurrent reconciles share one attempt")
    func concurrentReconciles_shareOneAttempt() async {
        let gate = AsyncGate()
        transport.beforeResponding = { request in
            if request.action == "register_device" { await gate.parkFirstCaller() }
        }

        let first = Task { await service.reconcileDeviceRegistration() }
        #expect(await gate.waitUntilParked())
        let second = Task { await service.reconcileDeviceRegistration() }
        for _ in 0..<50 { await Task.yield() }
        gate.release()

        let outcomes = [await first.value, await second.value]
        #expect(outcomes == [.registered, .registered])
        #expect(transport.count(of: "register_device") == 1)
    }

    // MARK: Free users and lapsed subscribers

    @Test("Registering when it would create a new installation needs Pro")
    func newInstallation_needsPro() async {
        stack.entitlement.entitlement = .inactive
        #expect(await service.reconcileDeviceRegistration() == .skipped(.proRequired))

        stack.entitlement.entitlement = .unresolved
        #expect(await service.reconcileDeviceRegistration() == .skipped(.entitlementUnresolved))

        #expect(transport.requests.isEmpty)
        #expect(stack.credentials.saveCount == 0)
    }

    @Test("A lapsed subscriber's existing installation keeps its device registration current")
    func lapsedSubscriber_withInstallation_canStillRegister() async {
        #expect(await service.reconcileDeviceRegistration() == .registered)
        stack.entitlement.entitlement = .inactive
        stack.push.pushState = .registered(tokenB)

        #expect(await service.reconcileDeviceRegistration() == .registered)
        #expect(transport.count(of: "register_device") == 2)
        #expect(transport.count(of: "bootstrap") == 1)
    }

    // MARK: Opt-in

    @Test("Opting in as a Free user with no installation neither prompts for permission nor creates anything")
    func enable_freeUser_isNeitherPromptedNorRegistered() async {
        stack.push.pushState = .notRequested
        stack.entitlement.entitlement = .inactive

        let outcome = await service.enablePushDelivery()

        #expect(outcome == .skipped(.proRequired))
        #expect(stack.push.optInCount == 0)
        #expect(transport.requests.isEmpty)
        #expect(stack.credentials.saveCount == 0)
    }

    @Test("Opting in as Pro prompts once, waits for the OS token, then registers it (bootstrap before register)")
    func enable_proUser_promptsWaitsAndRegisters() async {
        stack.push.pushState = .notRequested
        let push = stack.push
        let token = tokenA
        push.onOptIn = { push.pushState = .authorizedAwaitingToken }
        // The OS delivers the token during the third wait.
        stack.sleeper.onSleep = { number in
            if number == 3 { push.pushState = .registered(token) }
        }

        let outcome = await service.enablePushDelivery()

        #expect(outcome == .registered)
        #expect(push.optInCount == 1)
        #expect(stack.sleeper.count == 3)
        #expect(transport.actions == ["bootstrap", "register_device"])
    }

    @Test("If the user says no at the system prompt, nothing is registered and no installation is created")
    func enable_userDenies() async {
        stack.push.pushState = .notRequested
        let push = stack.push
        push.onOptIn = { push.pushState = .denied }

        let outcome = await service.enablePushDelivery()

        #expect(outcome == .skipped(.notificationsDenied))
        #expect(push.optInCount == 1)
        #expect(transport.requests.isEmpty)
        #expect(stack.credentials.saveCount == 0)
    }

    @Test("If the OS never delivers a token the wait is bounded")
    func enable_tokenNeverArrives_isBounded() async {
        stack.push.pushState = .notRequested
        let push = stack.push
        push.onOptIn = { push.pushState = .authorizedAwaitingToken }

        let outcome = await service.enablePushDelivery()

        #expect(outcome == .skipped(.noDeviceToken))
        #expect(stack.sleeper.count == PriceAlertsDeviceRegistrar.maximumTokenPolls)
        #expect(transport.requests.isEmpty)
    }

    @Test("A returning user's refresh asks the OS for the token and never prompts")
    func refresh_returningUser_neverPrompts() async {
        _ = await service.reconcileDeviceRegistration()

        #expect(stack.push.refreshCount == 1)
        #expect(stack.push.optInCount == 0)
    }

    // MARK: App-level, opt-in-only reconciliation

    @Test("For an install that never registered, the app-level hook is a complete no-op: no OS call, no network, no storage")
    func appLevelHook_isNoOpWithoutPriorRegistration() async {
        let outcome = await service.reconcileDeviceRegistrationIfPreviouslyRegistered()

        #expect(outcome == .skipped(.notOptedIn))
        #expect(stack.totalSideEffects == 0)
        #expect(stack.credentials.loadCount == 0)
    }

    @Test("For an install that registered before, the app-level hook re-reads the OS token and registers only what changed")
    func appLevelHook_reconcilesPreviousRegistration() async {
        _ = await service.reconcileDeviceRegistration()
        let refreshesBefore = stack.push.refreshCount

        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .alreadyRegistered)
        #expect(stack.push.refreshCount == refreshesBefore + 1)

        stack.push.pushState = .registered(tokenB)
        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .registered)
        #expect(transport.count(of: "register_device") == 2)
    }

    // MARK: Turning delivery off

    @Test("Disabling retires the held token on the server, forgets the fingerprint, and is not undone automatically")
    func unregister_retiresToken() async throws {
        _ = await service.reconcileDeviceRegistration()

        let changed = try await service.disablePushDelivery()

        #expect(changed)
        #expect(transport.lastRequest("unregister_device")?.json["device_token"] as? String == tokenA.hexString)
        #expect(stack.records.record == nil)
        #expect(transport.devices.filter(\.enabled).isEmpty)
        // No hidden re-registration.
        #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .skipped(.notOptedIn))
        #expect(transport.count(of: "register_device") == 1)
    }

    @Test("Disabling when the OS has no token to give does nothing on the server")
    func unregister_withoutToken() async throws {
        stack.push.pushState = .notRequested

        let changed = try await service.disablePushDelivery()

        #expect(changed == false)
        #expect(transport.requests.isEmpty)
        // The OS was asked (never prompted); it had nothing.
        #expect(stack.push.refreshCount == 1)
        #expect(stack.push.optInCount == 0)
    }

    @Test("After a relaunch the token is not held yet: disabling asks the OS for it first, then retires it")
    func unregister_afterRelaunch_fetchesTheTokenFirst() async throws {
        #expect(await service.reconcileDeviceRegistration() == .registered)
        // A relaunch: the push service has forgotten the token (it never persists it); the record remains.
        let push = stack.push
        let token = tokenA
        push.pushState = .notRequested
        push.onRefresh = { push.pushState = .registered(token) }

        let changed = try await service.disablePushDelivery()

        #expect(changed)
        #expect(transport.lastRequest("unregister_device")?.json["device_token"] as? String == tokenA.hexString)
        #expect(stack.records.record == nil)
        #expect(stack.push.optInCount == 0)
    }

    @Test("A failed unregister keeps the record, so the registration is not forgotten")
    func unregister_failure_keepsRecord() async throws {
        _ = await service.reconcileDeviceRegistration()
        let record = stack.records.record
        transport.enqueue("unregister_device", .error(status: 500, code: "internal_error"))

        await #expect(throws: PriceAlertsServiceError.api(.api(code: .internalError, statusCode: 500))) {
            try await service.disablePushDelivery()
        }
        #expect(stack.records.record == record)
    }
}

// MARK: - End to end with the real PushRegistrationService

/// A scriptable system seam for the REAL PushRegistrationService (Phase 2).
@MainActor
private final class FakeOSPushSystem: PushRegistrationSystem {
    var status: PushAuthorizationStatus
    var userGrants = true
    var tokenToDeliver: Data?
    var failRegistration = false
    weak var service: PushRegistrationService?

    private(set) var promptCount = 0
    private(set) var registerCount = 0

    init(status: PushAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> PushAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        promptCount += 1
        status = userGrants ? .authorized : .denied
        return userGrants
    }

    /// Plays the AppDelegate: the OS answers by calling back into the service.
    func registerForRemoteNotifications() {
        registerCount += 1
        if failRegistration {
            service?.handleRegistrationFailure(NSError(domain: "NSCocoaErrorDomain", code: 3000))
        } else if let tokenToDeliver {
            service?.handleDeviceToken(tokenToDeliver)
        }
    }
}

struct PriceAlertsWithRealPushServiceTests {
    private let transport = FakePriceAlertsTransport()
    private let system: FakeOSPushSystem
    private let push: PushRegistrationService
    private let credentials = InMemoryPriceAlertsCredentialStore()
    private let service: PriceAlertsService

    init(status: PushAuthorizationStatus = .notDetermined) {
        let system = FakeOSPushSystem(status: status)
        let push = PushRegistrationService(system: system)
        system.service = push
        self.system = system
        self.push = push
        service = PriceAlertsService.make(
            transport: transport,
            credentialStore: credentials,
            revenueCatIdentity: FakeIdentityProvider(),
            push: push,
            metadata: FakeMetadataProvider(bundle: "com.e85blends.app.ios.internal", environment: .production),
            registrationRecords: InMemoryRegistrationRecordStore(),
            entitlement: FakeEntitlement(.active),
            sleep: { _ in await Task.yield() }
        )
    }

    @Test("Opt-in end to end: the system prompt, the OS callback, then bootstrap and register_device with the hex token")
    func optIn_endToEnd() async throws {
        system.tokenToDeliver = Data(repeating: 0x5C, count: 32)

        let outcome = await service.enablePushDelivery()

        #expect(outcome == .registered)
        #expect(system.promptCount == 1)
        #expect(system.registerCount == 1)
        #expect(transport.actions == ["bootstrap", "register_device"])
        let request = try #require(transport.lastRequest("register_device"))
        #expect(request.json["device_token"] as? String == String(repeating: "5c", count: 32))
        #expect(request.json["bundle_id"] as? String == "com.e85blends.app.ios.internal")
        #expect(request.json["apns_environment"] as? String == "production")
    }

    @Test("A user who denies at the prompt is never registered")
    func optIn_denied() async {
        system.userGrants = false
        system.tokenToDeliver = Data(repeating: 0x5C, count: 32)

        let outcome = await service.enablePushDelivery()

        #expect(outcome == .skipped(.notificationsDenied))
        #expect(system.registerCount == 0)
        #expect(transport.requests.isEmpty)
        #expect(credentials.saveCount == 0)
    }

    @Test("Where the OS cannot register (a simulator, no Push capability) the result is a clean skip, not a crash")
    func optIn_osRegistrationFails() async {
        system.failRegistration = true

        let outcome = await service.enablePushDelivery()

        #expect(outcome == .skipped(.noDeviceToken))
        #expect(transport.requests.isEmpty)
        if case .failed = push.state {} else { Issue.record("the service should be in its non-fatal failed state") }
    }

    @Test("A token the OS rotates later is picked up by the next reconcile, and the old one is retired")
    func rotation_endToEnd() async {
        system.tokenToDeliver = Data(repeating: 0x01, count: 32)
        _ = await service.enablePushDelivery()

        // The OS later hands the app a different token — and from then on answers every
        // registerForRemoteNotifications() with it, as the real OS does.
        system.tokenToDeliver = Data(repeating: 0x02, count: 32)
        push.handleDeviceToken(Data(repeating: 0x02, count: 32))
        let outcome = await service.reconcileDeviceRegistration()

        #expect(outcome == .registered)
        #expect(transport.devices.filter(\.enabled).map(\.tokenHex) == [String(repeating: "02", count: 32)])
        #expect(transport.count(of: "register_device") == 2)
    }

    @Test("A returning, already-authorized user is reconciled without ever being prompted")
    func returningUser_neverPrompted() async {
        let returning = PriceAlertsWithRealPushServiceTests(status: .authorized)
        returning.system.tokenToDeliver = Data(repeating: 0x07, count: 32)
        // Establish a prior registration so the app-level hook has something to reconcile.
        _ = await returning.service.reconcileDeviceRegistration()

        let outcome = await returning.service.reconcileDeviceRegistrationIfPreviouslyRegistered()

        #expect(outcome == .alreadyRegistered)
        #expect(returning.system.promptCount == 0)
    }
}
