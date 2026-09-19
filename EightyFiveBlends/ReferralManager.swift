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
//  STATE-CONSISTENCY HARDENING PASS (2.4.0): `refresh()` and `applyReferralCode(_:)` used to run
//  fully independently once bootstrap was settled — each fetched/mutated `loadState` on its own
//  timeline, so an OLDER refresh whose network response happened to arrive AFTER a newer apply's
//  could silently clobber apply's authoritative result with stale data. `operationTail` now
//  chains every post-bootstrap operation in REQUEST order (not network-completion order): a
//  refresh/apply requested while another is still running waits for that one to fully finish
//  before doing its own network call, so whichever was requested LATER always finishes — and
//  writes `loadState` — strictly after whichever was requested earlier, regardless of which
//  network response actually arrives first. Two overlapping refreshes deduplicate onto one status
//  request (`inFlightRefreshTask`); two overlapping applyReferralCode calls never deduplicate —
//  even for the same code — each always reaches the backend and gets its own authoritative
//  answer (same-code idempotency is a backend responsibility, not this type's to invent). See
//  ReferralManagerTests.swift's own "STATE-CONSISTENCY HARDENING PASS" section for the tests that
//  reproduce the original race and verify this fix.
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
    /// The most recently QUEUED post-bootstrap operation (refresh or apply), used purely as a
    /// join point — every new operation awaits this before doing its own network call, then
    /// replaces it with itself. See this type's header ("STATE-CONSISTENCY HARDENING PASS").
    private var operationTail: Task<Void, Never>?
    /// Non-nil exactly while a refresh is queued or running and hasn't yet produced its result. A
    /// refresh requested during this window is DEDUPLICATED onto this same task instead of
    /// enqueuing a second, redundant status request. applyReferralCode never consults this: two
    /// overlapping applies always run as separate, serialized operations.
    private var inFlightRefreshTask: Task<Void, Never>?

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
    ///
    /// STATE-CONSISTENCY: deduplicates against another already-in-flight refresh
    /// (`inFlightRefreshTask`), and otherwise queues itself behind whatever post-bootstrap
    /// operation (an older refresh OR an in-flight apply) is currently running via
    /// `operationTail` — see this type's header. The dedup check-and-claim below is entirely
    /// synchronous (no `await` in between) so two calls made in the same instant can never both
    /// believe they're "the first" and race to create separate tasks.
    func refresh() async {
        if let inFlightRefreshTask {
            await inFlightRefreshTask.value
            return
        }

        let previousTail = operationTail
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureBootstrapped()
            } catch {
                self.inFlightRefreshTask = nil
                return
            }
            guard let credential = self.credential else {
                // Structurally unreachable — ensureBootstrapped() only returns normally after
                // performBootstrap() has set `credential`. A guard, not a force-unwrap, so a
                // future refactor accident fails safe instead of crashing.
                self.inFlightRefreshTask = nil
                return
            }
            // Wait for whatever was queued before THIS refresh was requested (an older refresh or
            // an in-flight apply) so a stale response here can never land after — and overwrite —
            // a logically later operation's result.
            await previousTail?.value
            await self.performRefresh(credential: credential)
            self.inFlightRefreshTask = nil
        }
        inFlightRefreshTask = task
        operationTail = task
        await task.value
    }

    private func performRefresh(credential: ReferralInstallationCredential) async {
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
    ///
    /// STATE-CONSISTENCY: NEVER deduplicated against another in-flight applyReferralCode call,
    /// even for the identical code — two overlapping calls are serialized (queued behind
    /// `operationTail`, exactly like refresh) but each always reaches the backend and returns
    /// whatever THAT call's own backend response says (`already_applied`, a different outcome,
    /// etc.). Same-code idempotency is the backend's own responsibility, never invented here. The
    /// claim of `operationTail` below is synchronous — see `refresh()`'s own header for why that
    /// matters.
    func applyReferralCode(_ code: String) async throws -> ReferralStatus {
        let previousTail = operationTail
        let resultTask = Task { [weak self] () async throws -> ReferralStatus in
            guard let self else { throw ReferralServiceError.notConfigured }
            try await self.ensureBootstrapped()
            guard let credential = self.credential else {
                throw ReferralServiceError.notConfigured
            }
            // Wait for whatever was queued before THIS apply was requested (an older apply OR an
            // in-flight refresh) so this call's mutation always lands strictly after it.
            await previousTail?.value
            let service = try self.serviceFactory()
            let response = try await service.applyCode(code, credential: credential)
            self.loadState = .loaded(response.status)
            return response.status
        }
        // A Void/Never proxy so the NEXT operation (a refresh or another apply) can wait for this
        // one to finish without caring about its throw/return type.
        operationTail = Task { _ = try? await resultTask.value }
        return try await resultTask.value
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
