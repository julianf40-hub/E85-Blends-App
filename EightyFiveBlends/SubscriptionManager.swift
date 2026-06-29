//
//  SubscriptionManager.swift
//  EightyFiveBlends
//

import StoreKit
import Observation

/// Single source of truth for 85Blends Pro entitlement state.
///
/// 85Blends Pro is one auto-renewing subscription:
///   • 85Blends Pro — $3.99 / month (no free trial)
///
/// Every Pro gate in the app reads the `isProUser` / `canAccess…` properties below,
/// all of which route through `isPro` — so there is exactly one place that decides
/// whether a user has Pro.
@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    // MARK: - Product identifier
    /// The one and only 85Blends Pro offering.
    static let monthlyID = "com.85blends.subscription.monthly"
    static let allProductIDs: Set<String> = [monthlyID]

    /// Marketing price shown before StoreKit products load (or in builds without a
    /// StoreKit configuration). Once the product loads we always prefer its localized price.
    static let fallbackDisplayPrice = "$3.99"

    // MARK: - Free-tier soft limits (non-blocking nudges only — they never block free features)
    static let freeVehicleLimit      = 2
    static let freeFuelLogLimit      = 25
    static let freeSavedStationLimit = 10

    // MARK: - Debug override (DEBUG / INTERNAL_BUILD only — compiled out of App Store release)
    #if DEBUG || INTERNAL_BUILD
    enum DebugProOverride: String, CaseIterable {
        case off       = "Off"
        case forceFree = "Force Free"
        case forcePro  = "Force Pro"
    }

    /// UserDefaults key for the persisted internal/dev Pro override. This lives in the
    /// internal app's own defaults domain (the Internal build has a distinct bundle ID),
    /// so it can never reach production — production doesn't compile this code at all.
    private static let debugProOverrideKey = "internal.debugProOverride"

    /// Manual Pro override for Developer/Internal builds. Persisted across launches so a
    /// forced state survives force-quit / relaunch; loaded in `init` and written on change.
    var debugProOverride: DebugProOverride = .off {
        didSet {
            UserDefaults.standard.set(debugProOverride.rawValue, forKey: Self.debugProOverrideKey)
            logEntitlementState("override changed")
        }
    }

    /// Human-readable entitlement breakdown for internal diagnostics.
    var debugEntitlementStatus: String {
        "StoreKit=\(isProStoreKit) | override=\(debugProOverride.rawValue) | effectivePro=\(isPro)"
    }

    private func logEntitlementState(_ context: String) {
        print("[85Blends][entitlement] \(context): \(debugEntitlementStatus)")
    }
    #endif

    // MARK: - Observable state

    /// Raw StoreKit-verified Pro status. Use `isPro` / `isProUser` / the `canAccess…` flags for UI logic.
    private(set) var isProStoreKit: Bool = false
    private(set) var availableProducts: [Product] = []
    private(set) var isLoadingProducts: Bool = false
    /// Set to `true` after the first `loadProducts()` call completes (success or failure).
    /// The paywall uses this to distinguish "still loading" from "load failed" so it never
    /// shows the error message before any fetch has actually been attempted.
    private(set) var hasAttemptedProductLoad: Bool = false

    // MARK: - Entitlement (single source of truth)

    /// Whether the user currently has 85Blends Pro.
    /// Defaults to `false` in production and only becomes `true` via a verified StoreKit
    /// entitlement. The debug override is the only other path, and it is compiled out of
    /// App Store release builds entirely.
    var isPro: Bool {
        #if DEBUG || INTERNAL_BUILD
        switch debugProOverride {
        case .forcePro:  return true
        case .forceFree: return false
        case .off:       return isProStoreKit
        }
        #else
        return isProStoreKit
        #endif
    }

    /// Public-facing alias used by feature code and views.
    var isProUser: Bool { isPro }

    // MARK: - Feature access (all derived from `isPro`)
    var canAccessTripPlanner: Bool       { isPro }
    var canAccessAdvancedAnalytics: Bool { isPro }
    var canAccessStationAlerts: Bool     { isPro }
    var canAccessUnlimitedVehicles: Bool { isPro }
    var canAccessCloudSync: Bool         { isPro }

    /// The 85Blends Pro monthly product once loaded from StoreKit, if available.
    var monthlyProduct: Product? {
        availableProducts.first { $0.id == Self.monthlyID }
    }

    /// Localized price for display, falling back to the marketing price before products load.
    var displayPrice: String {
        monthlyProduct?.displayPrice ?? Self.fallbackDisplayPrice
    }

    /// Whether a real StoreKit product is loaded and can actually be purchased.
    /// The paywall's primary CTA stays disabled while this is `false`, so there is no
    /// dead button when products haven't loaded (no internet / StoreKit unavailable /
    /// product not yet configured in App Store Connect).
    var canPurchase: Bool {
        monthlyProduct != nil
    }

    enum PurchaseState: Equatable {
        case idle, purchasing, restoring, succeeded
        /// Entitlement re-established via Restore Purchases.
        case restored
        case failed(String)
        /// Neutral, non-error message (e.g. a restore that found nothing to restore).
        case info(String)
    }
    private(set) var purchaseState: PurchaseState = .idle

    // MARK: - Private
    private var transactionListenerTask: Task<Void, Error>?
    private var isRefreshing = false

    private init() {
        #if DEBUG || INTERNAL_BUILD
        // Restore any persisted internal/dev override before entitlement refresh runs, so a
        // forced state survives force-quit / relaunch. (Setting a property in init does not
        // fire its didSet, so this does not redundantly write back to UserDefaults.)
        if let raw = UserDefaults.standard.string(forKey: Self.debugProOverrideKey),
           let saved = DebugProOverride(rawValue: raw) {
            debugProOverride = saved
        }
        #endif
        transactionListenerTask = Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { [weak self] in
            await self?.refreshEntitlements()
            await self?.loadProducts()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Public API

    @MainActor
    func refreshEntitlements() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var hasPro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result,
               Self.allProductIDs.contains(tx.productID) {
                hasPro = true
            }
        }
        isProStoreKit = hasPro
    }

    @MainActor
    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer {
            isLoadingProducts = false
            hasAttemptedProductLoad = true
        }
        do {
            let products = try await Product.products(for: Self.allProductIDs)
            availableProducts = products
            if products.isEmpty {
                // Empty result with no error means the product IDs returned nothing from
                // App Store Connect. Most common causes: the product ID in code doesn't
                // exactly match what's configured in App Store Connect, or the product
                // is not yet in "Ready to Submit" / approved status.
                print("[85Blends][StoreKit] loadProducts: 0 products returned for IDs: \(Self.allProductIDs). Verify the product IDs exactly match App Store Connect and the product status is Ready to Submit or approved.")
            }
        } catch {
            availableProducts = []
            // Log the real error in all builds — this is a critical commerce path and
            // silent failures are what caused the App Review rejection on iPad.
            print("[85Blends][StoreKit] loadProducts failed: \(error.localizedDescription) (code: \(error)). Possible causes: network issue, StoreKit sandbox misconfiguration, missing In-App Purchase entitlement, or product not yet approved in App Store Connect.")
        }
    }

    /// Convenience entry point for the paywall's primary CTA.
    /// Purchases the live `com.85blends.subscription.monthly` product via StoreKit.
    @MainActor
    func purchasePro() async {
        guard let product = monthlyProduct else { return }
        await purchase(product)
    }

    @MainActor
    func purchase(_ product: Product) async {
        // Ignore repeat taps while a purchase or restore is already in flight.
        guard purchaseState != .purchasing, purchaseState != .restoring else { return }
        purchaseState = .purchasing
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
                purchaseState = .succeeded
            case .userCancelled, .pending:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    @MainActor
    func restorePurchases() async {
        // Guard against rapid repeat taps kicking off overlapping restores.
        guard purchaseState != .restoring, purchaseState != .purchasing else { return }
        let wasProBefore = isProStoreKit
        purchaseState = .restoring
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            // AppStore.sync() succeeding doesn't mean the user owns Pro — distinguish a fresh
            // restore from "already active" and from "nothing to restore" so the UI is honest.
            if isProStoreKit {
                purchaseState = wasProBefore ? .info("85Blends Pro is active.") : .restored
            } else {
                purchaseState = .info("No active subscription found.")
            }
        } catch {
            purchaseState = .failed("We couldn't restore your purchases. Please try again.")
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let tx) = result else { return }
        await tx.finish()
        await refreshEntitlements()
    }
}
