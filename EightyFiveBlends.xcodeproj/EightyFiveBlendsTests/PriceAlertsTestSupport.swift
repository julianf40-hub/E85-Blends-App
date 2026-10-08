//
//  PriceAlertsTestSupport.swift
//  EightyFiveBlendsTests
//
//  Shared fakes for the Price Alerts client tests (PriceAlertsAPIContractTests,
//  PriceAlertsInstallationTests, PriceAlertsDeviceRegistrationTests, PriceAlertsServiceTests).
//  Nothing here touches the network, the real Keychain, UserNotifications or RevenueCat, and none of
//  it ever sees a production credential.
//
//  FakePriceAlertsTransport has two modes that tests mix freely:
//    - SCRIPTED: `enqueue(_:_:)` pins the exact response (status + body) for the next call to an
//      action — used by the contract tests, which assert on the wire format itself.
//    - SIMULATED: with nothing queued it behaves like price-alerts-api as documented in
//      docs/PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md §1 — bootstrap is an idempotent create that
//      refuses a different secret, every other action authenticates the installation, `set_alert` is
//      an upsert gated on Pro, registering a device retires the installation's previous token, a list
//      returns what was saved — so service-level tests read as behavior, not as scripts.
//

import Foundation
import Security
import Testing
@testable import EightyFiveBlends

// MARK: - Backend response fixtures

/// Bodies shaped exactly as the backend sends them: `numeric(6,3)` columns as strings, timestamps as
/// ISO-8601 with milliseconds, UUIDs lower-case.
enum BackendFixtures {
    /// `nil` becomes JSON `null`, as the backend renders an unset column.
    static func orNull(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    static func data(_ object: Any) -> Data {
        // Fixtures are literals; a failure here is a bug in the test, not in the code under test.
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func bootstrap(installationID: String, pro: Bool = true, linked: Bool = true) -> Data {
        data([
            "status": "ready",
            "client_installation_id": installationID,
            "platform": "ios",
            "pro_is_active": pro,
            "revenuecat_linked": linked,
        ])
    }

    static func registered(deviceID: UUID = UUID()) -> Data {
        data(["status": "registered", "platform": "ios", "device_id": deviceID.uuidString.lowercased()])
    }

    static func unregistered(changed: Bool = true) -> Data {
        data(["status": "unregistered", "changed": changed])
    }

    static func deleted(changed: Bool = true) -> Data {
        data(["status": "deleted", "changed": changed])
    }

    static func status(pro: Bool = true, linked: Bool = true, devices: Int = 1, alerts: Int = 1) -> Data {
        data([
            "platform": "ios",
            "pro_is_active": pro,
            "revenuecat_linked": linked,
            "active_devices": devices,
            "enabled_alerts": alerts,
        ])
    }

    static func error(_ code: String) -> Data {
        data(["error": code])
    }

    /// The core alert object, as `set_alert` returns it. `paymentType: nil` leaves `payment_type` OUT, the
    /// shape of a backend that predates payment types; the simulated server below always sends it.
    static func alertObject(
        id: UUID = UUID(),
        stationID: UUID,
        mode: String = "price_drop",
        threshold: String? = nil,
        minimumChange: String = "0.050",
        cooldownMinutes: Int = 360,
        enabled: Bool = true,
        paymentType: String? = nil
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": id.uuidString.lowercased(),
            "station_id": stationID.uuidString.lowercased(),
            "alert_mode": mode,
            "threshold_price": orNull(threshold),
            "minimum_change": minimumChange,
            "cooldown_minutes": cooldownMinutes,
            "enabled": enabled,
        ]
        if let paymentType {
            object["payment_type"] = paymentType
        }
        return object
    }

    static func saved(_ alert: [String: Any]) -> Data {
        data(["status": "saved", "alert": alert])
    }

    /// One `list_alerts` row: the alert plus the joined station and latest report.
    static func listRow(
        alert: [String: Any],
        stationName: String = "Corner Pump",
        address: String? = "1 Main St",
        city: String? = "Omaha",
        state: String? = "NE",
        lastNotifiedPrice: String? = nil,
        lastNotifiedAt: String? = nil,
        latestPrice: String? = "3.149",
        latestReportedAt: String? = "2026-10-06T08:00:00.000Z",
        latestComparable: (price: String?, reportedAt: String?, paymentType: String?)? = nil
    ) -> [String: Any] {
        var row = alert
        row["station_name"] = stationName
        row["address"] = orNull(address)
        row["city"] = orNull(city)
        row["state"] = orNull(state)
        row["last_notified_price"] = orNull(lastNotifiedPrice)
        row["last_notified_at"] = orNull(lastNotifiedAt)
        row["latest_price"] = orNull(latestPrice)
        row["latest_reported_at"] = orNull(latestReportedAt)
        // Phase 3C: present only when the backend sends them (`nil` models a backend that does not).
        if let latestComparable {
            row["latest_comparable_price"] = orNull(latestComparable.price)
            row["latest_comparable_reported_at"] = orNull(latestComparable.reportedAt)
            row["latest_comparable_payment_type"] = orNull(latestComparable.paymentType)
        }
        return row
    }

    static func list(_ rows: [[String: Any]]) -> Data {
        data(["alerts": rows])
    }
}

// MARK: - Transport

/// Records every request (parsed) and answers from a script or, failing that, a faithful simulation
/// of price-alerts-api.
final class FakePriceAlertsTransport: PriceAlertsAPITransport, @unchecked Sendable {
    struct Recorded {
        let action: String
        let json: [String: Any]
        let body: Data

        var bodyText: String { String(decoding: body, as: UTF8.self) }
        var installationID: String? { json["client_installation_id"] as? String }
        var secret: String? { json["installation_secret"] as? String }
    }

    enum Scripted {
        case response(status: Int, body: Data)
        case failure(Error)

        static func ok(_ body: Data) -> Scripted { .response(status: 200, body: body) }
        static func error(status: Int, code: String) -> Scripted { .response(status: status, body: BackendFixtures.error(code)) }
    }

    struct Device {
        let installationID: String
        let bundleID: String
        let environment: String
        let tokenHex: String
        var enabled: Bool
    }

    private(set) var requests: [Recorded] = []
    private var scripts: [String: [Scripted]] = [:]

    /// Awaited after a request is recorded and before it is answered — lets a test hold a call open.
    var beforeResponding: (@Sendable (Recorded) async -> Void)?

    // Simulated backend state.
    var installations: [String: (secret: String, linked: Bool)] = [:]
    var devices: [Device] = []
    var alerts: [String: [String: [String: Any]]] = [:]   // installation → station → alert object
    var knownStationIDs: Set<String>?                     // nil: every station exists
    /// Whether the simulated server treats a RevenueCat-linked installation as Pro.
    var serverGrantsPro = true
    /// A backend that predates payment types (the one in production until the rollout): it ignores `payment_type` and
    /// `alert_contract_version`, never sends `payment_type` and never sends the comparable-price fields.
    var backendPredatesPaymentTypes = false
    /// Whether the simulated station has a report of the alert's own price type. `false` models a station where, say, only
    /// Credit has ever been reported: a Cash alert lists with NO comparable price (the keys are present, the values null).
    var comparablePricesAvailable = true

    var actions: [String] { requests.map(\.action) }

    func count(of action: String) -> Int {
        requests.filter { $0.action == action }.count
    }

    func lastRequest(_ action: String) -> Recorded? {
        requests.last { $0.action == action }
    }

    func enqueue(_ action: String, _ responses: Scripted...) {
        scripts[action, default: []].append(contentsOf: responses)
    }

    func post(_ body: Data) async throws -> PriceAlertsTransportResponse {
        let json = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        let recorded = Recorded(action: json["action"] as? String ?? "", json: json, body: body)
        requests.append(recorded)
        await beforeResponding?(recorded)

        if var queue = scripts[recorded.action], queue.isEmpty == false {
            let next = queue.removeFirst()
            scripts[recorded.action] = queue
            switch next {
            case .response(let status, let data): return PriceAlertsTransportResponse(statusCode: status, data: data)
            case .failure(let error): throw error
            }
        }
        return simulate(recorded)
    }

    // MARK: Simulation

    private func reply(_ data: Data) -> PriceAlertsTransportResponse {
        PriceAlertsTransportResponse(statusCode: 200, data: data)
    }

    private func reply(_ status: Int, _ data: Data) -> PriceAlertsTransportResponse {
        PriceAlertsTransportResponse(statusCode: status, data: data)
    }

    private func simulate(_ request: Recorded) -> PriceAlertsTransportResponse {
        guard let id = request.installationID, let secret = request.secret else {
            return reply(400, BackendFixtures.error("invalid_installation_credentials"))
        }
        if request.action == "bootstrap" {
            if let existing = installations[id], existing.secret != secret {
                return reply(401, BackendFixtures.error("invalid_installation_credentials"))
            }
            let linked = request.json["revenuecat_app_user_id"] != nil
            installations[id] = (secret, linked || (installations[id]?.linked ?? false))
            let pro = serverGrantsPro && installations[id]?.linked == true
            return reply(BackendFixtures.bootstrap(installationID: id, pro: pro, linked: installations[id]?.linked == true))
        }
        guard let installation = installations[id], installation.secret == secret else {
            return reply(401, BackendFixtures.error("invalid_installation_credentials"))
        }

        switch request.action {
        case "register_device":
            let token = request.json["device_token"] as? String ?? ""
            let bundle = request.json["bundle_id"] as? String ?? ""
            let environment = request.json["apns_environment"] as? String ?? ""
            for index in devices.indices where devices[index].installationID == id
                && devices[index].bundleID == bundle && devices[index].tokenHex != token {
                devices[index].enabled = false
            }
            if let index = devices.firstIndex(where: { $0.bundleID == bundle && $0.environment == environment && $0.tokenHex == token }) {
                devices[index] = Device(installationID: id, bundleID: bundle, environment: environment, tokenHex: token, enabled: true)
            } else {
                devices.append(Device(installationID: id, bundleID: bundle, environment: environment, tokenHex: token, enabled: true))
            }
            return reply(BackendFixtures.registered())

        case "unregister_device":
            let token = request.json["device_token"] as? String ?? ""
            var changed = false
            for index in devices.indices where devices[index].installationID == id && devices[index].tokenHex == token {
                changed = changed || devices[index].enabled
                devices[index].enabled = false
            }
            return reply(BackendFixtures.unregistered(changed: changed))

        case "set_alert":
            guard serverGrantsPro && installation.linked else {
                return reply(403, BackendFixtures.error("pro_required"))
            }
            let station = request.json["station_id"] as? String ?? ""
            if let known = knownStationIDs, known.contains(station) == false {
                return reply(404, BackendFixtures.error("station_not_found"))
            }
            let threshold = (request.json["threshold_price"] as? Double).map { String(format: "%.3f", $0) }
            let existingAlert = alerts[id]?[station]
            // minimum_change follows the sensitivity contract (supabase/functions/price-alerts-api/alert-input.ts): a NEW
            // alert stores the value sent (0.05 when none); an EXISTING alert's value is replaced only when the request
            // declares alert_contract_version >= 2 and names a value, or names a value that is not the fixed legacy 0.05.
            // (The contract itself is proven against the real function by the Deno scenarios; this keeps the simulation
            // faithful so a service-level test reads like the real thing.) A backend that predates payment types takes
            // the request at face value: it always stores what it was sent.
            let namedMinimum = request.json["minimum_change"] as? Double
            let sentMinimum = namedMinimum ?? 0.05
            let declaredVersion = request.json["alert_contract_version"] as? Int ?? 1
            let replaces: Bool
            if backendPredatesPaymentTypes || existingAlert == nil {
                replaces = true
            } else if namedMinimum == nil {
                replaces = false
            } else {
                replaces = declaredVersion >= 2 || Int((sentMinimum * 1000).rounded()) != 50
            }
            let minimum = replaces
                ? String(format: "%.3f", sentMinimum)
                : (existingAlert?["minimum_change"] as? String ?? String(format: "%.3f", sentMinimum))
            let cooldown = request.json["cooldown_minutes"] as? Int ?? 360
            // payment_type: cash | credit | absent. Anything else is refused, as the real function does; an
            // absent field keeps the alert's current one, or stores `unknown` for a new alert.
            var payment = (existingAlert?["payment_type"] as? String) ?? "unknown"
            if backendPredatesPaymentTypes == false, let requested = request.json["payment_type"], (requested is NSNull) == false {
                guard let text = requested as? String, text == "cash" || text == "credit" else {
                    return reply(400, BackendFixtures.error("invalid_payment_type"))
                }
                payment = text
            }
            let alert = BackendFixtures.alertObject(
                id: (existingAlert?["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                stationID: UUID(uuidString: station) ?? UUID(),
                mode: request.json["alert_mode"] as? String ?? "price_drop",
                threshold: threshold,
                minimumChange: minimum,
                cooldownMinutes: cooldown,
                paymentType: backendPredatesPaymentTypes ? nil : payment
            )
            alerts[id, default: [:]][station] = alert
            return reply(BackendFixtures.saved(alert))

        case "delete_alert":
            let station = request.json["station_id"] as? String ?? ""
            let removed = alerts[id]?.removeValue(forKey: station) != nil
            return reply(BackendFixtures.deleted(changed: removed))

        case "list_alerts":
            // An alert that watches Cash or Credit comes back with the newest report of its own price type
            // (the fake's latest report is always one); a legacy alert comes back without the comparable
            // fields, the shape every Phase 3B test was written against.
            let rows = (alerts[id] ?? [:]).values
                .map { alert -> [String: Any] in
                    let payment = alert["payment_type"] as? String ?? "unknown"
                    let comparable: (price: String?, reportedAt: String?, paymentType: String?)?
                    if payment == "unknown" {
                        comparable = nil
                    } else if comparablePricesAvailable {
                        comparable = (price: "3.149", reportedAt: "2026-10-06T08:00:00.000Z", paymentType: payment)
                    } else {
                        comparable = (price: nil, reportedAt: nil, paymentType: nil)
                    }
                    return BackendFixtures.listRow(alert: alert, latestComparable: comparable)
                }
                .sorted { ($0["station_id"] as? String ?? "") < ($1["station_id"] as? String ?? "") }
            return reply(BackendFixtures.list(rows))

        case "status":
            let active = devices.filter { $0.installationID == id && $0.enabled }.count
            return reply(BackendFixtures.status(pro: serverGrantsPro && installation.linked, linked: installation.linked, devices: active, alerts: alerts[id]?.count ?? 0))

        default:
            return reply(400, BackendFixtures.error("unknown_action"))
        }
    }
}

// MARK: - Credential store

final class InMemoryPriceAlertsCredentialStore: PriceAlertsCredentialStoring, @unchecked Sendable {
    var stored: PriceAlertsInstallationCredential?
    var loadError: Error?
    var saveError: Error?
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var savedHistory: [PriceAlertsInstallationCredential] = []

    func loadCredential() throws -> PriceAlertsInstallationCredential? {
        loadCount += 1
        if let loadError { throw loadError }
        return stored
    }

    func save(_ credential: PriceAlertsInstallationCredential) throws {
        saveCount += 1
        if let saveError { throw saveError }
        stored = credential
        savedHistory.append(credential)
    }
}

// MARK: - Keychain

/// An in-memory single-item Keychain that RECORDS every query, so the storage rules can be asserted
/// on the exact attributes handed to the Security framework.
final class FakeKeychain: KeychainItemAccessing, @unchecked Sendable {
    enum Call {
        case copy([String: Any])
        case update(query: [String: Any], attributes: [String: Any])
        case add([String: Any])
    }

    private(set) var calls: [Call] = []
    var item: Data?
    var copyStatus: OSStatus?
    var updateStatus: OSStatus?
    var addStatus: OSStatus?

    var addCalls: [[String: Any]] {
        calls.compactMap { if case .add(let attributes) = $0 { return attributes } else { return nil } }
    }

    var updateCount: Int {
        calls.filter { if case .update = $0 { return true } else { return false } }.count
    }

    var allDictionaries: [[String: Any]] {
        calls.flatMap { call -> [[String: Any]] in
            switch call {
            case .copy(let query): return [query]
            case .update(let query, let attributes): return [query, attributes]
            case .add(let attributes): return [attributes]
            }
        }
    }

    func copyMatching(_ query: [String: Any]) -> KeychainReadResult {
        calls.append(.copy(query))
        if let copyStatus { return KeychainReadResult(status: copyStatus, data: nil) }
        guard let item else { return KeychainReadResult(status: errSecItemNotFound, data: nil) }
        return KeychainReadResult(status: errSecSuccess, data: item)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        calls.append(.update(query: query, attributes: attributes))
        if let updateStatus { return updateStatus }
        guard item != nil else { return errSecItemNotFound }
        item = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        calls.append(.add(attributes))
        if let addStatus { return addStatus }
        item = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
}

// MARK: - Push state

/// A scriptable stand-in for PushRegistrationService, as the registrar sees it.
final class FakePushState: PriceAlertsPushStateProviding {
    var pushState: PushRegistrationState
    private(set) var optInCount = 0
    private(set) var refreshCount = 0
    /// Runs inside `requestAuthorizationAndRegister()` — e.g. to move to `.registered` like the OS would.
    var onOptIn: (() -> Void)?
    var onRefresh: (() -> Void)?

    init(_ state: PushRegistrationState = .notRequested) {
        pushState = state
    }

    func requestAuthorizationAndRegister() async {
        optInCount += 1
        onOptIn?()
    }

    func refreshRegistrationIfAuthorized() async {
        refreshCount += 1
        onRefresh?()
    }

    static func token(_ byte: UInt8) -> PushDeviceToken {
        // Always valid: 32 bytes.
        PushDeviceToken(deviceToken: Data(repeating: byte, count: 32))!
    }
}

// MARK: - Small fakes

final class FakeMetadataProvider: PushDeviceRegistrationMetadataProviding, @unchecked Sendable {
    var metadata: PushDeviceRegistrationMetadata?

    init(bundle: String = "com.example.app", environment: APNsEnvironment = .production) {
        metadata = PushDeviceRegistrationMetadata(bundleIdentifier: bundle, apnsEnvironment: environment)
    }

    func currentMetadata() -> PushDeviceRegistrationMetadata? {
        metadata
    }
}

final class InMemoryRegistrationRecordStore: PriceAlertsDeviceRegistrationRecordStoring, @unchecked Sendable {
    var record: PriceAlertsDeviceRegistrationRecord?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func load() -> PriceAlertsDeviceRegistrationRecord? { record }

    func save(_ record: PriceAlertsDeviceRegistrationRecord) {
        saveCount += 1
        self.record = record
    }

    func clear() {
        clearCount += 1
        record = nil
    }
}

final class FakeEntitlement: PriceAlertsEntitlementProviding, @unchecked Sendable {
    var entitlement: PriceAlertsEntitlement

    init(_ entitlement: PriceAlertsEntitlement = .active) {
        self.entitlement = entitlement
    }
}

final class FakeIdentityProvider: PriceAlertsRevenueCatIdentityProviding, @unchecked Sendable {
    var identity: PriceAlertsRevenueCatIdentity?
    private(set) var callCount = 0

    init(_ identity: PriceAlertsRevenueCatIdentity? = PriceAlertsRevenueCatIdentity(
        appUserID: "$RCAnonymousID:0123456789abcdef0123456789abcdef", environment: .sandbox
    )) {
        self.identity = identity
    }

    func currentIdentity() async -> PriceAlertsRevenueCatIdentity? {
        callCount += 1
        return identity
    }
}

/// A clock a `@Sendable` closure can read while the test moves it.
nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Counts `sleep` calls and optionally runs something on each, on the main actor.
nonisolated final class SleepProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var onSleep: (@MainActor @Sendable (Int) -> Void)?

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func sleep(_: Duration) async {
        let number = recordCall()
        if let onSleep {
            await MainActor.run { onSleep(number) }
        }
    }

    // Locking lives in a synchronous helper: NSLock must not be taken directly inside async code.
    private func recordCall() -> Int {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls
    }
}

// MARK: - The whole stack

/// A fully wired PriceAlertsService over fakes. Constructing one performs no I/O at all — which is
/// itself asserted (`noLaunchTimeSideEffects`).
@MainActor
struct PriceAlertsStack {
    let transport = FakePriceAlertsTransport()
    let credentials = InMemoryPriceAlertsCredentialStore()
    let identity = FakeIdentityProvider()
    let push: FakePushState
    let metadata = FakeMetadataProvider()
    let records = InMemoryRegistrationRecordStore()
    let entitlement: FakeEntitlement
    let clock = TestClock()
    let sleeper = SleepProbe()
    let service: PriceAlertsService

    init(push: PushRegistrationState = .notRequested, entitlement: PriceAlertsEntitlement = .active) {
        self.push = FakePushState(push)
        self.entitlement = FakeEntitlement(entitlement)
        let clock = self.clock
        let sleeper = self.sleeper
        service = PriceAlertsService.make(
            transport: self.transport,
            credentialStore: self.credentials,
            revenueCatIdentity: self.identity,
            push: self.push,
            metadata: self.metadata,
            registrationRecords: self.records,
            entitlement: self.entitlement,
            appVersion: { "2.4.1 (100)" },
            now: { clock.now },
            sleep: { await sleeper.sleep($0) }
        )
    }

    /// A station UUID, as a saved station would carry.
    static func stationID(_ seed: UInt8 = 1) -> UUID {
        UUID(uuid: (0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x4A, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, seed))
    }

    /// Everything the stack could have DONE, summed: requests sent, credentials saved, identities
    /// looked up, permission prompts and OS registrations asked for, records written. Reading the
    /// credential store is deliberately not counted — finding out that no installation exists is a
    /// read, not an effect; tests that must prove "no Keychain access at all" assert
    /// `credentials.loadCount == 0` themselves.
    var totalSideEffects: Int {
        transport.requests.count + credentials.saveCount + identity.callCount
            + push.optInCount + push.refreshCount + records.saveCount + records.clearCount + sleeper.count
    }
}

// MARK: - Deterministic concurrency

/// Holds the FIRST caller of `parkFirstCaller()` until the test releases it, so one call stays in
/// flight while a second arrives — deterministically, with no reliance on how the scheduler orders
/// yielding tasks. Every later caller returns immediately, so a call that wrongly does NOT stand
/// aside for the parked one fails an expectation instead of hanging the suite.
@MainActor
final class AsyncGate {
    private var parked: CheckedContinuation<Void, Never>?
    private var hasParked = false

    var isParked: Bool { parked != nil }

    func parkFirstCaller() async {
        guard hasParked == false else { return }
        hasParked = true
        await withCheckedContinuation { parked = $0 }
    }

    func release() {
        parked?.resume()
        parked = nil
    }

    /// Suspends the test until a call is parked. Bounded, so a call that never arrives fails the test
    /// rather than hanging it.
    func waitUntilParked() async -> Bool {
        for _ in 0..<10_000 {
            if isParked { return true }
            await Task.yield()
        }
        return isParked
    }
}

/// A main-actor-isolated mutable cell, for recording values from inside `@Sendable` hooks.
@MainActor
final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
