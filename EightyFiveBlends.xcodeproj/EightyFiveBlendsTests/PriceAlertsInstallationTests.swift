//
//  PriceAlertsInstallationTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts client integration (Phase 3A) — the installation credential, its Keychain storage
//  rules, and the lifecycle that creates, bootstraps, reuses and recovers it
//  (PriceAlertsCredentialStore.swift, PriceAlertsInstallation.swift). The real Keychain is never
//  touched: the storage rules are asserted on the exact attributes handed to `KeychainItemAccessing`.
//
//  No assertion here prints a secret.
//

import Foundation
import Security
import Testing
@testable import EightyFiveBlends

// MARK: - Credential

struct PriceAlertsCredentialTests {
    @Test("A generated credential is acceptable to the backend: a v4 UUID and a 64-character base64url secret")
    func generate_isBackendAcceptable() {
        var ids = Set<UUID>()
        var secrets = Set<String>()
        for _ in 0..<50 {
            let credential = PriceAlertsInstallationCredential.generate()
            #expect(credential.isValid)
            #expect(credential.installationSecret.count == 64)
            #expect(credential.installationSecret.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })

            // The backend's UUID_RE: version nibble 1–5 and variant 8/9/a/b, lower-case on the wire.
            let wire = Array(credential.wireInstallationID)
            #expect(wire.count == 36)
            #expect(credential.wireInstallationID == credential.wireInstallationID.lowercased())
            #expect(wire[14] == "4")
            #expect("89ab".contains(wire[19]))

            ids.insert(credential.installationID)
            secrets.insert(credential.installationSecret)
        }
        #expect(ids.count == 50)
        #expect(secrets.count == 50)
    }

    @Test("Secret validity follows the backend: 32–512 printable ASCII characters, nothing a trim() could alter")
    func validity() {
        func valid(_ secret: String) -> Bool {
            PriceAlertsInstallationCredential(installationID: UUID(), installationSecret: secret).isValid
        }
        #expect(valid(String(repeating: "a", count: 32)))
        #expect(valid(String(repeating: "a", count: 512)))
        #expect(valid(String(repeating: "a", count: 31)) == false)
        #expect(valid(String(repeating: "a", count: 513)) == false)
        #expect(valid("") == false)
        #expect(valid(String(repeating: "a", count: 31) + " ") == false)
        #expect(valid(" " + String(repeating: "a", count: 32)) == false)
        #expect(valid(String(repeating: "a", count: 16) + " " + String(repeating: "a", count: 16)) == false)
        #expect(valid(String(repeating: "a", count: 32) + "\n") == false)
        #expect(valid(String(repeating: "é", count: 32)) == false)
        #expect(valid(String(repeating: "a", count: 31) + "é") == false)
    }

    @Test("The secret appears in no description, debug description, reflection or dump of the credential or anything holding it")
    func secret_neverAppearsInDescriptions() throws {
        let secret = "SECRET-" + String(repeating: "x", count: 40)
        let credential = PriceAlertsInstallationCredential(installationID: UUID(), installationSecret: secret)
        let draft = try PriceAlertDraft(communityStationID: PriceAlertsStack.stationID(), rule: .priceDrop)
        let request = PriceAlertsWireRequest.setAlert(credential: credential, draft: draft)
        let session = PriceAlertsInstallationSession(credential: credential, serverProIsActive: true, revenueCatLinked: true, includedRevenueCatIdentity: true)

        var dumped = ""
        dump(credential, to: &dumped)
        dump(request, to: &dumped)
        dump(session, to: &dumped)
        dump([credential], to: &dumped)
        dump(Optional(credential), to: &dumped)

        let texts = [
            String(describing: credential), String(reflecting: credential), "\(credential)", credential.description,
            credential.debugDescription, String(describing: request), String(reflecting: request),
            String(describing: session), String(describing: [credential]), String(describing: Optional(credential)),
            dumped,
        ]
        for text in texts {
            #expect(text.contains(secret) == false)
            #expect(text.contains("xxxxxxxx") == false)
        }
        #expect(Mirror(reflecting: credential).children.isEmpty)
        #expect(String(describing: credential).contains("redacted"))
    }

    @Test("The RevenueCat identity and the device token are redacted too")
    func otherSensitiveValues_areRedacted() throws {
        let identity = PriceAlertsRevenueCatIdentity(appUserID: "$RCAnonymousID:very-private-id", environment: .sandbox)
        let token = FakePushState.token(0xAB)
        var dumped = ""
        dump(identity, to: &dumped)
        dump(token, to: &dumped)
        let credential = PriceAlertsInstallationCredential.generate()
        let metadata = try #require(PushDeviceRegistrationMetadata(bundleIdentifier: "com.example.app", apnsEnvironment: .production))
        dump(PriceAlertsWireRequest.registerDevice(credential: credential, token: token, metadata: metadata), to: &dumped)
        dump(PriceAlertsWireRequest.bootstrap(credential: credential, revenueCat: identity, appVersion: "1"), to: &dumped)

        #expect(String(describing: identity).contains("very-private-id") == false)
        #expect(dumped.contains("very-private-id") == false)
        #expect(dumped.contains(token.hexString) == false)
        #expect(dumped.contains(credential.installationSecret) == false)
    }

    @Test("The app version reported at bootstrap is 'version (build)', tolerating either half missing")
    func appVersionFormatting() {
        #expect(PriceAlertsAppVersion.format(shortVersion: "2.4.1", build: "100") == "2.4.1 (100)")
        #expect(PriceAlertsAppVersion.format(shortVersion: " 2.4.1 ", build: nil) == "2.4.1")
        #expect(PriceAlertsAppVersion.format(shortVersion: nil, build: "100") == "(100)")
        #expect(PriceAlertsAppVersion.format(shortVersion: "", build: "  ") == nil)
        #expect(PriceAlertsAppVersion.format(shortVersion: nil, build: nil) == nil)
    }
}

// MARK: - Keychain store (the storage rules)

struct KeychainPriceAlertsCredentialStoreTests {
    private let keychain = FakeKeychain()
    private var store: KeychainPriceAlertsCredentialStore { KeychainPriceAlertsCredentialStore(keychain: keychain) }

    private func credential() -> PriceAlertsInstallationCredential {
        PriceAlertsInstallationCredential.generate()
    }

    @Test("A new credential is added as ONE generic-password item, device-only and never synchronizable")
    func save_newItem_isDeviceOnly() throws {
        let saved = credential()

        try store.save(saved)

        // Update-first, then add on not-found.
        #expect(keychain.updateCount == 1)
        let add = try #require(keychain.addCalls.first)
        #expect(keychain.addCalls.count == 1)
        #expect(add[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(add[kSecAttrService as String] as? String == "com.e85blends.app.pricealerts.installation")
        #expect(add[kSecAttrAccount as String] as? String == "installationCredential")
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        // Never eligible for iCloud Keychain: no synchronizable attribute is set anywhere.
        for dictionary in keychain.allDictionaries {
            #expect(dictionary[kSecAttrSynchronizable as String] == nil)
        }
        // Id AND secret live together in the one item.
        let data = try #require(add[kSecValueData as String] as? Data)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["installationSecret"] as? String == saved.installationSecret)
        #expect((object["installationID"] as? String).flatMap(UUID.init(uuidString:)) == saved.installationID)
    }

    @Test("Saving over an existing item updates it in place — nothing is deleted first, nothing is added twice")
    func save_existingItem_updatesInPlace() throws {
        try store.save(credential())
        let replacement = credential()

        try store.save(replacement)

        #expect(keychain.addCalls.count == 1)
        #expect(keychain.updateCount == 2)
        #expect(try store.loadCredential() == replacement)
    }

    @Test("A stored credential round-trips")
    func load_roundTrips() throws {
        let saved = credential()
        try store.save(saved)
        #expect(try store.loadCredential() == saved)
    }

    @Test("The read asks for the item's data, one match, and carries no synchronizable attribute")
    func load_query() throws {
        _ = try store.loadCredential()
        guard case .copy(let query) = try #require(keychain.calls.first) else {
            Issue.record("first call was not a read")
            return
        }
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecAttrService as String] as? String == "com.e85blends.app.pricealerts.installation")
        #expect(query[kSecAttrSynchronizable as String] == nil)
    }

    @Test("Nothing stored is simply absent")
    func load_notFound_isNil() throws {
        #expect(try store.loadCredential() == nil)
    }

    @Test("An item whose bytes do not decode is corruption of content, treated as absent so it can be replaced")
    func load_corruptPayload_isAbsent() throws {
        keychain.item = Data("this is not a credential".utf8)
        #expect(try store.loadCredential() == nil)

        keychain.item = Data("{\"installationID\":\"not-a-uuid\",\"installationSecret\":\"x\"}".utf8)
        #expect(try store.loadCredential() == nil)

        keychain.item = Data()
        #expect(try store.loadCredential() == nil)
    }

    @Test("A Keychain failure other than 'not found' THROWS — it is never mistaken for absence")
    func load_transientFailure_throws() {
        for status in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed] {
            keychain.copyStatus = status
            #expect(throws: PriceAlertsCredentialStoreError.keychainFailure(status)) {
                try store.loadCredential()
            }
        }
    }

    @Test("A failed update that is not 'not found' throws without adding a second item")
    func save_updateFailure_throws_andDoesNotAdd() {
        keychain.updateStatus = errSecInteractionNotAllowed
        #expect(throws: PriceAlertsCredentialStoreError.keychainFailure(errSecInteractionNotAllowed)) {
            try store.save(credential())
        }
        #expect(keychain.addCalls.isEmpty)
    }

    @Test("A failed add throws")
    func save_addFailure_throws() {
        keychain.addStatus = errSecNotAvailable
        #expect(throws: PriceAlertsCredentialStoreError.keychainFailure(errSecNotAvailable)) {
            try store.save(credential())
        }
    }
}

// MARK: - Lifecycle

struct PriceAlertsInstallationTests {
    private let transport = FakePriceAlertsTransport()
    private let credentials = InMemoryPriceAlertsCredentialStore()
    private let identity = FakeIdentityProvider()

    private func makeManager(store: (any PriceAlertsCredentialStoring)? = nil) -> PriceAlertsInstallationManager {
        PriceAlertsInstallationManager(
            store: store ?? credentials,
            api: PriceAlertsAPIClient(transport: transport),
            identityProvider: identity,
            appVersion: { "2.4.1 (100)" }
        )
    }

    private func rejected401() -> FakePriceAlertsTransport.Scripted {
        .error(status: 401, code: "invalid_installation_credentials")
    }

    // MARK: Creation is lazy

    @Test("Constructing the manager and reading the credential create nothing and call nothing")
    func nothingIsCreatedUntilNeeded() throws {
        let manager = makeManager()

        #expect(try manager.existingCredential() == nil)

        #expect(credentials.saveCount == 0)
        #expect(transport.requests.isEmpty)
        #expect(identity.callCount == 0)
    }

    @Test("ensureReady creates the credential, persists it BEFORE sending it, then bootstraps with it")
    func ensureReady_createsPersistsThenBootstraps() async throws {
        let storedWhenBootstrapArrived = Box<PriceAlertsInstallationCredential?>(nil)
        let credentials = self.credentials
        transport.beforeResponding = { _ in
            await MainActor.run { storedWhenBootstrapArrived.value = credentials.stored }
        }
        let manager = makeManager()

        let session = try await manager.ensureReady()

        #expect(credentials.saveCount == 1)
        #expect(storedWhenBootstrapArrived.value == session.credential)
        #expect(transport.actions == ["bootstrap"])
        let request = try #require(transport.lastRequest("bootstrap"))
        #expect(request.installationID == session.credential.wireInstallationID)
        #expect(request.secret == session.credential.installationSecret)
        #expect(session.credential.isValid)
        #expect(request.json["app_version"] as? String == "2.4.1 (100)")
    }

    @Test("An existing valid credential is reused as it is — never regenerated, never re-saved")
    func ensureReady_reusesExistingCredential() async throws {
        let existing = PriceAlertsInstallationCredential.generate()
        credentials.stored = existing
        let manager = makeManager()

        let session = try await manager.ensureReady()

        #expect(session.credential == existing)
        #expect(credentials.saveCount == 0)
        #expect(transport.lastRequest("bootstrap")?.installationID == existing.wireInstallationID)
    }

    @Test("The server's view of Pro and of the RevenueCat link is reported, and bootstrap carries the identity")
    func ensureReady_reportsServerState_andSendsIdentity() async throws {
        let manager = makeManager()

        let session = try await manager.ensureReady()

        #expect(session.serverProIsActive)
        #expect(session.revenueCatLinked)
        #expect(session.includedRevenueCatIdentity)
        let request = try #require(transport.lastRequest("bootstrap"))
        #expect(request.json["revenuecat_environment"] as? String == "SANDBOX")
        #expect((request.json["revenuecat_app_user_id"] as? String)?.hasPrefix("$RCAnonymousID:") == true)
    }

    @Test("A second ensureReady in the same process makes no network call")
    func ensureReady_secondCall_isFree() async throws {
        let manager = makeManager()
        let first = try await manager.ensureReady()
        let second = try await manager.ensureReady()

        #expect(first == second)
        #expect(transport.count(of: "bootstrap") == 1)
    }

    @Test("Concurrent callers share one in-flight bootstrap — one credential, one request")
    func ensureReady_concurrentCallersShareOneBootstrap() async throws {
        let gate = AsyncGate()
        transport.beforeResponding = { _ in await gate.parkFirstCaller() }
        let manager = makeManager()

        let first = Task { try await manager.ensureReady() }
        #expect(await gate.waitUntilParked())
        let second = Task { try await manager.ensureReady() }
        for _ in 0..<50 { await Task.yield() }
        gate.release()

        let firstSession = try await first.value
        let secondSession = try await second.value
        #expect(firstSession == secondSession)
        #expect(transport.count(of: "bootstrap") == 1)
        #expect(credentials.saveCount == 1)
    }

    @Test("The identity is linked once it is available — and only then is bootstrap repeated")
    func identityUpgrade() async throws {
        identity.identity = nil
        let manager = makeManager()

        let withoutIdentity = try await manager.ensureReady()
        #expect(withoutIdentity.includedRevenueCatIdentity == false)
        #expect(transport.lastRequest("bootstrap")?.json["revenuecat_app_user_id"] == nil)

        // Still nothing to link: no repeat call.
        _ = try await manager.ensureReady()
        #expect(transport.count(of: "bootstrap") == 1)

        // RevenueCat is ready now: bootstrap again, with the pair.
        identity.identity = PriceAlertsRevenueCatIdentity(appUserID: "user-1", environment: .production)
        let linked = try await manager.ensureReady()
        #expect(linked.includedRevenueCatIdentity)
        #expect(transport.count(of: "bootstrap") == 2)
        #expect(transport.lastRequest("bootstrap")?.json["revenuecat_environment"] as? String == "PRODUCTION")

        // And then it is settled.
        _ = try await manager.ensureReady()
        #expect(transport.count(of: "bootstrap") == 2)
    }

    @Test("forceRebootstrap repeats the call (used to refresh the server's RevenueCat link)")
    func forceRebootstrap() async throws {
        let manager = makeManager()
        _ = try await manager.ensureReady()
        _ = try await manager.ensureReady(forceRebootstrap: true)
        #expect(transport.count(of: "bootstrap") == 2)
        #expect(credentials.saveCount == 1)
    }

    // MARK: Missing, corrupt and unreadable local state

    @Test("A stored credential with an invalid secret is replaced, once, in place")
    func corruptStoredCredential_isReplaced() async throws {
        let bad = PriceAlertsInstallationCredential(installationID: UUID(), installationSecret: "way too short")
        credentials.stored = bad
        let manager = makeManager()

        let session = try await manager.ensureReady()

        #expect(session.credential != bad)
        #expect(session.credential.isValid)
        #expect(credentials.saveCount == 1)
        #expect(credentials.stored == session.credential)
    }

    @Test("A corrupt Keychain item is replaced through the real store, updating the one item rather than adding another")
    func corruptKeychainItem_isReplacedInPlace() async throws {
        let keychain = FakeKeychain()
        keychain.item = Data("garbage".utf8)
        let manager = makeManager(store: KeychainPriceAlertsCredentialStore(keychain: keychain))

        let session = try await manager.ensureReady()

        #expect(keychain.addCalls.isEmpty)
        #expect(keychain.updateCount == 1)
        #expect(try KeychainPriceAlertsCredentialStore(keychain: keychain).loadCredential() == session.credential)
    }

    @Test("A Keychain that cannot be READ right now never causes a new identity to be generated")
    func unreadableKeychain_neverForksTheIdentity() async {
        let existing = PriceAlertsInstallationCredential.generate()
        credentials.stored = existing
        credentials.loadError = PriceAlertsCredentialStoreError.keychainFailure(errSecInteractionNotAllowed)
        let manager = makeManager()

        await #expect(throws: PriceAlertsServiceError.credentialStorageUnavailable) {
            try await manager.ensureReady()
        }
        #expect(credentials.saveCount == 0)
        #expect(transport.requests.isEmpty)
        #expect(credentials.stored == existing)
    }

    @Test("A credential that cannot be persisted is never sent anywhere")
    func unpersistableCredential_isNeverBootstrapped() async {
        credentials.saveError = PriceAlertsCredentialStoreError.keychainFailure(errSecNotAvailable)
        let manager = makeManager()

        await #expect(throws: PriceAlertsServiceError.credentialStorageUnavailable) {
            try await manager.ensureReady()
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Reading the existing credential reports a Keychain failure instead of pretending there is none")
    func existingCredential_readFailure() {
        credentials.loadError = PriceAlertsCredentialStoreError.keychainFailure(errSecNotAvailable)
        let manager = makeManager()
        #expect(throws: PriceAlertsServiceError.credentialStorageUnavailable) {
            try manager.existingCredential()
        }
    }

    @Test("The credential is never written to UserDefaults")
    func secret_isNotInUserDefaults() async throws {
        let manager = makeManager()
        let session = try await manager.ensureReady()

        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in defaults {
            #expect("\(key)=\(value)".contains(session.credential.installationSecret) == false)
        }
    }

    // MARK: Server-side invalidation and recovery

    @Test("A 401 on an operation re-bootstraps the SAME credential once and retries the operation once")
    func rejectedOperation_recoversWithSameCredential() async throws {
        let manager = makeManager()
        transport.enqueue("list_alerts", rejected401())
        var attempts = 0

        let alerts: [PriceAlertListing] = try await manager.withInstallation { credential in
            attempts += 1
            return try await PriceAlertsAPIClient(transport: transport).listAlerts(credential: credential)
        }

        #expect(alerts.isEmpty)
        #expect(attempts == 2)
        #expect(transport.actions == ["bootstrap", "list_alerts", "bootstrap", "list_alerts"])
        // The same credential throughout — nothing was regenerated.
        #expect(Set(transport.requests.compactMap(\.installationID)).count == 1)
        #expect(credentials.saveCount == 1)
    }

    @Test("When the server holds this installation id under a different secret, a NEW credential replaces it")
    func serverHoldsDifferentSecret_credentialIsReplaced() async throws {
        let stale = PriceAlertsInstallationCredential.generate()
        credentials.stored = stale
        transport.installations[stale.wireInstallationID] = (secret: "someone-elses-secret-someone-elses-secret", linked: false)
        let manager = makeManager()

        let session = try await manager.ensureReady()

        #expect(session.credential != stale)
        #expect(session.credential.installationID != stale.installationID)
        #expect(credentials.stored == session.credential)
        #expect(credentials.saveCount == 1)
        #expect(transport.count(of: "bootstrap") == 2)
        #expect(transport.requests[0].installationID == stale.wireInstallationID)
        #expect(transport.requests[1].installationID == session.credential.wireInstallationID)
    }

    @Test("Recovery is bounded: a second rejection propagates, with no third attempt")
    func recovery_isBounded() async {
        let manager = makeManager()
        transport.enqueue("list_alerts", rejected401(), rejected401(), rejected401())
        var attempts = 0

        await #expect(throws: PriceAlertsAPIError.api(code: .invalidInstallationCredentials, statusCode: 401)) {
            let _: [PriceAlertListing] = try await manager.withInstallation { credential in
                attempts += 1
                return try await PriceAlertsAPIClient(transport: transport).listAlerts(credential: credential)
            }
        }
        #expect(attempts == 2)
        #expect(transport.count(of: "bootstrap") == 2)
        #expect(transport.count(of: "list_alerts") == 2)
    }

    @Test("If bootstrap itself keeps being refused, one replacement is tried and then the error propagates — no loop")
    func bootstrapRefusedTwice_propagates() async {
        let manager = makeManager()
        transport.enqueue("bootstrap", rejected401(), rejected401(), rejected401())

        await #expect(throws: PriceAlertsAPIError.api(code: .invalidInstallationCredentials, statusCode: 401)) {
            try await manager.ensureReady()
        }
        #expect(transport.count(of: "bootstrap") == 2)
        #expect(credentials.saveCount == 2)
    }

    @Test("A rejected API KEY (401 unauthorized) is not an installation problem: no recovery, no new credential")
    func rejectedAPIKey_doesNotTriggerRecovery() async {
        let manager = makeManager()
        transport.enqueue("list_alerts", .error(status: 401, code: "unauthorized"))

        await #expect(throws: PriceAlertsAPIError.api(code: .unauthorized, statusCode: 401)) {
            let _: [PriceAlertListing] = try await manager.withInstallation { credential in
                try await PriceAlertsAPIClient(transport: transport).listAlerts(credential: credential)
            }
        }
        #expect(transport.count(of: "bootstrap") == 1)
        #expect(transport.count(of: "list_alerts") == 1)
        #expect(credentials.saveCount == 1)
    }

    // MARK: Existing-only access

    @Test("withExistingInstallation with no credential runs nothing and creates nothing")
    func withExisting_withoutCredential() async throws {
        let manager = makeManager()
        var ran = false

        let result: Int? = try await manager.withExistingInstallation { _ in
            ran = true
            return 1
        }

        #expect(result == nil)
        #expect(ran == false)
        #expect(credentials.saveCount == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test("withExistingInstallation uses the stored credential directly — no bootstrap first")
    func withExisting_usesStoredCredential() async throws {
        let existing = PriceAlertsInstallationCredential.generate()
        credentials.stored = existing
        transport.installations[existing.wireInstallationID] = (secret: existing.installationSecret, linked: false)
        let manager = makeManager()

        let alerts: [PriceAlertListing]? = try await manager.withExistingInstallation { credential in
            try await PriceAlertsAPIClient(transport: transport).listAlerts(credential: credential)
        }

        #expect(alerts?.isEmpty == true)
        #expect(transport.actions == ["list_alerts"])
        #expect(credentials.saveCount == 0)
    }

    @Test("If the server has forgotten an existing credential, withExistingInstallation recovers it once")
    func withExisting_recoversForgottenCredential() async throws {
        let existing = PriceAlertsInstallationCredential.generate()
        credentials.stored = existing
        let manager = makeManager()

        // The simulated server has never heard of it: the list is refused, bootstrap re-creates the
        // row, and the retry succeeds — with the credential unchanged.
        let alerts: [PriceAlertListing]? = try await manager.withExistingInstallation { credential in
            try await PriceAlertsAPIClient(transport: transport).listAlerts(credential: credential)
        }

        #expect(alerts?.isEmpty == true)
        #expect(transport.actions == ["list_alerts", "bootstrap", "list_alerts"])
        #expect(credentials.saveCount == 0)
        #expect(credentials.stored == existing)
    }
}
