//
//  RevenueCatSubscriptionService.swift
//  EightyFiveBlends
//
//  85Blends 2.3.0 — RevenueCat authoritative subscription cutover.
//
//  RevenueCat is the application-level subscription management layer for 85Blends: it loads the
//  subscription offering, initiates purchases, restores purchases, interprets CustomerInfo, and
//  determines whether `pro` is active. Apple/StoreKit still performs the underlying App Store
//  transaction (the product remains `com.85blends.subscription.monthly`) — RevenueCat is
//  configured with `purchasesAreCompletedBy: .revenueCat`, so RevenueCat owns purchasing end to
//  end rather than observing transactions 85Blends' own StoreKit code would otherwise complete.
//
//  KEY AUTHORITY INVARIANT: `revenueCatIsPro` below — derived from
//  `CustomerInfo.entitlements["pro"]?.isActive == true` — is the ONLY real subscription
//  entitlement source in this app. `SubscriptionManager.isPro` reads it directly (Internal/Debug
//  builds may still layer the Developer Pro Override on top — see SubscriptionManager.swift).
//  There is no StoreKit-side entitlement authority left to agree or disagree with; see the
//  85Blends 2.3.0 RevenueCat cutover report for the previous shadow-observation architecture this
//  replaces.
//
//  PUBLIC vs SECRET KEYS: this file only ever uses a RevenueCat *public* SDK key (client-safe,
//  same trust model as SUPABASE_ANON_KEY in SupabaseConfig.swift — see RevenueCatConfiguration.
//  swift). A RevenueCat *secret* API key, a webhook signing secret, or any App Store Connect/
//  Supabase server credential must NEVER appear in this file, anywhere else in the iOS app, or
//  in source control — those are server-only concerns for a future backend task, not this one.
//
//  ANONYMOUS ONLY: 85Blends has no account system (see CLAUDE.md, VehicleCreationPolicy.swift's
//  own no-account framing). This file never calls `Purchases.shared.logIn(_:)` and never
//  supplies a custom App User ID — RevenueCat manages its own anonymous identity exactly as it
//  would for any login-less app. That anonymous RevenueCat App User ID is deliberately its own,
//  separate identity — never conflated with 85Blends' Community Pricing reporter ID
//  (CommunityPriceService.anonymousReporterID), any future push-notification installation ID, or
//  an APNs device token.
//
//  TESTABILITY: real SDK calls are routed through the small `RevenueCatClient` protocol below
//  (`LiveRevenueCatClient` in production) so this type isn't hardwired to the `Purchases.shared`
//  global. The pure decision functions (`isProEntitlementActive`, `purchaseOutcome`,
//  `resolvePackage`, `revenueCatIsProAfterFailedRefresh`) contain the actual business logic and
//  are unit-testable without constructing real RevenueCat SDK model types — see
//  SubscriptionManagerTests.swift for why, and for the tests themselves.
//

import Foundation
import Observation
import RevenueCat

/// Thin boundary around the RevenueCat SDK calls this app makes, so `RevenueCatSubscriptionService`
/// doesn't hardcode every call to the `Purchases.shared` singleton. Deliberately small — 85Blends
/// has exactly one subscription product, so this is not a general-purpose billing abstraction.
protocol RevenueCatClient: Sendable {
    func fetchCustomerInfo() async throws -> CustomerInfo
    func fetchOfferings() async throws -> Offerings
    func purchase(package: Package) async throws -> PurchaseResultData
    func restorePurchases() async throws -> CustomerInfo
}

/// Production implementation — forwards directly to the configured `Purchases.shared` singleton.
struct LiveRevenueCatClient: RevenueCatClient {
    func fetchCustomerInfo() async throws -> CustomerInfo {
        try await Purchases.shared.customerInfo()
    }

    func fetchOfferings() async throws -> Offerings {
        try await Purchases.shared.offerings()
    }

    func purchase(package: Package) async throws -> PurchaseResultData {
        try await Purchases.shared.purchase(package: package)
    }

    func restorePurchases() async throws -> CustomerInfo {
        try await Purchases.shared.restorePurchases()
    }
}

@MainActor
@Observable
final class RevenueCatSubscriptionService {
    static let shared = RevenueCatSubscriptionService()

    /// The RevenueCat entitlement identifier this app's Pro gate reads. A short, duration-free
    /// name (not e.g. "pro_monthly") so a future 3-month/annual product could attach to the same
    /// entitlement without any code change here.
    static let proEntitlementID = "pro"

    /// The RevenueCat offering identifier configured in the RevenueCat dashboard.
    static let offeringID = "default"

    // MARK: - Configuration state

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

    /// Offering/package resolution state for the one 85Blends Pro monthly package. Kept distinct
    /// from `notLoaded` vs `loading` vs terminal-failure states so the paywall (via
    /// SubscriptionManager) can tell "haven't tried yet" from "tried and failed" — the same
    /// distinction `hasAttemptedProductLoad` made for StoreKit product loading before this
    /// cutover.
    enum PackageAvailability: Equatable {
        case notLoaded
        case loading
        case ready(Package)
        case offeringUnavailable
        case packageUnavailable
        /// The resolved package's underlying Apple product ID did not match
        /// `SubscriptionManager.monthlyID`. Never purchased — see `resolvePackage(...)`.
        case unexpectedProduct(String)

        static func == (lhs: PackageAvailability, rhs: PackageAvailability) -> Bool {
            switch (lhs, rhs) {
            case (.notLoaded, .notLoaded), (.loading, .loading),
                 (.offeringUnavailable, .offeringUnavailable), (.packageUnavailable, .packageUnavailable):
                return true
            case (.ready(let l), .ready(let r)):
                return l.identifier == r.identifier
            case (.unexpectedProduct(let l), .unexpectedProduct(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    enum PurchaseOutcome: Equatable {
        /// The purchase succeeded AND the returned CustomerInfo shows an active `pro` entitlement.
        case proActivated
        /// The purchase call completed without throwing, but the returned CustomerInfo does not
        /// show an active `pro` entitlement. Never treated as success — see Phase 12 of the
        /// migration task: a non-throwing result must never be conflated with `isPro = true`.
        case notEntitled
        case cancelled
        case failed(String)
    }

    // MARK: - Observable state (now authoritative — see this type's header)

    private(set) var configurationState: ConfigurationState = .notConfigured
    /// The real, authoritative RevenueCat Pro entitlement:
    /// `customerInfo.entitlements["pro"]?.isActive == true`. `SubscriptionManager.isPro` reads
    /// this directly (Internal/Debug may still layer the Developer Override on top).
    private(set) var revenueCatIsPro: Bool = false
    private(set) var customerInfoLastUpdatedAt: Date?
    private(set) var maskedAppUserID: String?
    private(set) var packageAvailability: PackageAvailability = .notLoaded
    /// `true`/`false` once a `pro` entitlement record has been seen (active or not — RevenueCat
    /// still reports sandbox-vs-production for an expired/inactive entitlement); `nil` if no
    /// entitlement record has ever been observed. Diagnostics-only.
    private(set) var isSandboxEnvironment: Bool?
    private(set) var lastErrorDescription: String?

    var isConfigured: Bool { configurationState == .configured }

    /// The resolved, validated monthly package — non-nil only once `packageAvailability` is
    /// `.ready`. This is what `SubscriptionManager.purchasePro()` passes to `purchase(_:)`.
    var monthlyPackage: Package? {
        if case .ready(let package) = packageAvailability { return package }
        return nil
    }

    // MARK: - Private

    private let client: RevenueCatClient
    private var customerInfoObservationTask: Task<Void, Never>?

    /// `client` is injectable for testing (see this type's header); production code always uses
    /// the default `LiveRevenueCatClient()` via `.shared`.
    init(client: RevenueCatClient = LiveRevenueCatClient()) {
        self.client = client
    }

    // MARK: - Configuration

    /// Idempotent — safe to call once from app startup. Does nothing (stays `.notConfigured`,
    /// logs in DEBUG/INTERNAL_BUILD only) if no public SDK key is configured.
    func configureIfNeeded() async {
        guard configurationState == .notConfigured else { return }

        guard let apiKey = RevenueCatConfiguration.publicSDKKey else {
            #if DEBUG || INTERNAL_BUILD
            print("[85Blends][RevenueCat] Not configured: SDK key not configured.")
            #endif
            return
        }

        #if DEBUG || INTERNAL_BUILD
        Purchases.logLevel = .debug
        #endif

        // RevenueCat now owns the purchase lifecycle end to end — this is the one load-bearing
        // configuration line in this whole file. Apple/StoreKit still performs the underlying
        // App Store transaction; RevenueCat is the layer that initiates and finishes it.
        let configuration = Configuration.Builder(withAPIKey: apiKey)
            .with(purchasesAreCompletedBy: .revenueCat, storeKitVersion: .storeKit2)
            .build()
        Purchases.configure(with: configuration)

        configurationState = .configured
        maskedAppUserID = Self.maskedAppUserID(from: Purchases.shared.appUserID)
        startObservingCustomerInfo()

        async let customerInfoLoad: Void = refreshCustomerInfoNow()
        async let offeringsLoad: Void = loadOfferings()
        _ = await (customerInfoLoad, offeringsLoad)
    }

    // MARK: - CustomerInfo observation

    /// Reactive entitlement updates (Phase 16): renewals, expirations, refunds/revocations, and
    /// restores observed elsewhere all flow through this stream without requiring a relaunch.
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
        let entitlement = customerInfo.entitlements[Self.proEntitlementID]
        revenueCatIsPro = Self.isProEntitlementActive(entitlementIsActive: entitlement?.isActive)
        isSandboxEnvironment = entitlement?.isSandbox
        customerInfoLastUpdatedAt = Date()
        maskedAppUserID = Self.maskedAppUserID(from: Purchases.shared.appUserID)
        print("[85Blends][RevenueCat] CustomerInfo applied: pro=\(revenueCatIsPro)")
    }

    /// Manual refresh — re-fetches CustomerInfo and nothing else. Used by the Internal/Debug
    /// diagnostics card and on scenePhase → .active (see EightyFiveBlendsApp.swift). RevenueCat's
    /// own CustomerInfo cache means this does not necessarily hit the network on every call.
    func refreshCustomerInfoNow() async {
        guard configurationState == .configured else { return }
        do {
            let customerInfo = try await client.fetchCustomerInfo()
            apply(customerInfo)
        } catch {
            lastErrorDescription = error.localizedDescription
            // Deliberately does not touch revenueCatIsPro — see
            // `revenueCatIsProAfterFailedRefresh(previousValue:)` below: a transient refresh
            // failure must never clear a previously-established entitlement.
            revenueCatIsPro = Self.revenueCatIsProAfterFailedRefresh(previousValue: revenueCatIsPro)
        }
    }

    // MARK: - Offering / package loading

    /// Resolves the `default` offering's `$rc_monthly` package and validates it maps to
    /// `com.85blends.subscription.monthly` before it is ever eligible to purchase. Safe to call
    /// repeatedly (e.g. every paywall presentation, for freshness).
    func loadOfferings() async {
        guard configurationState == .configured else { return }
        guard packageAvailability != .loading else { return }
        packageAvailability = .loading
        do {
            let offerings = try await client.fetchOfferings()
            let offering = offerings.offering(identifier: Self.offeringID) ?? offerings.current
            let monthlyPackage = offering?.monthly
            let resolution = Self.resolvePackage(
                offeringExists: offering != nil,
                monthlyPackageExists: monthlyPackage != nil,
                packageProductID: monthlyPackage?.storeProduct.productIdentifier,
                expectedProductID: SubscriptionManager.monthlyID
            )
            switch resolution {
            case .ready:
                packageAvailability = .ready(monthlyPackage!)
                lastErrorDescription = nil
            case .offeringUnavailable:
                packageAvailability = .offeringUnavailable
                lastErrorDescription = "RevenueCat offering \"\(Self.offeringID)\" is unavailable."
            case .packageUnavailable:
                packageAvailability = .packageUnavailable
                lastErrorDescription = "RevenueCat monthly package is unavailable in the \"\(Self.offeringID)\" offering."
            case .unexpectedProduct(let productID):
                packageAvailability = .unexpectedProduct(productID)
                lastErrorDescription = "RevenueCat monthly package maps to unexpected product \"\(productID)\" (expected \(SubscriptionManager.monthlyID)) — refusing to purchase."
                #if DEBUG || INTERNAL_BUILD
                print("[85Blends][RevenueCat] \(lastErrorDescription ?? "")")
                #endif
            }
        } catch {
            packageAvailability = .offeringUnavailable
            lastErrorDescription = error.localizedDescription
        }
    }

    // MARK: - Purchase

    /// Purchases the given package via RevenueCat. Entitlement is derived strictly from the
    /// returned CustomerInfo — a non-throwing result never implies Pro on its own (Phase 12).
    func purchase(_ package: Package) async -> PurchaseOutcome {
        do {
            let result = try await client.purchase(package: package)
            apply(result.customerInfo)
            return Self.purchaseOutcome(
                userCancelled: result.userCancelled,
                isProEntitlementActiveAfterPurchase: revenueCatIsPro
            )
        } catch {
            lastErrorDescription = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Restore

    /// Restores purchases via RevenueCat. Returns whether `pro` is active in the returned
    /// CustomerInfo — never assumed true just because the call didn't throw.
    func restore() async -> Result<Bool, String> {
        do {
            let customerInfo = try await client.restorePurchases()
            apply(customerInfo)
            return .success(revenueCatIsPro)
        } catch {
            lastErrorDescription = error.localizedDescription
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Pure decision logic (unit-testable — see SubscriptionManagerTests.swift)

    /// Mirrors `customerInfo.entitlements["pro"]?.isActive == true` exactly, but operates on the
    /// already-extracted optional Bool so it can be unit-tested without constructing a real
    /// RevenueCat `CustomerInfo`/`EntitlementInfo`.
    static func isProEntitlementActive(entitlementIsActive: Bool?) -> Bool {
        entitlementIsActive == true
    }

    static func purchaseOutcome(userCancelled: Bool, isProEntitlementActiveAfterPurchase: Bool) -> PurchaseOutcome {
        if userCancelled { return .cancelled }
        return isProEntitlementActiveAfterPurchase ? .proActivated : .notEntitled
    }

    enum PackageResolution: Equatable {
        case ready
        case offeringUnavailable
        case packageUnavailable
        case unexpectedProduct(String)
    }

    static func resolvePackage(
        offeringExists: Bool,
        monthlyPackageExists: Bool,
        packageProductID: String?,
        expectedProductID: String
    ) -> PackageResolution {
        guard offeringExists else { return .offeringUnavailable }
        guard monthlyPackageExists, let packageProductID else { return .packageUnavailable }
        guard packageProductID == expectedProductID else { return .unexpectedProduct(packageProductID) }
        return .ready
    }

    /// A refresh failure must never clear a previously-established entitlement — RevenueCat's own
    /// CustomerInfo cache is the fallback, not a hand-rolled one. This is intentionally a no-op
    /// (returns `previousValue` unchanged); it exists as a named, tested seam documenting that
    /// contract rather than leaving it as an implicit property of `refreshCustomerInfoNow()`'s
    /// catch block.
    static func revenueCatIsProAfterFailedRefresh(previousValue: Bool) -> Bool {
        previousValue
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
