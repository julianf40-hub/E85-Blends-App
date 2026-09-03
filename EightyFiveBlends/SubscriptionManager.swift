//
//  SubscriptionManager.swift
//  EightyFiveBlends
//

import Foundation
import Observation
import RevenueCat

/// Single source of truth for 85Blends Pro entitlement state.
///
/// 85Blends Pro is one auto-renewing subscription:
///   • 85Blends Pro — $3.99 / month (no free trial)
///
/// Every Pro gate in the app reads the `isProUser` / `canAccess…` properties below,
/// all of which route through `isPro` — so there is exactly one place that decides
/// whether a user has Pro.
///
/// As of the 85Blends 2.3.0 RevenueCat cutover, `isPro` is derived from
/// `RevenueCatSubscriptionService.shared.revenueCatIsPro` — RevenueCat's own authoritative
/// `CustomerInfo.entitlements["pro"]?.isActive` — not from any direct StoreKit entitlement check.
/// Internal/Debug builds may still layer the Developer Pro Override on top; see `isPro` below.
@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    // MARK: - Product identifier
    /// The one and only 85Blends Pro offering. This is the Apple App Store product ID — RevenueCat
    /// maps it to the `pro` entitlement via the `default` offering's `$rc_monthly` package. See
    /// RevenueCatSubscriptionService.resolvePackage(...), which refuses to purchase anything that
    /// doesn't resolve to this exact ID.
    static let monthlyID = "com.85blends.subscription.monthly"

    /// Marketing price shown before the RevenueCat package loads (or if it never does). Once the
    /// package loads we always prefer its localized price.
    static let fallbackDisplayPrice = "$3.99"

    // MARK: - Free-tier creation limit (blocking)
    /// Vehicles a Free user may create. Pro is unlimited — see `canAccessUnlimitedVehicles`
    /// below. Unlike the soft limits directly below, this one is actually enforced at every
    /// vehicle-creation entry point (see VehicleCreationPolicy) — it blocks creating another
    /// vehicle once reached, though it never touches vehicles a user already has (grandfathered
    /// vehicles above this count — e.g. from a downgrade, or synced in via CloudKit from a
    /// formerly-Pro device — remain fully visible, editable, and usable; only new creation stops).
    static let freeVehicleLimit = 1

    // MARK: - Free-tier soft limits (non-blocking nudges only — they never block free features)
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
        "RevenueCat=\(RevenueCatSubscriptionService.shared.revenueCatIsPro) | override=\(debugProOverride.rawValue) | effectivePro=\(isPro)"
    }

    private func logEntitlementState(_ context: String) {
        print("[85Blends][entitlement] \(context): \(debugEntitlementStatus)")
    }

    /// Whether a Developer Pro Override is currently forcing state away from RevenueCat's real
    /// entitlement (`.forcePro` or `.forceFree`) — `false` only when the override is `.off`.
    /// Exists so call sites (PreferencesView's stale-override warning/reset UI) don't need to
    /// compare against `.off` inline, and so "is an override active right now" reads as one
    /// intentional question rather than an ad-hoc comparison repeated at each call site.
    var isDebugProOverrideActive: Bool { debugProOverride != .off }

    /// Clears the Developer Pro Override back to `.off`, so `isPro` immediately falls back to
    /// RevenueCat's real entitlement. Reuses `debugProOverride`'s existing `didSet` (UserDefaults
    /// persistence + `logEntitlementState` diagnostic log) — no new storage path, no change to
    /// `effectivePro(override:revenueCatIsPro:)`'s precedence rule. This is the "safe reset"
    /// entry point: a lingering `.forcePro`/`.forceFree` from an earlier test session survives
    /// force-quit/relaunch and even switching to a different RevenueCat sandbox account (it's
    /// local device state, not tied to any RevenueCat identity) — this gives internal testers an
    /// explicit, one-call way to clear it rather than relying on remembering to flip the Picker
    /// back to "Off" themselves.
    func resetDebugProOverride() {
        debugProOverride = .off
    }
    #endif

    // MARK: - Entitlement (single source of truth)

    /// Whether the user currently has 85Blends Pro.
    ///
    /// Production: derived exclusively from RevenueCat's authoritative CustomerInfo entitlement
    /// (`RevenueCatSubscriptionService.shared.revenueCatIsPro`). Internal/Debug builds may
    /// additionally force this via the Developer Pro Override, which is compiled out of App
    /// Store release builds entirely — see `effectivePro(override:revenueCatIsPro:)` below for
    /// the actual (unit-tested) precedence rule.
    var isPro: Bool {
        #if DEBUG || INTERNAL_BUILD
        Self.effectivePro(override: debugProOverride, revenueCatIsPro: RevenueCatSubscriptionService.shared.revenueCatIsPro)
        #else
        RevenueCatSubscriptionService.shared.revenueCatIsPro
        #endif
    }

    #if DEBUG || INTERNAL_BUILD
    /// Pure override-precedence rule: Force Pro always wins, Force Free always wins, Off follows
    /// RevenueCat exactly. Extracted out of `isPro` so this precedence can be unit-tested with
    /// plain values instead of mutating the live RevenueCatSubscriptionService singleton — see
    /// SubscriptionManagerTests.swift. This entire function is compiled out of App Store Release
    /// builds along with the rest of the Developer Override (`#if DEBUG || INTERNAL_BUILD`), so
    /// it can never affect production semantics.
    static func effectivePro(override: DebugProOverride, revenueCatIsPro: Bool) -> Bool {
        switch override {
        case .forcePro:  return true
        case .forceFree: return false
        case .off:       return revenueCatIsPro
        }
    }
    #endif

    /// Public-facing alias used by feature code and views.
    var isProUser: Bool { isPro }

    /// 85Blends 2.3.2 — true only until this process's first-ever authoritative RevenueCat
    /// CustomerInfo answer arrives (or is determined unreachable). A presentation that gates on
    /// `isProUser` alone cannot tell "not yet resolved" apart from "resolved to Free," since both
    /// read as `false` — this is the separate question feature code should check first, before
    /// ever treating an unresolved entitlement as Free. Never itself an entitlement signal: it
    /// says nothing about whether the user is Pro, only whether that answer has arrived yet. See
    /// RevenueCatSubscriptionService.isInitialEntitlementResolutionPending's own header for the
    /// full rationale and forward-only lifecycle. Deliberately NOT gated behind the Developer Pro
    /// Override (unlike `isPro` above) — the override forces an entitlement value, it does not
    /// change whether RevenueCat itself has answered yet.
    var isInitialEntitlementResolutionPending: Bool {
        RevenueCatSubscriptionService.shared.isInitialEntitlementResolutionPending
    }

    // MARK: - Feature access (all derived from `isPro`)
    var canAccessTripPlanner: Bool       { isPro }
    var canAccessAdvancedAnalytics: Bool { isPro }
    var canAccessStationAlerts: Bool     { isPro }
    var canAccessUnlimitedVehicles: Bool { isPro }

    // MARK: - Package / price (sourced from RevenueCat — see RevenueCatSubscriptionService)

    /// The RevenueCat-resolved, validated monthly package's underlying store product, once
    /// loaded. `nil` while loading, on failure, or if RevenueCat's mapping didn't match
    /// `Self.monthlyID` (see RevenueCatSubscriptionService.resolvePackage).
    var monthlyStoreProduct: StoreProduct? {
        RevenueCatSubscriptionService.shared.monthlyPackage?.storeProduct
    }

    /// Localized price for display, falling back to the marketing price before the package loads.
    var displayPrice: String {
        monthlyStoreProduct?.localizedPriceString ?? Self.fallbackDisplayPrice
    }

    /// Whether a real, validated RevenueCat package is loaded and can actually be purchased.
    /// The paywall's primary CTA stays disabled while this is `false`, so there is no dead
    /// button when nothing has loaded (no internet / RevenueCat unavailable / offering
    /// misconfigured).
    var canPurchase: Bool {
        monthlyStoreProduct != nil
    }

    /// Mirrors RevenueCatSubscriptionService.packageAvailability's `.loading` state.
    var isLoadingProducts: Bool {
        RevenueCatSubscriptionService.shared.packageAvailability == .loading
    }

    /// `true` once the first `loadProducts()` has completed (success or failure) — i.e. package
    /// availability is no longer `.notLoaded`/`.loading`. The paywall uses this to distinguish
    /// "still loading" from "load failed" so it never shows the error message before any fetch
    /// has actually been attempted.
    var hasAttemptedProductLoad: Bool {
        switch RevenueCatSubscriptionService.shared.packageAvailability {
        case .notLoaded, .loading: return false
        default: return true
        }
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
        // RevenueCat configuration + the initial CustomerInfo/offerings load happen once from
        // app startup (see EightyFiveBlendsApp.swift's launch `.task`), not here — see Phase 15
        // of the RevenueCat cutover task for why an explicit app-lifecycle hook is preferred over
        // a side effect in this singleton's lazy init.
    }

    // MARK: - Public API

    /// Loads (or re-fetches, for freshness) the RevenueCat offering/package used by the paywall.
    @MainActor
    func loadProducts() async {
        await RevenueCatSubscriptionService.shared.loadOfferings()
    }

    /// Convenience entry point for the paywall's primary CTA.
    /// Purchases the live `com.85blends.subscription.monthly` product via RevenueCat.
    @MainActor
    func purchasePro() async {
        guard let package = RevenueCatSubscriptionService.shared.monthlyPackage else {
            // The paywall's unlockButton is already disabled whenever canPurchase is false, so
            // this guard should be unreachable from a real tap — but log it in case it's ever
            // hit anyway (e.g. a future call site that doesn't check canPurchase first), so a
            // "tap did nothing" report is never a total dead end in the console.
            print("[85Blends][RevenueCat] Purchase requested but no package is loaded — ignoring tap (canPurchase=false).")
            return
        }
        await purchase(package)
    }

    @MainActor
    func purchase(_ package: Package) async {
        // Ignore repeat taps while a purchase or restore is already in flight.
        guard purchaseState != .purchasing, purchaseState != .restoring else { return }
        purchaseState = .purchasing
        print("[85Blends][RevenueCat] Purchase requested: \(package.storeProduct.productIdentifier)")

        let outcome = await RevenueCatSubscriptionService.shared.purchase(package)
        print("[85Blends][RevenueCat] Purchase outcome: \(outcome)")
        purchaseState = Self.state(forPurchaseOutcome: outcome)
    }

    @MainActor
    func restorePurchases() async {
        // Guard against rapid repeat taps kicking off overlapping restores.
        guard purchaseState != .restoring, purchaseState != .purchasing else { return }
        // The raw RevenueCat entitlement, not `isPro` — a Developer Force Pro/Force Free override
        // must never distort restore messaging (e.g. reporting "restored" when Force Pro was
        // already masking a Free RevenueCat account).
        let wasProBefore = RevenueCatSubscriptionService.shared.revenueCatIsPro
        purchaseState = .restoring
        print("[85Blends][RevenueCat] Restore requested")

        let outcome = await RevenueCatSubscriptionService.shared.restore()
        print("[85Blends][RevenueCat] Restore outcome: \(outcome)")
        purchaseState = Self.state(forRestoreOutcome: outcome, wasProBefore: wasProBefore)
    }

    // MARK: - Pure state-transition logic (unit-testable — see SubscriptionManagerTests.swift)
    //
    // Named `state(for...:)`, not `purchaseState(for...:)` — these are `static func`s on the same
    // type as the `purchaseState` instance property above, and a same-named static function
    // caused Xcode to resolve `Self.purchaseState(...)` against the instance property instead of
    // the function ("Cannot call value of non-function type 'SubscriptionManager.PurchaseState'").

    /// Maps a RevenueCat purchase outcome to the user-visible `PurchaseState`. Extracted out of
    /// `purchase(_:)` so Phase 25's purchase-outcome test cases can run without driving a real
    /// RevenueCat purchase call. `.notEntitled` (purchase didn't throw, but CustomerInfo shows no
    /// active `pro`) is deliberately mapped to `.failed`, never `.succeeded` — a non-throwing
    /// result must never be conflated with granting Pro.
    static func state(forPurchaseOutcome outcome: RevenueCatSubscriptionService.PurchaseOutcome) -> PurchaseState {
        switch outcome {
        case .proActivated:
            return .succeeded
        case .notEntitled:
            // 2.3.2 release-readiness correction: names the actual, real support address
            // directly in the message itself (support@85blends.app — see MoreView's "Contact
            // Support" row for the same address), rather than a bare "contact support" with no
            // way to act on it from this specific alert.
            return .failed("We couldn't verify your purchase. Please try again or contact support@85blends.app.")
        case .cancelled:
            return .idle
        case .failed(let message):
            return .failed(message)
        }
    }

    /// Maps a RevenueCat restore outcome to the user-visible `PurchaseState`, distinguishing a
    /// fresh restore from "already active" and from "nothing to restore" so the UI is honest —
    /// see Phase 25's restore test cases.
    static func state(forRestoreOutcome outcome: RevenueCatSubscriptionService.RestoreOutcome, wasProBefore: Bool) -> PurchaseState {
        switch outcome {
        case .proActive:
            return wasProBefore ? .info("85Blends Pro is active.") : .restored
        case .noActivePro:
            return .info("No active subscription found.")
        case .failed:
            return .failed("We couldn't restore your purchases. Please try again.")
        }
    }
}
