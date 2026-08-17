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

    // MARK: - Temporary purchase diagnostic (TestFlight investigation aid)
    //
    // `purchaseState` alone can't say WHY a purchase attempt ended — `.userCancelled` and
    // `.pending` both collapse to `.idle`, indistinguishable on screen from "nothing happened."
    // The person validating this build doesn't have Xcode/console access, so this captures the
    // literal StoreKit outcome (result case, or thrown error type/description — never receipt
    // or transaction payload data) directly on the device. Set only from the purchase() call
    // this manager itself drives — never from the background Transaction.updates listener or
    // from refreshEntitlements(), so it can't be silently overwritten by unrelated concurrent
    // StoreKit activity while the user is trying to read it.
    //
    // TEMPORARY: remove once the split-second "Processing your purchase…" → back-to-normal
    // TestFlight regression is root-caused and fixed. Not intended to ship long-term.
    private(set) var lastPurchaseDiagnostic: String?

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
        // Always-on (not #if DEBUG-gated), matching the loadProducts() precedent below: this is
        // a critical commerce path and a future TestFlight validation needs this in the device
        // console regardless of build configuration. No receipt/transaction payload is logged.
        print("[85Blends][StoreKit] Entitlement refreshed: isPro=\(hasPro)")
    }

    @MainActor
    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer {
            isLoadingProducts = false
            hasAttemptedProductLoad = true
        }
        print("[85Blends][StoreKit] Loading products… requested IDs: \(Self.allProductIDs)")
        do {
            let products = try await Product.products(for: Self.allProductIDs)
            availableProducts = products
            print("[85Blends][StoreKit] Products returned: \(products.count)")
            if products.isEmpty {
                // Empty result with no error means the product IDs returned nothing from
                // App Store Connect. Most common causes: the product ID in code doesn't
                // exactly match what's configured in App Store Connect, or the product
                // is not yet in "Ready to Submit" / approved status.
                print("[85Blends][StoreKit] loadProducts: 0 products returned for IDs: \(Self.allProductIDs). Verify the product IDs exactly match App Store Connect and the product status is Ready to Submit or approved.")
            } else {
                for product in products {
                    print("[85Blends][StoreKit] Loaded product: \(product.id) — \(product.displayName) — \(product.displayPrice)")
                }
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
        guard let product = monthlyProduct else {
            // The paywall's unlockButton is already disabled whenever canPurchase is false, so
            // this guard should be unreachable from a real tap — but log it in case it's ever
            // hit anyway (e.g. a future call site that doesn't check canPurchase first), so a
            // "tap did nothing" report is never a total dead end in the console.
            print("[85Blends][StoreKit] Purchase requested but no product is loaded — ignoring tap (canPurchase=false).")
            return
        }
        await purchase(product)
    }

    @MainActor
    func purchase(_ product: Product) async {
        // Ignore repeat taps while a purchase or restore is already in flight.
        guard purchaseState != .purchasing, purchaseState != .restoring else { return }
        purchaseState = .purchasing
        // Clear the previous attempt's diagnostic the moment a new attempt begins, so a stale
        // result from an earlier tap is never misread as describing this one.
        lastPurchaseDiagnostic = nil
        print("[85Blends][StoreKit] Purchase requested: \(product.id)")
        do {
            switch try await product.purchase() {
            case .success(let verification):
                print("[85Blends][StoreKit] Purchase result: success")
                let verified = await handle(verification)
                if verified {
                    purchaseState = .succeeded
                    lastPurchaseDiagnostic = "Purchase result: success (transaction verified)"
                } else {
                    // The purchase completed but the transaction failed verification — this
                    // must never be reported as success (handle() already refused to grant
                    // entitlement in this case; previously purchaseState was set to .succeeded
                    // here unconditionally regardless of verification outcome, which could show
                    // a false "success" UI state even when Pro was never actually granted).
                    print("[85Blends][StoreKit] Purchase result: success, but transaction verification failed")
                    purchaseState = .failed("We couldn't verify your purchase. Please try again or contact support.")
                    lastPurchaseDiagnostic = "StoreKit result: success, but transaction verification failed"
                }
            case .userCancelled:
                print("[85Blends][StoreKit] Purchase result: userCancelled")
                purchaseState = .idle
                lastPurchaseDiagnostic = "StoreKit result: userCancelled"
            case .pending:
                print("[85Blends][StoreKit] Purchase result: pending")
                purchaseState = .idle
                lastPurchaseDiagnostic = "StoreKit result: pending (e.g. Ask to Buy approval required)"
            @unknown default:
                print("[85Blends][StoreKit] Purchase result: unrecognized result case")
                purchaseState = .idle
                lastPurchaseDiagnostic = "StoreKit result: unrecognized case (@unknown default)"
            }
        } catch {
            // Previously this error only ever reached purchaseState (UI-only) and never the
            // console — a real TestFlight device log had no way to see it. Now logged (and
            // surfaced on-screen) in all builds, matching the loadProducts() precedent above.
            let description = errorDiagnosticDescription(error)
            print("[85Blends][StoreKit] Purchase error type: \(type(of: error))")
            print("[85Blends][StoreKit] Purchase error: \(description)")
            purchaseState = .failed(error.localizedDescription)
            lastPurchaseDiagnostic = "StoreKit error: \(description)"
        }
    }

    @MainActor
    func restorePurchases() async {
        // Guard against rapid repeat taps kicking off overlapping restores.
        guard purchaseState != .restoring, purchaseState != .purchasing else { return }
        let wasProBefore = isProStoreKit
        purchaseState = .restoring
        print("[85Blends][StoreKit] Restore requested")
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            // AppStore.sync() succeeding doesn't mean the user owns Pro — distinguish a fresh
            // restore from "already active" and from "nothing to restore" so the UI is honest.
            if isProStoreKit {
                purchaseState = wasProBefore ? .info("85Blends Pro is active.") : .restored
                print("[85Blends][StoreKit] Restore result: \(wasProBefore ? "already active" : "restored")")
            } else {
                purchaseState = .info("No active subscription found.")
                print("[85Blends][StoreKit] Restore result: no active subscription found")
            }
        } catch {
            print("[85Blends][StoreKit] Restore failed: \(error.localizedDescription)")
            purchaseState = .failed("We couldn't restore your purchases. Please try again.")
        }
    }

    // MARK: - Private helpers

    /// Compile-safe error categorization for diagnostics only — never throws, never guesses at
    /// enum cases that may not exist in this SDK. Tries StoreKit's two documented `purchase()`
    /// error types (`StoreKitError`, `Product.PurchaseError`) for a readable case name via
    /// `String(describing:)` (which works regardless of the exact case set, so this can't fail
    /// to compile or crash if a future/unlisted case is returned); falls back to the error's own
    /// type name + description for anything else. Deliberately contains no receipt, transaction,
    /// JWS, or Apple ID data — only case names, descriptions, and localized messages.
    private func errorDiagnosticDescription(_ error: Error) -> String {
        if let storeKitError = error as? StoreKitError {
            return "StoreKitError.\(String(describing: storeKitError))"
        }
        if let purchaseError = error as? Product.PurchaseError {
            return "PurchaseError.\(String(describing: purchaseError))"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }

    /// Returns whether the transaction was verified (and, if so, finished + entitlements
    /// refreshed). Callers that need to reflect verification outcome in UI/diagnostic state
    /// (see `purchase(_:)`) use the return value; the background `Transaction.updates` listener
    /// in `init` ignores it (`@discardableResult`) since it has no UI state to update.
    @MainActor
    @discardableResult
    private func handle(_ result: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let tx) = result else {
            // Previously silent — an unverified transaction was dropped with zero trace. This
            // doesn't change behavior (an unverified transaction must never grant entitlement),
            // it just makes that correct-but-silent path visible in a device log.
            print("[85Blends][StoreKit] Transaction verification failed — ignoring unverified transaction.")
            return false
        }
        print("[85Blends][StoreKit] Transaction verified: \(tx.productID)")
        await tx.finish()
        await refreshEntitlements()
        return true
    }
}
