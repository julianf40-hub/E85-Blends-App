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
//  REQUEST-ORDER EDGE CASE (2.4.0): the dedup above was originally keyed on nothing but
//  `inFlightRefreshTask != nil`, which was too broad — a refresh requested AFTER an apply had
//  already queued behind an older, still-in-flight refresh would dedupe directly onto that OLDER
//  refresh, and could return (with the older refresh's stale result) before the apply had even
//  run, even though it was requested after the apply. `operationGeneration` fixes this: it's
//  incremented every time ANY operation claims `operationTail`, and refresh only dedupes onto
//  `inFlightRefreshTask` when `operationGeneration` is STILL the value it was when that refresh
//  claimed the tail — i.e., nothing (in particular, no apply) has been queued since. Once
//  something else claims the tail, a later refresh always enqueues itself as a genuinely NEW
//  operation instead, behind whatever is now current. See ReferralManagerTests.swift's own
//  "REQUEST-ORDER EDGE CASE" section.
//

import Foundation
import Observation

enum ReferralLoadState: Equatable {
    /// Neutral initial state — no attempt has been made yet this process. Deliberately NEVER
    /// reused to mean "a prerequisite is unavailable": before this hardening pass, a missing
    /// RevenueCat identity or StoreKit environment signal both left this at `.idle`, which
    /// `ReferEarnView` rendered identically to `.loading` — a real, potentially indefinite
    /// prerequisite wait was visually indistinguishable from "still loading" (see this feature's
    /// own task spec, Part A). `.waitingForRevenueCatIdentity`/`.waitingForStoreEnvironment` below
    /// exist specifically so a genuine wait is never silently folded back into this case.
    case idle
    case loading
    /// `performBootstrap()` is waiting on `identityProvider.currentAppUserID()` — RevenueCat
    /// hasn't produced an App User ID yet this launch. Not an error: routine and retryable, but
    /// distinct from `.idle` so the UI can say what setup is actually waiting on.
    case waitingForRevenueCatIdentity
    /// `performBootstrap()` is waiting on `environmentProvider.currentEnvironment()` — the
    /// verified StoreKit SANDBOX/PRODUCTION signal referral-api's bootstrap action requires isn't
    /// available yet (or the bounded wait for it timed out — see
    /// StoreKitReferralRevenueEnvironmentProvider's own "BOUNDED WAIT" header). Not an error.
    case waitingForStoreEnvironment
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
    /// Incremented every time ANY post-bootstrap operation (refresh or apply) claims
    /// `operationTail` — see this type's header ("REQUEST-ORDER EDGE CASE") for why refresh's
    /// dedup check needs this in addition to `inFlightRefreshTask`.
    private var operationGeneration = 0
    /// Non-nil exactly while a refresh is queued or running and hasn't yet produced its result. A
    /// refresh requested during this window is DEDUPLICATED onto this same task ONLY IF
    /// `operationGeneration` still matches `inFlightRefreshGeneration` below (nothing has claimed
    /// the tail since) — otherwise it enqueues itself as a new operation instead. applyReferralCode
    /// never consults either of these: two overlapping applies always run as separate, serialized
    /// operations.
    private var inFlightRefreshTask: Task<Void, Never>?
    /// The `operationGeneration` value at the moment `inFlightRefreshTask` claimed the tail — see
    /// `refresh()`'s dedup check and `clearInFlightRefresh(ifStillGeneration:)`.
    private var inFlightRefreshGeneration = 0

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
    /// (`inFlightRefreshTask`) ONLY IF no other operation has claimed the tail of the queue since
    /// that refresh started (`operationGeneration` — see this type's header, "REQUEST-ORDER EDGE
    /// CASE"); otherwise it queues itself behind whatever post-bootstrap operation (an older
    /// refresh OR an in-flight apply) is CURRENTLY running via `operationTail`. The check-and-claim
    /// below is entirely synchronous (no `await` in between) so two calls made in the same instant
    /// can never both believe they're "the first" and race to create separate tasks.
    func refresh() async {
        if let inFlightRefreshTask, inFlightRefreshGeneration == operationGeneration {
            await inFlightRefreshTask.value
            return
        }

        let previousTail = operationTail
        operationGeneration += 1
        let myGeneration = operationGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureBootstrapped()
            } catch {
                self.clearInFlightRefresh(ifStillGeneration: myGeneration)
                return
            }
            guard let credential = self.credential else {
                // Structurally unreachable — ensureBootstrapped() only returns normally after
                // performBootstrap() has set `credential`. A guard, not a force-unwrap, so a
                // future refactor accident fails safe instead of crashing.
                self.clearInFlightRefresh(ifStillGeneration: myGeneration)
                return
            }
            // Wait for whatever was queued before THIS refresh was requested (an older refresh or
            // an in-flight apply) so a stale response here can never land after — and overwrite —
            // a logically later operation's result.
            await previousTail?.value
            await self.performRefresh(credential: credential)
            self.clearInFlightRefresh(ifStillGeneration: myGeneration)
        }
        inFlightRefreshTask = task
        inFlightRefreshGeneration = myGeneration
        operationTail = task
        await task.value
    }

    /// Clears `inFlightRefreshTask` only if it still belongs to THIS refresh (identified by
    /// `generation`) — see this type's header ("REQUEST-ORDER EDGE CASE"). A refresh that queued
    /// behind an intervening apply claims the slot with a NEWER generation; this older refresh's
    /// own cleanup, running later, must never clobber that newer claim once it finishes.
    private func clearInFlightRefresh(ifStillGeneration generation: Int) {
        guard inFlightRefreshGeneration == generation else { return }
        inFlightRefreshTask = nil
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
        // Claiming the tail always advances the generation — see this type's header
        // ("REQUEST-ORDER EDGE CASE"). This is what invalidates any refresh's dedup eligibility
        // once an apply has been queued: a refresh checking `inFlightRefreshGeneration ==
        // operationGeneration` afterward will see a mismatch and correctly enqueue itself anew.
        operationGeneration += 1
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
            // launch. Retryable, but distinct from `.idle` (see ReferralLoadState's own header) so
            // the UI can say specifically what referral setup is waiting on, instead of an
            // indefinite generic spinner.
            loadState = .waitingForRevenueCatIdentity
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

        // Set BEFORE awaiting the environment signal — StoreKitReferralRevenueEnvironmentProvider
        // bounds its own wait (see that type's own "BOUNDED WAIT" header), but even a bounded wait
        // takes real time; this immediately tells the UI what referral setup is waiting on instead
        // of leaving it on a generic network spinner for however long that wait takes.
        loadState = .waitingForStoreEnvironment
        guard let environment = await environmentProvider.currentEnvironment() else {
            // Already `.waitingForStoreEnvironment` from just above — explicit here too so this
            // stays correct even if a future refactor reorders the lines above. No authoritative
            // signal arrived before the provider's own bounded wait gave up — never a guess.
            loadState = .waitingForStoreEnvironment
            throw ReferralServiceError.notConfigured
        }
        loadState = .loading

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
