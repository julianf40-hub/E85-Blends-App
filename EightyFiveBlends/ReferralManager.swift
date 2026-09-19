//
//  ReferralManager.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — iOS referral client foundation. Owns the referral installation credential,
//  bootstraps/refreshes progress against supabase/functions/referral-api, and exposes state for a
//  FUTURE Refer & Earn UI (explicitly NOT built in this PR). No SwiftUI view talks to
//  URLSession/Keychain/RevenueCat/StoreKit directly — mirrors RevenueCatSubscriptionService's own
//  @MainActor @Observable manager shape.
//
//  NEVER logs, persists outside Keychain, or sends to analytics: installationSecret, or the raw
//  RevenueCat App User ID. Only ReferralAPIService's request bodies ever see them, over HTTPS,
//  exactly once per call — this type never holds the App User ID as a stored property, only ever
//  reading it fresh from `identityProvider` for the duration of one bootstrap attempt.
//
//  BACKEND STATUS IS AUTHORITATIVE: this type never locally computes/derives referral progress,
//  qualification, or milestone state — every `ReferralStatus` shown here came directly from a
//  referral-api response.
//
//  PURCHASE-ORDERING SAFETY: `applyReferralCode(_:)` is `async throws` — it never returns/updates
//  state until the BACKEND confirms the result. A future purchase-flow view can
//  `try await ReferralManager.shared.applyReferralCode(code)` immediately before presenting a
//  purchase and know definitively whether attribution succeeded before proceeding — never
//  fire-and-forget, and a failure never locally marks anything as applied.
//
//  CORRECTNESS HARDENING PASS (2.4.0):
//    - This type now owns fetching the RevenueCat App User ID itself, via the injected
//      `identityProvider` (see ReferralRevenueCatIdentityProviding.swift) — `bootstrapIfNeeded()`
//      takes no argument, and EightyFiveBlendsApp.swift never sees the raw identity.
//    - `ensureBootstrapped()` is now the SINGLE preparation gate `bootstrapIfNeeded()`,
//      `refresh()`, and `applyReferralCode(_:)` all go through. A `status`/`apply_code` request is
//      never sent while no backend participant is known to exist yet for this installation — if
//      the startup bootstrap failed or was never attempted (no identity/environment signal yet),
//      `refresh()`/`applyReferralCode(_:)` transparently retry it first rather than calling
//      `status`/`apply_code` straight into a guaranteed `invalid_installation_credentials`.
//    - `credential` and `hasBootstrappedThisLaunch` are only ever mutated after BOTH a durable
//      Keychain save (see ReferralInstallationCredential.loadOrCreate) AND a successful backend
//      `bootstrap` call have completed — never optimistically, and never on top of an unpersisted
//      credential (see ReferralCredentialStoring's own header on why that would risk forking the
//      referral identity).
//

import Foundation
import Observation

enum ReferralLoadState: Equatable {
    case idle
    case loading
    case loaded(ReferralStatus)
    case failed(ReferralServiceError)
}

@MainActor
@Observable
final class ReferralManager {
    static let shared = ReferralManager()

    private(set) var loadState: ReferralLoadState = .idle
    /// True once a bootstrap has ever succeeded THIS process — see `ensureBootstrapped()`'s own
    /// re-entrancy guard. Deliberately process-scoped, not persisted: a fresh launch re-bootstraps
    /// (idempotently — the backend's own `bootstrap` action is safe to call repeatedly) so a
    /// RevenueCat identity change between launches is still picked up.
    private(set) var hasBootstrappedThisLaunch = false

    private var credential: ReferralInstallationCredential?
    private let credentialStore: ReferralCredentialStoring
    private let environmentProvider: ReferralRevenueEnvironmentProviding
    private let identityProvider: ReferralRevenueCatIdentityProviding
    private let serviceFactory: @Sendable () throws -> ReferralAPIServicing
    private var bootstrapTask: Task<Void, Error>?

    init(
        credentialStore: ReferralCredentialStoring = KeychainReferralCredentialStore(),
        environmentProvider: ReferralRevenueEnvironmentProviding = StoreKitReferralRevenueEnvironmentProvider(),
        identityProvider: ReferralRevenueCatIdentityProviding = LiveReferralRevenueCatIdentityProvider(),
        serviceFactory: @escaping @Sendable () throws -> ReferralAPIServicing = { try ReferralAPIService() }
    ) {
        self.credentialStore = credentialStore
        self.environmentProvider = environmentProvider
        self.identityProvider = identityProvider
        self.serviceFactory = serviceFactory
    }

    /// Best-effort, fire-and-forget startup entry point — see EightyFiveBlendsApp.swift's
    /// integration point. Never throws: delegates all preparation to `ensureBootstrapped()` and
    /// lets `loadState` (set inside `performBootstrap()`) carry the outcome for any future
    /// diagnostics UI — a temporary failure here must never propagate to the caller and must never
    /// affect launch, Stations, entitlement resolution, the paywall, or purchasing.
    func bootstrapIfNeeded() async {
        try? await ensureBootstrapped()
    }

    /// Re-fetches progress from the backend — never computed locally (see this type's own
    /// "backend status is authoritative" header). Ensures a successful bootstrap first (see
    /// `ensureBootstrapped()`); if preparation itself can't complete yet (or fails), this stays a
    /// safe no-op — `loadState` already reflects why, and a pull-to-refresh caller never needs a
    /// do/catch.
    func refresh() async {
        do {
            try await ensureBootstrapped()
        } catch {
            return
        }
        guard let credential else {
            // Structurally unreachable — ensureBootstrapped() only returns normally after
            // performBootstrap() has set `credential`. A guard, not a force-unwrap, so a future
            // refactor accident fails safe instead of crashing.
            return
        }

        loadState = .loading
        do {
            let service = try serviceFactory()
            let status = try await service.status(credential: credential)
            loadState = .loaded(status)
        } catch let error as ReferralServiceError {
            loadState = .failed(error)
        } catch {
            loadState = .failed(.network(error.localizedDescription))
        }
    }

    /// Applies someone else's referral code. See this type's header ("PURCHASE-ORDERING SAFETY")
    /// — never fire-and-forget, never locally marks success ahead of the backend's own answer.
    /// Ensures a successful bootstrap first (see `ensureBootstrapped()`) — if preparation itself
    /// fails, that error propagates directly, exactly like any other failure to apply the code
    /// (never silently swallowed, and `apply_code` is never sent without a known backend
    /// participant).
    func applyReferralCode(_ code: String) async throws -> ReferralStatus {
        try await ensureBootstrapped()
        guard let credential else {
            throw ReferralServiceError.notConfigured
        }
        let service = try serviceFactory()
        let response = try await service.applyCode(code, credential: credential)
        loadState = .loaded(response.status)
        return response.status
    }

    /// The single preparation gate every backend-calling entry point above goes through before
    /// talking to referral-api. Guarantees a durably-persisted credential AND a successful backend
    /// `bootstrap` call have both completed at least once for this installation before ANY
    /// `status`/`apply_code` request is attempted — see this type's own header.
    ///
    /// Concurrency: simultaneous callers (a startup call racing a manual pull-to-refresh, say) are
    /// deduplicated onto the SAME in-flight attempt via `bootstrapTask` — never more than one live
    /// backend bootstrap call at a time, and never two credentials generated concurrently. If that
    /// shared attempt fails, EVERY caller awaiting it receives the same failure; `bootstrapTask` is
    /// cleared afterward either way so a later call can retry once its own dependencies (identity,
    /// environment, network, Keychain) may have recovered.
    private func ensureBootstrapped() async throws {
        if hasBootstrappedThisLaunch { return }

        if let bootstrapTask {
            try await bootstrapTask.value
            return
        }

        let task = Task { [weak self] () async throws -> Void in
            guard let self else { return }
            try await self.performBootstrap()
        }
        bootstrapTask = task
        defer { bootstrapTask = nil }
        try await task.value
    }

    private func performBootstrap() async throws {
        loadState = .loading

        guard let revenueCatAppUserID = identityProvider.currentAppUserID(), revenueCatAppUserID.isEmpty == false else {
            // Not an error — RevenueCat simply hasn't configured/produced an identity yet this
            // launch. Stays idle/retryable, exactly like "no environment signal yet" below.
            loadState = .idle
            throw ReferralServiceError.notConfigured
        }

        let resolvedCredential: ReferralInstallationCredential
        do {
            resolvedCredential = try ReferralInstallationCredential.loadOrCreate(using: credentialStore)
        } catch {
            // A genuine Keychain failure — `credential` is deliberately NOT assigned here, and
            // this never reaches the backend call below (see ReferralCredentialStoring's own
            // header on why generating/using an unpersisted credential would risk forking the
            // referral identity).
            let serviceError = ReferralServiceError.credentialUnavailable
            loadState = .failed(serviceError)
            throw serviceError
        }

        guard let environment = await environmentProvider.currentEnvironment() else {
            loadState = .idle
            throw ReferralServiceError.notConfigured
        }

        do {
            let service = try serviceFactory()
            let response = try await service.bootstrap(
                credential: resolvedCredential,
                revenueCatAppUserID: revenueCatAppUserID,
                environment: environment,
                appVersion: Self.currentAppVersion
            )
            // Only NOW — after a durably-persisted credential AND a confirmed backend bootstrap —
            // do `credential`/`hasBootstrappedThisLaunch` change. A failure at any point above or
            // below never reaches these two lines (see this type's own header).
            credential = resolvedCredential
            loadState = .loaded(response.status)
            hasBootstrappedThisLaunch = true
        } catch let error as ReferralServiceError {
            loadState = .failed(error)
            throw error
        } catch {
            let serviceError = ReferralServiceError.network(error.localizedDescription)
            loadState = .failed(serviceError)
            throw serviceError
        }
    }

    /// CFBundleShortVersionString, capped to referral-api's own 64-character bound (see
    /// _shared/referral-api-validation.ts's MAX_APP_VERSION_LENGTH) — never the build number, and
    /// never sent at all if unavailable rather than guessing a value.
    private static var currentAppVersion: String? {
        guard
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        return String(version.prefix(64))
    }
}
