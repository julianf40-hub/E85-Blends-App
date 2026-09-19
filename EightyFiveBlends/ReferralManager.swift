//
//  ReferralManager.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — iOS referral client foundation. Owns the referral installation credential,
//  bootstraps/refreshes progress against supabase/functions/referral-api, and exposes state for a
//  FUTURE Refer & Earn UI (explicitly NOT built in this PR). No SwiftUI view talks to
//  URLSession/Keychain directly — mirrors RevenueCatSubscriptionService's own
//  @MainActor @Observable manager shape.
//
//  NEVER logs, persists outside Keychain, or sends to analytics: installationSecret, or the raw
//  RevenueCat App User ID. Only ReferralAPIService's request bodies ever see them, over HTTPS,
//  exactly once per call — this type never even holds the App User ID as a stored property,
//  only ever forwarding whatever the caller supplies for the duration of one bootstrap call.
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
    /// True once a bootstrap has ever succeeded THIS process — see `bootstrapIfNeeded(_:)`'s own
    /// re-entrancy guard. Deliberately process-scoped, not persisted: a fresh launch re-bootstraps
    /// (idempotently — the backend's own `bootstrap` action is safe to call repeatedly) so a
    /// RevenueCat identity change between launches is still picked up.
    private(set) var hasBootstrappedThisLaunch = false

    private var credential: ReferralInstallationCredential?
    private let credentialStore: ReferralCredentialStoring
    private let environmentProvider: ReferralRevenueEnvironmentProviding
    private let serviceFactory: @Sendable () throws -> ReferralAPIServicing
    private var bootstrapTask: Task<Void, Never>?

    init(
        credentialStore: ReferralCredentialStoring = KeychainReferralCredentialStore(),
        environmentProvider: ReferralRevenueEnvironmentProviding = StoreKitReferralRevenueEnvironmentProvider(),
        serviceFactory: @escaping @Sendable () throws -> ReferralAPIServicing = { try ReferralAPIService() }
    ) {
        self.credentialStore = credentialStore
        self.environmentProvider = environmentProvider
        self.serviceFactory = serviceFactory
    }

    /// Best-effort, one-shot startup bootstrap — see EightyFiveBlendsApp.swift's integration
    /// point. Safe to call more than once: a bootstrap already in flight is awaited rather than
    /// duplicated, and a call after this launch's bootstrap already succeeded is a no-op. Never
    /// throws — a temporary failure (network, backend, or no environment signal yet) leaves
    /// `loadState` as `.failed`/`.idle` for a future manual `refresh()` to retry, and never
    /// regenerates or touches the stored credential.
    func bootstrapIfNeeded(revenueCatAppUserID: String?) async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard hasBootstrappedThisLaunch == false else { return }
        guard let revenueCatAppUserID, revenueCatAppUserID.isEmpty == false else { return }

        let task = Task { [weak self] in
            await self?.performBootstrap(revenueCatAppUserID: revenueCatAppUserID)
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    private func performBootstrap(revenueCatAppUserID: String) async {
        loadState = .loading
        let resolvedCredential = ReferralInstallationCredential.loadOrCreate(using: credentialStore)
        credential = resolvedCredential

        guard let environment = await environmentProvider.currentEnvironment() else {
            // No authoritative environment signal available yet — best-effort only (see this
            // type's header). A later launch will try again; the credential above is already
            // durably persisted either way, so nothing here is lost by waiting.
            loadState = .idle
            return
        }

        do {
            let service = try serviceFactory()
            let response = try await service.bootstrap(
                credential: resolvedCredential,
                revenueCatAppUserID: revenueCatAppUserID,
                environment: environment,
                appVersion: Self.currentAppVersion
            )
            loadState = .loaded(response.status)
            hasBootstrappedThisLaunch = true
        } catch let error as ReferralServiceError {
            loadState = .failed(error)
        } catch {
            loadState = .failed(.network(error.localizedDescription))
        }
    }

    /// Re-fetches progress from the backend — never computed locally (see this type's own
    /// "backend status is authoritative" header). A no-op if bootstrap has never produced a
    /// credential yet, since there is no authenticated installation to ask about.
    func refresh() async {
        guard let credential else { return }
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
    func applyReferralCode(_ code: String) async throws -> ReferralStatus {
        guard let credential else {
            throw ReferralServiceError.notConfigured
        }
        let service = try serviceFactory()
        let response = try await service.applyCode(code, credential: credential)
        loadState = .loaded(response.status)
        return response.status
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
