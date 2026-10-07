//
//  PriceAlertsInstallation.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). The lifecycle of this install's
//  identity at price-alerts-api: a locally generated credential (PriceAlertsCredentialStore.swift)
//  and the server-side installation row that `bootstrap` creates for it.
//
//  LAZY. Nothing here runs at launch and nothing exists until Price Alerts actually needs it:
//    - `existingCredential()` only ever READS. A user who never used Price Alerts has none, and
//      reading alerts or deleting one for such a user needs no installation at all.
//    - `ensureReady()` — called by operations that need the server to know this install (saving an
//      alert, registering a device) — creates the credential if absent, persists it, and bootstraps.
//
//  THE RULES (each covered by PriceAlertsInstallationTests):
//    - PERSIST BEFORE USE. A new credential is saved to the Keychain before it is sent anywhere. If it
//      cannot be saved, nothing is bootstrapped: a secret that never durably persisted would be
//      regenerated on the next launch, orphaning whatever the server created for it.
//    - NEVER FORK ON A TRANSIENT FAILURE. If the Keychain cannot be READ right now (as opposed to
//      "not found"), this throws instead of generating a replacement on top of a credential that is
//      merely unreadable this instant.
//    - A MISSING OR CORRUPT STORED CREDENTIAL IS REPLACED, once, in place (the store updates the item
//      rather than adding a second one).
//    - ONE BOOTSTRAP PER PROCESS, SHARED. Concurrent callers join a single in-flight bootstrap. The
//      call is idempotent on the server, so repeating it on the next launch is harmless and also
//      re-links the RevenueCat identity (which is how the SERVER learns the user is Pro).
//    - SERVER-SIDE INVALIDATION IS HANDLED, BOUNDEDLY. A `401 invalid_installation_credentials` from
//      any call means the server no longer accepts this credential. Recovery is: bootstrap the SAME
//      credential again (cures a server that merely forgot the row); if bootstrap itself is refused,
//      the server holds a different secret for this id and no credential this device can produce
//      will ever match, so a NEW credential is generated, saved and bootstrapped. The failed
//      operation is then retried once. Nothing loops: at most two bootstraps and two attempts of the
//      operation per call. (An installation orphaned this way keeps its alerts on the server; the
//      backend offers no way to reclaim or delete it.)
//
//  The RevenueCat identity is read fresh for each bootstrap and never stored here. 85Blends has no
//  accounts (see RevenueCatSubscriptionService's "ANONYMOUS ONLY" header), so the identity does not
//  change within an install; if the first bootstrap ran before RevenueCat was ready it is repeated
//  once an identity is available, and only then.
//

import Foundation

/// Who RevenueCat says this install is, or `nil` while that cannot be established (the SDK is not
/// configured yet, or the verified App Store environment is not known). A `nil` is never replaced by
/// a placeholder: the bootstrap simply goes without, and is repeated later.
protocol PriceAlertsRevenueCatIdentityProviding: Sendable {
    func currentIdentity() async -> PriceAlertsRevenueCatIdentity?
}

/// The `app_version` string `bootstrap` reports, e.g. "2.4.1 (100)". Cosmetic server-side metadata;
/// PriceAlertsWireRequest drops it if the backend would reject it.
nonisolated enum PriceAlertsAppVersion {
    static func format(shortVersion: String?, build: String?) -> String? {
        let version = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let build = build?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        case let (nil, build?): return "(\(build))"
        case (nil, nil): return nil
        }
    }

    static func current(bundle: Bundle = .main) -> String? {
        format(
            shortVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: bundle.infoDictionary?["CFBundleVersion"] as? String
        )
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// A credential the server has accepted for this process, and what it said about it.
nonisolated struct PriceAlertsInstallationSession: Equatable, Sendable {
    let credential: PriceAlertsInstallationCredential
    /// The SERVER's view of Pro when this session was bootstrapped.
    let serverProIsActive: Bool
    let revenueCatLinked: Bool
    /// Whether the bootstrap carried a RevenueCat identity. Without one the server cannot know the
    /// user is Pro, so a session without it is upgraded as soon as an identity is available.
    let includedRevenueCatIdentity: Bool
}

@MainActor
final class PriceAlertsInstallationManager {
    private let store: any PriceAlertsCredentialStoring
    private let api: any PriceAlertsAPIClienting
    private let identityProvider: any PriceAlertsRevenueCatIdentityProviding
    private let appVersion: @Sendable () -> String?

    private var session: PriceAlertsInstallationSession?
    private var inFlight: Task<PriceAlertsInstallationSession, Error>?

    init(
        store: any PriceAlertsCredentialStoring,
        api: any PriceAlertsAPIClienting,
        identityProvider: any PriceAlertsRevenueCatIdentityProviding,
        appVersion: @escaping @Sendable () -> String? = { nil }
    ) {
        self.store = store
        self.api = api
        self.identityProvider = identityProvider
        self.appVersion = appVersion
    }

    // MARK: - Reading

    /// The stored credential, or `nil` if this install has never used Price Alerts (or the stored
    /// bytes are unusable). Never creates anything and never touches the network.
    /// - Throws: `credentialStorageUnavailable` if the Keychain cannot be read right now.
    func existingCredential() throws -> PriceAlertsInstallationCredential? {
        do {
            guard let credential = try store.loadCredential(), credential.isValid else { return nil }
            return credential
        } catch {
            throw PriceAlertsServiceError.credentialStorageUnavailable
        }
    }

    // MARK: - Ensuring

    /// A credential the server has accepted, creating and bootstrapping one only if this process has
    /// not already. Concurrent callers share one bootstrap.
    /// - Parameter forceRebootstrap: bootstrap again even if this process already did (used to
    ///   refresh the server's RevenueCat link, and by recovery).
    func ensureReady(forceRebootstrap: Bool = false) async throws -> PriceAlertsInstallationSession {
        if let inFlight {
            return try await inFlight.value
        }
        if forceRebootstrap == false, let current = session, current.includedRevenueCatIdentity {
            return current
        }
        let previous = forceRebootstrap ? nil : session
        let task = Task { try await self.bootstrap(replacing: previous) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func bootstrap(replacing previous: PriceAlertsInstallationSession?) async throws -> PriceAlertsInstallationSession {
        let identity = await identityProvider.currentIdentity()
        // The previous session lacked an identity and there is still none: nothing new to link, so
        // keep the session that works instead of repeating an identical call.
        if let previous, identity == nil {
            return previous
        }

        var credential = try loadOrCreateCredential()
        let version = appVersion()
        let result: PriceAlertsBootstrapResult
        do {
            result = try await api.bootstrap(credential: credential, revenueCat: identity, appVersion: version)
        } catch let error as PriceAlertsAPIError where error.rejectsInstallationCredentials {
            // The server holds this installation id under a different secret, so this device can
            // never authenticate it again. Replace the credential durably, then bootstrap that.
            credential = try persistNewCredential()
            result = try await api.bootstrap(credential: credential, revenueCat: identity, appVersion: version)
        }

        let ready = PriceAlertsInstallationSession(
            credential: credential,
            serverProIsActive: result.proIsActive,
            revenueCatLinked: result.revenueCatLinked,
            includedRevenueCatIdentity: identity?.isAcceptableToBackend == true
        )
        session = ready
        return ready
    }

    // MARK: - Running operations

    /// Runs `operation` with a server-accepted credential (creating the installation if needed). If
    /// the server rejects that credential, recovers once and runs the operation once more; a second
    /// rejection propagates.
    func withInstallation<T>(
        _ operation: (PriceAlertsInstallationCredential) async throws -> T
    ) async throws -> T {
        let ready = try await ensureReady()
        do {
            return try await operation(ready.credential)
        } catch let error as PriceAlertsAPIError where error.rejectsInstallationCredentials {
            let recovered = try await recover(from: ready.credential)
            return try await operation(recovered.credential)
        }
    }

    /// Runs `operation` with the stored credential ONLY if one exists — it never creates an
    /// installation and does not bootstrap first. Returns `nil` (without running anything) when this
    /// install has no credential. Recovery on rejection is as for `withInstallation`.
    func withExistingInstallation<T>(
        _ operation: (PriceAlertsInstallationCredential) async throws -> T
    ) async throws -> T? {
        guard let credential = try existingCredential() else { return nil }
        do {
            return try await operation(credential)
        } catch let error as PriceAlertsAPIError where error.rejectsInstallationCredentials {
            let recovered = try await recover(from: credential)
            return try await operation(recovered.credential)
        }
    }

    /// The server rejected `rejected`. Forget the session built on it and bootstrap again, which
    /// either re-creates the forgotten row or, if the id is held under another secret, replaces the
    /// credential (see this file's header).
    func recover(from rejected: PriceAlertsInstallationCredential) async throws -> PriceAlertsInstallationSession {
        if session?.credential == rejected {
            session = nil
        }
        return try await ensureReady(forceRebootstrap: true)
    }

    // MARK: - Credential persistence

    private func loadOrCreateCredential() throws -> PriceAlertsInstallationCredential {
        if let existing = try existingCredential() {
            return existing
        }
        return try persistNewCredential()
    }

    private func persistNewCredential() throws -> PriceAlertsInstallationCredential {
        let generated = PriceAlertsInstallationCredential.generate()
        do {
            try store.save(generated)
        } catch {
            throw PriceAlertsServiceError.credentialStorageUnavailable
        }
        return generated
    }
}
