//
//  PriceAlertsDeviceRegistration.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). Keeps price-alerts-api's record of
//  THIS device (its APNs token, bundle identifier and APNs environment) in step with what the OS
//  last told PushRegistrationService. The token capture itself is Phase 2 (PushRegistrationService)
//  and is not replaced: this only READS its state — and, on an explicit opt-in, asks it to prompt
//  and register — and never writes to it, so a failed backend call can never cost the app a good
//  local token.
//
//  NOTHING HERE RUNS AT LAUNCH. Constructing a registrar does nothing. Registration happens only when
//  a caller asks: `enable()` (the user opting in to Price Alerts notifications), `refresh(...)` (a
//  returning user on a Price Alerts screen), or `refreshIfPreviouslyRegistered()` (safe to call from
//  app-level code such as scenePhase handling — it does nothing for any install that has never
//  registered).
//
//  IDEMPOTENT, AND ONLY AS CHATTY AS NEEDED. The server's register_device is an idempotent upsert,
//  but the client avoids calling it needlessly. After a successful registration it persists a
//  FINGERPRINT — SHA-256 over (installation id, bundle id, APNs environment, token) — never the token
//  itself (PushRegistrationService deliberately never persists the token: a restored backup must not
//  resurrect another device's). The next reconcile compares:
//      same fingerprint, registered within `refreshInterval`  → no network call
//      anything differs (a rotated token, a new installation, another environment or bundle) → register
//      same fingerprint but older than `refreshInterval`      → register again, which also revives a
//                                                               device the worker invalidated
//  Registering a new token makes the server retire the old one, so rotation needs nothing more.
//
//  FAILURE IS CONTAINED. A failed call leaves the previous fingerprint and the push token untouched,
//  and starts a bounded backoff (30 s, 2 min, 10 min, then 30 min between automatic attempts; an
//  explicit user action bypasses the wait but is still exactly one attempt). Nothing retries by
//  itself, so there is no loop. Concurrent callers share one in-flight attempt.
//
//  DENIED / NO TOKEN / UNKNOWN ENVIRONMENT never reach the network. A user who denied notifications
//  is not registered; a simulator or a build without the Push Notifications capability has no token;
//  and an APNs environment that cannot be established is never guessed (see
//  PushDeviceRegistrationMetadata.swift for why a wrong one is worse than none).
//

import CryptoKit
import Foundation

// MARK: - Seams

/// The slice of PushRegistrationService this feature uses. PushRegistrationService conforms
/// (PushRegistrationService+PriceAlerts.swift); the tests substitute a fake. (Implicitly MainActor
/// like every declaration in this module, and deliberately not `Sendable`: a retroactive `Sendable`
/// requirement cannot be satisfied by a conformance declared outside PushRegistrationService's file.)
protocol PriceAlertsPushStateProviding {
    var pushState: PushRegistrationState { get }
    /// An explicit opt-in: prompts only if the user was never asked, then registers with APNs.
    func requestAuthorizationAndRegister() async
    /// A returning, already-opted-in user: asks the OS for the current token. Never prompts.
    func refreshRegistrationIfAuthorized() async
}

/// What was last successfully registered, as a one-way fingerprint.
nonisolated struct PriceAlertsDeviceRegistrationRecord: Codable, Equatable, Sendable {
    let fingerprint: String
    let registeredAt: Date
}

protocol PriceAlertsDeviceRegistrationRecordStoring: Sendable {
    func load() -> PriceAlertsDeviceRegistrationRecord?
    func save(_ record: PriceAlertsDeviceRegistrationRecord)
    func clear()
}

/// UserDefaults is the right home: the record is a one-way hash of non-secret facts plus a date, it
/// must not outlive this app's data, and losing it only costs one idempotent re-registration.
struct UserDefaultsPriceAlertsDeviceRegistrationRecordStore: PriceAlertsDeviceRegistrationRecordStoring {
    static let key = "com.e85blends.pricealerts.deviceRegistration.v1"

    var defaults: UserDefaults = .standard

    func load() -> PriceAlertsDeviceRegistrationRecord? {
        // Unreadable or malformed data is simply "no record".
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PriceAlertsDeviceRegistrationRecord.self, from: data)
    }

    func save(_ record: PriceAlertsDeviceRegistrationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

// MARK: - Outcomes

nonisolated enum PriceAlertsReconcileTrigger: Equatable, Sendable {
    /// A person asked (opt-in, "try again"): ignores the backoff wait, still makes one attempt.
    case userInitiated
    /// App-level housekeeping: honours the backoff wait.
    case automatic
}

nonisolated enum PriceAlertsDeviceRegistrationSkipReason: Equatable, Sendable {
    /// The user denied notifications. Nothing is registered and nothing will prompt again.
    case notificationsDenied
    /// No APNs token to register: permission not requested yet, still awaiting the OS, or the OS
    /// failed (a simulator, or a build without the Push Notifications capability).
    case noDeviceToken
    /// The APNs environment (or bundle identifier) could not be established; never guessed.
    case pushEnvironmentUnresolved
    /// `refreshIfPreviouslyRegistered` on an install that has never registered.
    case notOptedIn
    /// A new installation would be needed and the user is not Pro.
    case proRequired
    /// A new installation would be needed and RevenueCat has not answered yet.
    case entitlementUnresolved
    /// An automatic attempt failed recently; try again no sooner than this.
    case backingOff(until: Date)
}

nonisolated enum PriceAlertsDeviceRegistrationOutcome: Equatable, Sendable {
    /// The backend call was made and succeeded.
    case registered
    /// The backend already holds exactly this registration (per the local fingerprint); no call made.
    case alreadyRegistered
    case skipped(PriceAlertsDeviceRegistrationSkipReason)
    /// The attempt failed. The push token and the previous fingerprint are untouched.
    case failed(PriceAlertsServiceError)
}

// MARK: - Backoff

nonisolated struct PriceAlertsRetryBackoff: Equatable, Sendable {
    /// The wait after the 1st, 2nd, 3rd and every later consecutive failure.
    static let delays: [TimeInterval] = [30, 120, 600, 1800]

    private(set) var consecutiveFailures = 0
    private(set) var retryNotBefore: Date?

    mutating func recordFailure(at now: Date) {
        consecutiveFailures += 1
        let delay = Self.delays[min(consecutiveFailures, Self.delays.count) - 1]
        retryNotBefore = now.addingTimeInterval(delay)
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        retryNotBefore = nil
    }

    /// When an automatic attempt may next be made, or `nil` if one may be made now.
    func blockedUntil(now: Date) -> Date? {
        guard let retryNotBefore, retryNotBefore > now else { return nil }
        return retryNotBefore
    }
}

// MARK: - Registrar

@MainActor
final class PriceAlertsDeviceRegistrar {
    /// A registration older than this is repeated even if nothing changed — cheap, idempotent, and
    /// the only way to revive a device the worker invalidated for the same token.
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// How long an opt-in or refresh waits for the OS to deliver a token it was just asked for.
    static let tokenPollInterval: Duration = .milliseconds(250)
    static let maximumTokenPolls = 40

    private let api: any PriceAlertsAPIClienting
    private let installation: PriceAlertsInstallationManager
    private let push: any PriceAlertsPushStateProviding
    private let metadataProvider: any PushDeviceRegistrationMetadataProviding
    private let records: any PriceAlertsDeviceRegistrationRecordStoring
    private let entitlementProvider: any PriceAlertsEntitlementProviding
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async -> Void

    private var backoff = PriceAlertsRetryBackoff()
    private var inFlight: Task<PriceAlertsDeviceRegistrationOutcome, Never>?

    init(
        api: any PriceAlertsAPIClienting,
        installation: PriceAlertsInstallationManager,
        push: any PriceAlertsPushStateProviding,
        metadataProvider: any PushDeviceRegistrationMetadataProviding,
        records: any PriceAlertsDeviceRegistrationRecordStoring,
        entitlementProvider: any PriceAlertsEntitlementProviding,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.api = api
        self.installation = installation
        self.push = push
        self.metadataProvider = metadataProvider
        self.records = records
        self.entitlementProvider = entitlementProvider
        self.now = now
        self.sleep = sleep
    }

    // MARK: Entry points

    /// The user is opting in to Price Alerts notifications. Prompts for permission only if they were
    /// never asked, waits (boundedly) for the OS to deliver a token, then registers it. A user who
    /// could not proceed anyway — Free, with no installation yet — is neither prompted nor registered.
    func enable() async -> PriceAlertsDeviceRegistrationOutcome {
        do {
            if let blocked = try installationCreationBlock() {
                return .skipped(blocked)
            }
        } catch {
            return .failed(PriceAlertsServiceError.from(error))
        }
        await push.requestAuthorizationAndRegister()
        await waitForPendingToken()
        return await reconcile(trigger: .userInitiated)
    }

    /// A returning user: asks the OS for the current token (never prompting) and brings the backend
    /// up to date.
    func refresh(trigger: PriceAlertsReconcileTrigger = .userInitiated) async -> PriceAlertsDeviceRegistrationOutcome {
        await push.refreshRegistrationIfAuthorized()
        await waitForPendingToken()
        return await reconcile(trigger: trigger)
    }

    /// For app-level callers (e.g. when the app becomes active): does nothing at all — no OS call, no
    /// network call — unless this install has registered before.
    func refreshIfPreviouslyRegistered() async -> PriceAlertsDeviceRegistrationOutcome {
        guard records.load() != nil else { return .skipped(.notOptedIn) }
        return await refresh(trigger: .automatic)
    }

    /// Compares what the OS currently holds with what the backend was last given and registers only
    /// if they differ. Concurrent callers share one attempt.
    func reconcile(trigger: PriceAlertsReconcileTrigger) async -> PriceAlertsDeviceRegistrationOutcome {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.performReconcile(trigger: trigger) }
        inFlight = task
        defer { inFlight = nil }
        return await task.value
    }

    /// Turns delivery off for this device's token: asks the backend to retire it and forgets the local
    /// fingerprint. Not automatic anywhere. Returns whether the backend changed a row (`false` when
    /// there was nothing to unregister).
    ///
    /// After a relaunch the OS has not handed the token back yet and PushRegistrationService
    /// deliberately never persisted it, so if none is held the OS is asked for it first (never
    /// prompting) — otherwise "turn off" would silently do nothing.
    @discardableResult
    func unregister() async throws -> Bool {
        if case .registered = push.pushState {} else {
            await push.refreshRegistrationIfAuthorized()
            await waitForPendingToken()
        }
        guard case .registered(let token) = push.pushState else { return false }
        do {
            let changed = try await installation.withExistingInstallation { credential in
                try await api.unregisterDevice(credential: credential, token: token)
            }
            records.clear()
            return changed ?? false
        } catch {
            throw PriceAlertsServiceError.from(error)
        }
    }

    // MARK: Reconciling

    private func performReconcile(trigger: PriceAlertsReconcileTrigger) async -> PriceAlertsDeviceRegistrationOutcome {
        let token: PushDeviceToken
        switch push.pushState {
        case .denied:
            return .skipped(.notificationsDenied)
        case .registered(let current):
            token = current
        case .notRequested, .authorizedAwaitingToken, .failed:
            return .skipped(.noDeviceToken)
        }

        guard let metadata = metadataProvider.currentMetadata() else {
            return .skipped(.pushEnvironmentUnresolved)
        }

        let attemptTime = now()
        if trigger == .automatic, let until = backoff.blockedUntil(now: attemptTime) {
            return .skipped(.backingOff(until: until))
        }

        do {
            if let existing = try installation.existingCredential() {
                let fingerprint = PriceAlertsDeviceFingerprint.make(installationID: existing.installationID, token: token, metadata: metadata)
                if isCurrent(fingerprint, at: attemptTime) {
                    return .alreadyRegistered
                }
            } else if let blocked = try installationCreationBlock() {
                return .skipped(blocked)
            }

            let registeredFingerprint = try await installation.withInstallation { credential in
                _ = try await api.registerDevice(credential: credential, token: token, metadata: metadata)
                // Computed from the credential that actually succeeded: recovery may have replaced it.
                return PriceAlertsDeviceFingerprint.make(installationID: credential.installationID, token: token, metadata: metadata)
            }
            records.save(PriceAlertsDeviceRegistrationRecord(fingerprint: registeredFingerprint, registeredAt: now()))
            backoff.recordSuccess()
            return .registered
        } catch {
            let failure = PriceAlertsServiceError.from(error)
            if failure != .api(.network(.cancelled)) {
                backoff.recordFailure(at: now())
            }
            return .failed(failure)
        }
    }

    private func isCurrent(_ fingerprint: String, at time: Date) -> Bool {
        guard let record = records.load(), record.fingerprint == fingerprint else { return false }
        let age = time.timeIntervalSince(record.registeredAt)
        // A record from the future (a clock that moved back) is not trusted.
        return age >= 0 && age < Self.refreshInterval
    }

    /// Why registering would have to create a new installation and may not: no credential exists yet
    /// and the user is not (known to be) Pro.
    private func installationCreationBlock() throws -> PriceAlertsDeviceRegistrationSkipReason? {
        guard try installation.existingCredential() == nil else { return nil }
        switch entitlementProvider.entitlement {
        case .active: return nil
        case .inactive: return .proRequired
        case .unresolved: return .entitlementUnresolved
        }
    }

    private func waitForPendingToken() async {
        var polls = 0
        while push.pushState == .authorizedAwaitingToken, polls < Self.maximumTokenPolls {
            await sleep(Self.tokenPollInterval)
            polls += 1
        }
    }
}

// MARK: - Fingerprint

nonisolated enum PriceAlertsDeviceFingerprint {
    private static let hexDigits = Array("0123456789abcdef")

    /// One-way: SHA-256 over everything whose change must trigger a fresh registration. The token
    /// cannot be recovered from it.
    static func make(
        installationID: UUID,
        token: PushDeviceToken,
        metadata: PushDeviceRegistrationMetadata
    ) -> String {
        let material = [
            "v1",
            installationID.uuidString.lowercased(),
            metadata.bundleIdentifier,
            metadata.apnsEnvironment.rawValue,
            token.hexString,
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).reduce(into: "") { result, byte in
            result.append(hexDigits[Int(byte >> 4)])
            result.append(hexDigits[Int(byte & 0x0F)])
        }
    }
}
