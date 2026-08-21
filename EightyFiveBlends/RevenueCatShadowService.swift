//
//  RevenueCatShadowService.swift
//  EightyFiveBlends
//
//  85Blends 2.3.0 — RevenueCat Phase 1: safe shadow integration.
//
//  RevenueCat is being introduced because a future server-driven Pro capability (Station Price
//  Alerts) needs authoritative subscription lifecycle state while the app is closed — something
//  today's on-device-only StoreKit entitlement cannot provide. This file is deliberately the
//  ENTIRE extent of that integration for now: RevenueCat is configured, it observes the same
//  transactions 85Blends' own StoreKit code already completes, and its resulting entitlement
//  state is surfaced here purely for comparison/diagnostics. It has no authority whatsoever over
//  production Pro access — see `SubscriptionManager.swift`, which this file never calls into and
//  is never called from, and which remains the single source of truth for `isPro`/`isProUser`
//  exactly as before this file existed. A later, separate task will decide whether and how
//  RevenueCat ever participates in that decision.
//
//  KEY SAFETY INVARIANT: nothing in this type can affect `SubscriptionManager.isPro`. Every
//  property here is read-only diagnostic/shadow state, consumed today only by the Internal/Debug
//  migration diagnostics in PreferencesView.swift. If RevenueCat fails to configure, fails to
//  reach its servers, or disagrees with StoreKit in either direction, the only user-visible
//  effect anywhere in the app is what those diagnostics show — production entitlement is
//  completely unaffected. Never add a call site that reads `revenueCatIsPro` to decide anything
//  a real user sees outside that Internal/Debug screen.
//
//  PUBLIC vs SECRET KEYS: this file only ever uses a RevenueCat *public* SDK key (client-safe,
//  same trust model as SUPABASE_ANON_KEY in SupabaseConfig.swift — see RevenueCatConfiguration.
//  swift). A RevenueCat *secret* API key, a webhook signing secret, or any App Store Connect/
//  Supabase server credential must NEVER appear in this file, anywhere else in the iOS app, or
//  in source control — those are server-only concerns for a future backend task, not this one.
//
//  TRANSACTION OWNERSHIP: 85Blends' own StoreKit code (SubscriptionManager.purchase(_:)) keeps
//  finishing every transaction exactly as before (`tx.finish()`). RevenueCat is configured with
//  `purchasesAreCompletedBy: .myApp` specifically so it never attempts to finish a transaction
//  itself — this is RevenueCat's own documented "Observer Mode" successor, designed precisely
//  for an app that wants RevenueCat's entitlement tracking without handing it purchase
//  ownership. See https://www.revenuecat.com/docs/migrating-to-revenuecat/sdk-or-not/finishing-transactions
//
//  ANONYMOUS ONLY: 85Blends has no account system (see CLAUDE.md, VehicleCreationPolicy.swift's
//  own no-account framing). This file never calls `Purchases.shared.logIn(_:)` and never
//  supplies a custom App User ID — RevenueCat manages its own anonymous identity exactly as it
//  would for any login-less app. That anonymous RevenueCat App User ID is deliberately its own,
//  separate identity — never conflated with 85Blends' Community Pricing reporter ID
//  (CommunityPriceService.anonymousReporterID), any future push-notification installation ID, or
//  an APNs device token. See the Station Price Alerts and RevenueCat migration-readiness audits
//  for why those three stay distinct.
//

import Foundation
import Observation
import RevenueCat

@MainActor
@Observable
final class RevenueCatShadowService {
    static let shared = RevenueCatShadowService()

    /// The RevenueCat entitlement identifier this app's future Pro gate would eventually read —
    /// see the RevenueCat migration-readiness audit's recommendation. A short, duration-free
    /// name (not e.g. "pro_monthly") so a future 3-month/annual product can attach to the same
    /// entitlement without any code change here.
    static let proEntitlementID = "pro"

    /// Conservative, documented-motivated backoff between failed historical-sync attempts.
    /// RevenueCat's own guidance warns against syncing/restoring frequently ("can increase
    /// latency... and can unintentionally alias customers together") — this is deliberately not
    /// aggressive, and there is no background timer anywhere in this file that would retry
    /// sooner; a retry only happens opportunistically the next time the app is launched fresh,
    /// per `attemptHistoricalSyncIfEligible(realStoreKitIsPro:)`'s own "at most once per
    /// session" guard below.
    private static let retryBackoffInterval: TimeInterval = 60 * 60 * 24 // 24 hours

    private static let historicalSyncSucceededDefaultsKey = "revenueCatShadow.historicalSyncSucceeded"
    private static let historicalSyncLastAttemptDefaultsKey = "revenueCatShadow.historicalSyncLastAttemptAt"

    // MARK: - Shadow state (diagnostic only — see this type's header)

    enum ConfigurationState: Equatable {
        /// Default state, and the state a missing/blank public SDK key leaves this in forever
        /// for this launch — the safe no-op path. See RevenueCatConfiguration.publicSDKKey.
        /// `Purchases.configure(with:)` itself is non-throwing, so there is no reachable
        /// "configuration failed" state here — a bad key surfaces later, as a `customerInfo()`/
        /// `customerInfoStream` failure captured in `lastErrorDescription` while this stays
        /// `.configured` (the SDK call itself did succeed).
        case notConfigured
        case configured
    }

    enum HistoricalSyncState: Equatable {
        /// Verified StoreKit is Free — there is nothing to migrate, and syncing would be pure
        /// noise (never spam RevenueCat for a Free user).
        case notNeeded
        case notAttempted
        case inProgress
        case succeeded
        case retryPending(nextEligibleAt: Date)
        case failed(String)
    }

    private(set) var configurationState: ConfigurationState = .notConfigured
    private(set) var revenueCatIsPro: Bool = false
    private(set) var customerInfoLastUpdatedAt: Date?
    private(set) var maskedAppUserID: String?
    private(set) var historicalSyncState: HistoricalSyncState = .notAttempted
    private(set) var lastErrorDescription: String?

    var isConfigured: Bool { configurationState == .configured }

    // MARK: - Private

    private var customerInfoObservationTask: Task<Void, Never>?
    /// In-memory only, deliberately not persisted — resets every launch, which is exactly what
    /// backs "never more than once during one launch/session" (Phase 18 of the migration task).
    /// Persisted success/backoff state (below, via UserDefaults) is the separate, cross-launch
    /// guard against re-syncing an already-migrated or recently-failed subscriber.
    private var hasAttemptedSyncThisSession = false

    private init() {}

    // MARK: - Configuration

    /// Idempotent — safe to call once from app startup. Does nothing (stays `.notConfigured`,
    /// logs in DEBUG/INTERNAL_BUILD only) if no public SDK key is configured. Never throws,
    /// never affects StoreKit, never affects `SubscriptionManager`.
    func configureIfNeeded() async {
        guard configurationState == .notConfigured else { return }

        guard let apiKey = RevenueCatConfiguration.publicSDKKey else {
            #if DEBUG || INTERNAL_BUILD
            print("[85Blends][RevenueCat] Shadow integration unavailable: SDK key not configured.")
            #endif
            return
        }

        #if DEBUG || INTERNAL_BUILD
        // Verbose SDK logging only in Debug/Internal — matches SubscriptionManager's own
        // always-visible-in-those-builds-only diagnostic posture. Never enabled in Release.
        Purchases.logLevel = .debug
        #endif

        let configuration = Configuration.Builder(withAPIKey: apiKey)
            // The one load-bearing line in this whole file: 85Blends' own StoreKit code keeps
            // finishing every transaction (SubscriptionManager.handle(_:) → tx.finish()).
            // RevenueCat must never also try to finish the same transaction.
            .with(purchasesAreCompletedBy: .myApp, storeKitVersion: .storeKit2)
            .build()
        Purchases.configure(with: configuration)

        configurationState = .configured
        maskedAppUserID = Self.maskedAppUserID(from: Purchases.shared.appUserID)
        startObservingCustomerInfo()

        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            apply(customerInfo)
        } catch {
            // Configuration itself succeeded; only this initial fetch failed (e.g. offline on
            // first launch — a real, documented gap in RevenueCat's own migration guidance).
            // Shadow state simply stays at its default until the next successful fetch/stream
            // update. This can never affect production isPro — see this type's header.
            lastErrorDescription = error.localizedDescription
        }
    }

    // MARK: - CustomerInfo observation

    private func startObservingCustomerInfo() {
        customerInfoObservationTask?.cancel()
        customerInfoObservationTask = Task { [weak self] in
            do {
                for try await customerInfo in Purchases.shared.customerInfoStream {
                    guard let self, Task.isCancelled == false else { return }
                    self.apply(customerInfo)
                }
            } catch {
                guard let self, Task.isCancelled == false else { return }
                self.lastErrorDescription = "CustomerInfo observation stopped: \(error.localizedDescription)"
            }
        }
    }

    private func apply(_ customerInfo: CustomerInfo) {
        revenueCatIsPro = customerInfo.entitlements[Self.proEntitlementID]?.isActive == true
        customerInfoLastUpdatedAt = Date()
        maskedAppUserID = Self.maskedAppUserID(from: Purchases.shared.appUserID)
    }

    /// Internal/Debug diagnostics-only manual refresh — re-fetches CustomerInfo and nothing
    /// else. Deliberately NOT a "Sync Purchases" or "Restore" action: it never calls
    /// `syncPurchases()`, `restorePurchases()`, or any purchase API, and never mutates
    /// entitlement/customer state. See PreferencesView.swift's diagnostics card, the only caller.
    func refreshCustomerInfoNow() async {
        guard configurationState == .configured else { return }
        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            apply(customerInfo)
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    // MARK: - Historical (existing-subscriber) sync

    /// The controlled, conservative migration sync described in the RevenueCat migration task.
    /// `realStoreKitIsPro` must be the actual verified StoreKit entitlement
    /// (`SubscriptionManager.isProStoreKit`) — never `SubscriptionManager.isPro`, which also
    /// reflects the Internal/Debug Force Pro/Force Free override. A developer forcing Pro on a
    /// Free StoreKit account must never trigger a real sync attempt against RevenueCat.
    ///
    /// Eligible only when ALL of: RevenueCat is configured; nothing has been attempted yet this
    /// session (in-memory, resets every launch); the real StoreKit entitlement is Pro (a Free
    /// StoreKit user has nothing to migrate — never sync/spam for Free users); RevenueCat does
    /// not already show Pro (nothing to reconcile if it agrees); no prior sync has already
    /// succeeded (persisted — a succeeded migration never re-syncs); and the backoff window since
    /// any prior failed attempt (persisted) has elapsed.
    func attemptHistoricalSyncIfEligible(realStoreKitIsPro: Bool) async {
        guard configurationState == .configured else { return }
        guard hasAttemptedSyncThisSession == false else { return }

        guard realStoreKitIsPro else {
            historicalSyncState = .notNeeded
            return
        }

        guard revenueCatIsPro == false else {
            historicalSyncState = .succeeded
            Self.persistedHistoricalSyncSucceeded = true
            return
        }

        guard Self.persistedHistoricalSyncSucceeded == false else {
            historicalSyncState = .succeeded
            return
        }

        if let lastAttempt = Self.persistedHistoricalSyncLastAttemptAt {
            let nextEligibleAt = lastAttempt.addingTimeInterval(Self.retryBackoffInterval)
            guard Date() >= nextEligibleAt else {
                historicalSyncState = .retryPending(nextEligibleAt: nextEligibleAt)
                return
            }
        }

        hasAttemptedSyncThisSession = true
        historicalSyncState = .inProgress
        Self.persistedHistoricalSyncLastAttemptAt = Date()

        do {
            // The documented programmatic migration path — never restorePurchases() here, which
            // official RevenueCat guidance reserves for explicit user action (it "may cause OS
            // level sign-in prompts to appear"). syncPurchases() does not.
            let customerInfo = try await Purchases.shared.syncPurchases()
            apply(customerInfo)

            if revenueCatIsPro {
                historicalSyncState = .succeeded
                Self.persistedHistoricalSyncSucceeded = true
            } else {
                // Completed without throwing, but RevenueCat still doesn't show Pro (e.g. the
                // local receipt didn't contain what was expected). Recoverable — eligible for
                // another attempt after the backoff window, not treated as permanent.
                let message = "Sync completed but RevenueCat did not report an active Pro entitlement."
                lastErrorDescription = message
                historicalSyncState = .failed(message)
            }
        } catch {
            lastErrorDescription = error.localizedDescription
            historicalSyncState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Persisted migration state (UserDefaults — mirrors SubscriptionManager.
    // debugProOverride's own persistence pattern; separate per bundle ID automatically, since
    // Internal and Production/Debug are already separate UserDefaults domains)

    private static var persistedHistoricalSyncSucceeded: Bool {
        get { UserDefaults.standard.bool(forKey: historicalSyncSucceededDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: historicalSyncSucceededDefaultsKey) }
    }

    private static var persistedHistoricalSyncLastAttemptAt: Date? {
        get {
            let stored = UserDefaults.standard.double(forKey: historicalSyncLastAttemptDefaultsKey)
            return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: historicalSyncLastAttemptDefaultsKey) }
    }

    // MARK: - Masking

    /// Mirrors CommunityPriceService.maskedReporterID's exact prefix/suffix convention, so
    /// diagnostic identifier masking reads consistently across the app.
    private static func maskedAppUserID(from raw: String) -> String {
        guard raw.count > 8 else { return "***" }
        let prefix = raw.prefix(4)
        let suffix = raw.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}
