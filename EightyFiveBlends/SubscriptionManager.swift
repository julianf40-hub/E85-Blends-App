//
//  SubscriptionManager.swift
//  EightyFiveBlends
//

import Foundation
import Observation
import RevenueCat

/// Single source of truth for 85Blends Pro entitlement state.
///
/// 85Blends Pro is one entitlement (`pro`), offered as three auto-renewing plans — see
/// ProPlan.swift for identity/pricing metadata:
///   • Monthly — $3.99 / month
///   • 3 Months — $9.99 / 3 months
///   • Annual — $24.99 / year
/// No plan grants a different feature set or a different entitlement — see
/// RevenueCatSubscriptionService's "KEY AUTHORITY INVARIANT."
///
/// Every Pro gate in the app reads the `isProUser` / `canAccess…` properties below,
/// all of which route through `isPro` — so there is exactly one place that decides
/// whether a user has Pro, and it is completely plan-agnostic.
///
/// As of the 85Blends 2.3.0 RevenueCat cutover, `isPro` is derived from
/// `RevenueCatSubscriptionService.shared.revenueCatIsPro` — RevenueCat's own authoritative
/// `CustomerInfo.entitlements["pro"]?.isActive` — not from any direct StoreKit entitlement check.
/// Internal/Debug builds may still layer the Developer Pro Override on top; see `isPro` below.
@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

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

    /// 85Blends 2.4.0 Refer & Earn hardening — a STRONGER signal than
    /// `isInitialEntitlementResolutionPending == false`. That flag only means the first
    /// resolution *attempt* has finished — per `InitialEntitlementResolutionState.resolved`'s own
    /// header, it is deliberately reached on a FAILED first fetch too (and on a missing SDK key),
    /// specifically so Stations never hangs behind an indefinite loading shell. That means
    /// `isInitialEntitlementResolutionPending == false && isProUser == false` alone cannot
    /// distinguish a confirmed-Free result from "the fetch failed and we still don't actually
    /// know." This property answers the narrower, stronger question Refer & Earn actually needs:
    /// has at least one REAL CustomerInfo result been successfully applied this process? Derived
    /// from `RevenueCatSubscriptionService.customerInfoLastUpdatedAt`, which is set only inside
    /// `apply(_:)` — i.e. only by a successful fetch/purchase/restore/stream update, never by a
    /// failed refresh (see that file's own `refreshCustomerInfoNow()` catch block, which
    /// deliberately never touches it). Referral code entry must never be offered — and an
    /// existing Pro subscriber must never be told they're already Pro — on the strength of a
    /// failed fetch; this is the property that lets `ReferralPresentation.entryEligibility`
    /// require a real answer before doing either.
    var hasAuthoritativeProStatus: Bool {
        RevenueCatSubscriptionService.shared.customerInfoLastUpdatedAt != nil
    }

    /// Narrow feature-facing wrapper so Refer & Earn's "Try Again" can re-request CustomerInfo
    /// without reaching into RevenueCatSubscriptionService or Purchases.shared directly from
    /// SwiftUI. Duplicates no entitlement logic of its own — delegates entirely to the existing
    /// `refreshCustomerInfoNow()`, the same manual-refresh path already used by Internal/Debug
    /// diagnostics and the scenePhase → .active handler.
    func refreshProStatus() async {
        await RevenueCatSubscriptionService.shared.refreshCustomerInfoNow()
    }

    /// 85Blends 2.4.0 Referral Reward Redemption — narrow feature-facing wrapper so
    /// ReferralRewardRedemptionSheet's return-from-App-Store path can reconcile RevenueCat after an
    /// EXTERNAL Apple Offer Code redemption without reaching into RevenueCatSubscriptionService
    /// directly from SwiftUI. Delegates entirely to
    /// `RevenueCatSubscriptionService.syncAfterExternalRedemption()` — see that method's own header
    /// for why this calls RevenueCat's `syncPurchases()`, never `restorePurchases()`/
    /// `refreshCustomerInfoNow()`, and why a failed sync is never surfaced as a hard error here.
    @discardableResult
    func syncAfterExternalRedemption() async -> Bool {
        await RevenueCatSubscriptionService.shared.syncAfterExternalRedemption()
    }

    // MARK: - Feature access (all derived from `isPro`)
    var canAccessTripPlanner: Bool       { isPro }
    var canAccessAdvancedAnalytics: Bool { isPro }
    var canAccessStationAlerts: Bool     { isPro }
    var canAccessUnlimitedVehicles: Bool { isPro }
    /// 85Blends 2.4.0 — the Nearby E85 Home Screen widget (all three families) is a Pro feature.
    /// Same plan-agnostic `isPro` as every other gate above. This property is the app-side
    /// authority the widget mirror is derived FROM (see NearbyE85WidgetAccessPublisher) and the
    /// value ContentView's widget deep-link gate reads (see NearbyE85WidgetEntitlementRoute) — the
    /// App-Group value the widget extension itself reads is only ever a copy of this, never a
    /// second source of truth (see SharedNearbyE85/NearbyE85WidgetAccess.swift's header).
    var canAccessNearbyE85Widget: Bool   { isPro }

    // MARK: - Package / price (sourced from RevenueCat — see RevenueCatSubscriptionService)

    /// The RevenueCat-resolved, validated store product for this plan, once loaded. `nil` while
    /// loading, on failure, or if RevenueCat's mapping didn't match this plan's own
    /// `ProPlan.productID` (see RevenueCatSubscriptionService.resolvePackage).
    func storeProduct(for plan: ProPlan) -> StoreProduct? {
        RevenueCatSubscriptionService.shared.package(for: plan)?.storeProduct
    }

    /// Localized price for display, falling back to the plan's own marketing price before its
    /// package loads.
    func displayPrice(for plan: ProPlan) -> String {
        storeProduct(for: plan)?.localizedPriceString ?? plan.fallbackDisplayPrice
    }

    /// Whether a real, validated RevenueCat package is loaded for THIS plan and it can actually
    /// be purchased. The paywall disables selecting/purchasing a plan while this is `false` for
    /// it, so there is no dead button for a plan that hasn't loaded (no internet / RevenueCat
    /// unavailable / that one plan misconfigured) — independent of whether the OTHER two plans
    /// are available.
    func canPurchase(_ plan: ProPlan) -> Bool {
        storeProduct(for: plan) != nil
    }

    /// True when NOT EVEN ONE of the three plans is currently purchasable. This — not any single
    /// plan's own `canPurchase(_:)` — is what should drive the paywall's full load-error/retry
    /// experience; one or two plans being unavailable while at least one still works is handled
    /// per-plan instead (see ProUpgradeView).
    var anyPlanPurchasable: Bool {
        ProPlan.allCases.contains { canPurchase($0) }
    }

    /// 85Blends 2.4.0 RevenueCatUI integration — the raw `default` offering `ProUpgradeView`
    /// passes to `PaywallView(offering:)`, once loaded. `nil` until `loadProducts()` completes at
    /// least once. See `RevenueCatSubscriptionService.defaultOffering`'s own header for why this
    /// is never RevenueCat's own `.current` offering.
    var defaultOffering: Offering? {
        RevenueCatSubscriptionService.shared.defaultOffering
    }

    /// 85Blends 2.4.0 RevenueCatUI integration — true if ANY plan's package resolved to a product
    /// ID that doesn't match its own `ProPlan.productID` (see
    /// `RevenueCatSubscriptionService.resolvePackage(...)`'s own header for why this can only mean
    /// a `default`-offering dashboard misconfiguration — e.g. the retired quarterly product
    /// getting reattached to a plan slot it must never occupy). `canPurchase(_:)` already refused
    /// to let the pre-RevenueCatUI custom paywall sell such a package; `PaywallView(offering:)`
    /// renders directly from the raw `Offering` and has no awareness of this app's own per-plan
    /// product-ID cross-validation, so `ProUpgradeView` checks this BEFORE ever presenting it —
    /// falling back to its own retry UI instead of RevenueCatUI in that case — to preserve the
    /// exact same "never sell the wrong product" guarantee.
    var hasUnexpectedProductInDefaultOffering: Bool {
        ProPlan.allCases.contains { plan in
            if case .unexpectedProduct = RevenueCatSubscriptionService.shared.packageAvailability(for: plan) {
                return true
            }
            return false
        }
    }

    /// True while an offerings load is currently in flight for any plan — all three always load
    /// together in one `RevenueCatSubscriptionService.loadOfferings()` call, so checking one is
    /// equivalent to checking all three.
    var isLoadingProducts: Bool {
        ProPlan.allCases.contains { RevenueCatSubscriptionService.shared.packageAvailability(for: $0) == .loading }
    }

    /// `true` once the first `loadProducts()` has completed (success or failure) for every plan —
    /// i.e. no plan's availability is still `.notLoaded`/`.loading`. The paywall uses this to
    /// distinguish "still loading" from "load failed" so it never shows the error message before
    /// any fetch has actually been attempted.
    var hasAttemptedProductLoad: Bool {
        ProPlan.allCases.allSatisfy { plan in
            switch RevenueCatSubscriptionService.shared.packageAvailability(for: plan) {
            case .notLoaded, .loading: return false
            default: return true
            }
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

    /// The purchase/restore state machine. See `PurchaseFlow`'s own header for the invariants it
    /// enforces (transient `.purchasing`/`.restoring` are never allowed to outlive their cause).
    /// All mutation goes through the intent methods below, never by assigning states directly.
    private(set) var flow = PurchaseFlow()

    /// The user-visible purchase/restore state. Derived from `flow`, so every reader — the
    /// paywall's status row, the Restore button's enabled state, ContentView's review-request
    /// gate — sees exactly what the state machine says.
    var purchaseState: PurchaseState { flow.state }

    /// Pending Restore Purchases result for the paywall to present, or `nil`. Cleared by
    /// `dismissRestoreFeedback()` when the user acknowledges the alert.
    var restoreFeedback: RestoreFeedback? { flow.restoreFeedback }

    /// 85Blends 2.4.0 — true whenever the single 85Blends Pro paywall (`ProUpgradeView`) is
    /// currently on screen, in either presentation style (`.modal` sheet or `.pushed`
    /// NavigationLink). Set/cleared centrally from `ProUpgradeView`'s own onAppear/onDisappear —
    /// see that view's header — so every existing and future paywall call site (currently
    /// `ProFeatureLockView`, `ProLimitBannerView`, `GarageView`, and `MoreView`) reports this
    /// automatically with no per-call-site wiring. Read-only outside this file. Exists purely as
    /// a presentation signal for the App Store review-request system (see
    /// ReviewRequestManager/ContentView) to avoid ever prompting for a review while the paywall
    /// is visible — it has no effect on entitlement, purchasing, or the paywall itself.
    var isPaywallPresented: Bool { paywallPresentationCount > 0 }

    /// How many `ProUpgradeView` instances are currently on screen — normally 0 or 1, but a
    /// second paywall can be presented over the first (e.g. a widget deep-link paywall sheet over
    /// the pushed More → 85Blends Pro screen). A plain Bool let the upper instance's disappearance
    /// report "no paywall" while the lower one was still showing, which would also have cleared the
    /// lower one's pending purchase/restore state and result alert.
    private var paywallPresentationCount = 0

    /// Called only by `ProUpgradeView`. Not private so that view (a separate file) can call it,
    /// but deliberately not part of the "Public API" section below — this is presentation
    /// bookkeeping, not an entitlement or purchasing action.
    func setPaywallPresented(_ presented: Bool) {
        paywallPresentationCount = presented ? paywallPresentationCount + 1 : max(0, paywallPresentationCount - 1)
        if paywallPresentationCount == 0 {
            // The paywall's callbacks (`.onPurchaseStarted`/`.onPurchaseCompleted`/…) live on its
            // view tree, so once it is gone nothing is left to ever clear a pending transient
            // state — it would otherwise outlive the screen for the rest of the session. This
            // claims NO outcome: StoreKit/RevenueCat own any in-flight transaction independently
            // of this view, and its result still arrives through the authoritative CustomerInfo
            // path (`RevenueCatSubscriptionService.apply(_:)` → `entitlementApplied(…)` below).
            flow.paywallDismissed()
        }
    }

    // MARK: - RevenueCatUI paywall callbacks (called only by `ProUpgradeView`)
    //
    // 85Blends 2.4.0 RevenueCatUI integration — whenever RevenueCatUI's hosted paywall performs a
    // purchase or restore directly (see that view's header), `ProUpgradeView` reports it through
    // these intent methods, which apply the exact same state transitions `purchase(_:)`/
    // `restorePurchases()` below produce when this type drives the RevenueCat call itself — via
    // the same `state(forPurchaseOutcome:)`/`state(forRestoreOutcome:wasProBefore:)` pure
    // mappings — so `purchaseState`/`isPurchaseActive` (see ContentView's review-request gate)
    // stays meaningful regardless of which call path actually performed the purchase. Not part of
    // the "Public API" section below: this is presentation/outcome bookkeeping, never itself an
    // entitlement or purchasing action.
    //
    // RevenueCatUI delivers these callbacks via SwiftUI preference changes on `PaywallView`, which
    // are LOST if the entitlement flips and `ProUpgradeView` swaps `PaywallView` out first — so
    // none of them is the only thing that can end a transient state; see `entitlementApplied`.

    func paywallPurchaseStarted() {
        // A purchase cannot genuinely be starting while RevenueCat already reports Pro (the paywall
        // is not shown to a Pro user); ignoring it keeps a late/duplicate "started" signal from
        // re-arming `.purchasing` over an active entitlement.
        guard RevenueCatSubscriptionService.shared.revenueCatIsPro == false else { return }
        flow.purchaseStarted()
    }

    func paywallPurchaseFinished(_ outcome: RevenueCatSubscriptionService.PurchaseOutcome) {
        flow.purchaseFinished(state: Self.state(forPurchaseOutcome: outcome))
    }

    func paywallRestoreStarted() {
        // The raw RevenueCat entitlement, not `isPro` — a Developer Force Pro/Force Free override
        // must never distort restore messaging (e.g. reporting "restored" when Force Pro was
        // already masking a Free RevenueCat account).
        flow.restoreStarted(wasProBefore: RevenueCatSubscriptionService.shared.revenueCatIsPro)
    }

    func paywallRestoreFinished(_ outcome: RevenueCatSubscriptionService.RestoreOutcome) {
        flow.restoreFinished(
            state: Self.state(forRestoreOutcome: outcome, wasProBefore: flow.restoreWasProBefore),
            feedback: Self.restoreFeedback(for: outcome),
            viaPaywallCallback: true,
            paywallPresented: isPaywallPresented
        )
    }

    /// The user acknowledged the restore-result alert.
    func dismissRestoreFeedback() {
        flow.dismissRestoreFeedback()
    }

    /// Called by `RevenueCatSubscriptionService.apply(_:)` after EVERY authoritative CustomerInfo
    /// it applies — a purchase, a restore, a refresh, or a `customerInfoStream` emission alike —
    /// with the RAW RevenueCat Pro entitlement (`revenueCatIsPro`), deliberately never `isPro`:
    /// the Developer Pro Override can force `isPro` without any purchase having happened and must
    /// never be mistaken for one. This is the one place that guarantees an active authoritative
    /// entitlement can never coexist with a stuck `.purchasing`/`.restoring`, independent of
    /// whether the paywall's own callbacks ever arrive.
    func entitlementApplied(revenueCatIsPro: Bool) {
        flow.entitlementApplied(revenueCatIsPro: revenueCatIsPro, paywallPresented: isPaywallPresented)
    }

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
        // Reconcile transient purchase/restore state against every authoritative entitlement
        // update — see `entitlementApplied(revenueCatIsPro:)`.
        RevenueCatSubscriptionService.shared.onEntitlementApplied = { [weak self] revenueCatIsPro in
            self?.entitlementApplied(revenueCatIsPro: revenueCatIsPro)
        }
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

    /// Convenience entry point for the paywall's primary CTA. Purchases exactly the given plan's
    /// live product via RevenueCat — never a fallback to a different plan. See ProPlan.swift for
    /// the three recognized product IDs.
    @MainActor
    func purchasePro(_ plan: ProPlan) async {
        guard let package = RevenueCatSubscriptionService.shared.package(for: plan) else {
            // The paywall's unlockButton is already disabled whenever canPurchase(plan) is false,
            // so this guard should be unreachable from a real tap — but log it in case it's ever
            // hit anyway (e.g. a future call site that doesn't check canPurchase first), so a
            // "tap did nothing" report is never a total dead end in the console.
            print("[85Blends][RevenueCat] Purchase requested for \(plan.rawValue) but no package is loaded — ignoring tap (canPurchase=false).")
            return
        }
        await purchase(package)
    }

    @MainActor
    func purchase(_ package: Package) async {
        // Ignore repeat taps while a purchase or restore is already in flight.
        guard flow.isBusy == false else { return }
        flow.purchaseStarted()
        print("[85Blends][RevenueCat] Purchase requested: \(package.storeProduct.productIdentifier)")

        let outcome = await RevenueCatSubscriptionService.shared.purchase(package)
        print("[85Blends][RevenueCat] Purchase outcome: \(outcome)")
        flow.purchaseFinished(state: Self.state(forPurchaseOutcome: outcome))
    }

    @MainActor
    func restorePurchases() async {
        // Guard against rapid repeat taps kicking off overlapping restores.
        guard flow.isBusy == false else { return }
        // The raw RevenueCat entitlement, not `isPro` — a Developer Force Pro/Force Free override
        // must never distort restore messaging (e.g. reporting "restored" when Force Pro was
        // already masking a Free RevenueCat account).
        let wasProBefore = RevenueCatSubscriptionService.shared.revenueCatIsPro
        flow.restoreStarted(wasProBefore: wasProBefore)
        print("[85Blends][RevenueCat] Restore requested")

        // This call always returns (never throws — failures come back as `.failed`), so unlike the
        // paywall-callback path this one can never strand `.restoring`; whatever the outcome, the
        // user gets a result alert and Restore becomes tappable again.
        let outcome = await RevenueCatSubscriptionService.shared.restore()
        print("[85Blends][RevenueCat] Restore outcome: \(outcome)")
        flow.restoreFinished(
            state: Self.state(forRestoreOutcome: outcome, wasProBefore: wasProBefore),
            feedback: Self.restoreFeedback(for: outcome),
            viaPaywallCallback: false,
            paywallPresented: isPaywallPresented
        )
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
            return PurchaseFlow.stateForActiveRestore(wasProBefore: wasProBefore)
        case .noActivePro:
            return .info("No active subscription found.")
        case .failed:
            return .failed("We couldn't restore your purchases. Please try again.")
        }
    }

    /// Maps a RevenueCat restore outcome to the result alert the paywall presents. An already-Pro
    /// user restoring is still a success here (`.proActive` regardless of `wasProBefore`): the
    /// restore genuinely re-verified an active subscription. Never carries the raw RevenueCat/
    /// StoreKit error text — `.failed(_)`'s message is deliberately dropped.
    static func restoreFeedback(for outcome: RevenueCatSubscriptionService.RestoreOutcome) -> RestoreFeedback {
        switch outcome {
        case .proActive:   return .restored
        case .noActivePro: return .noActiveSubscription
        case .failed:      return .failed
        }
    }
}

// MARK: - Restore result feedback

/// The outcome of a Restore Purchases attempt, as shown to the user in one native alert. A single
/// enum (not one boolean per outcome) so exactly one result can be pending at a time.
enum RestoreFeedback: Equatable {
    /// An active 85Blends Pro entitlement was confirmed.
    case restored
    /// Restore completed but RevenueCat reports no active Pro entitlement for this Apple ID.
    case noActiveSubscription
    /// The restore itself failed (network, StoreKit, RevenueCat).
    case failed

    var title: String {
        switch self {
        case .restored:             return "Purchases Restored"
        case .noActiveSubscription: return "No Active Subscription Found"
        case .failed:               return "Restore Failed"
        }
    }

    var message: String {
        switch self {
        case .restored:
            return "Your 85Blends Pro subscription has been restored successfully."
        case .noActiveSubscription:
            return "We couldn't find an active 85Blends Pro subscription associated with your Apple ID."
        case .failed:
            return "We couldn't restore your purchases right now. Please check your connection and try again."
        }
    }
}

// MARK: - Purchase / restore flow state machine

/// Pure state machine behind `SubscriptionManager.purchaseState`/`restoreFeedback` — no
/// RevenueCat, StoreKit or SwiftUI types, so every transition is directly unit-testable
/// (see SubscriptionManagerTests.swift's `PurchaseFlowTests`).
///
/// INVARIANTS it enforces:
///   1. `.purchasing` and `.restoring` are TRANSIENT. An authoritative active entitlement
///      (`entitlementApplied`) ends a pending purchase (→ `.succeeded`) and a pending restore that
///      began while Free (→ `.restored` + result alert) — so a purchase/restore whose paywall
///      callback was lost (RevenueCatUI delivers them as SwiftUI preference changes on
///      `PaywallView`, which `ProUpgradeView` removes the instant `isProUser` flips) can never
///      leave the screen showing "Processing your purchase…" over an active Pro entitlement, nor
///      leave Restore Purchases disabled.
///   2. Every terminal path leaves the transient state: success, cancel, failure, entitlement
///      arrival, and paywall dismissal.
///   3. A restore always ends with a result (`restoreFeedback`) — restored / none found / failed —
///      and is immediately actionable again.
///   4. Dismissing the paywall clears transient state WITHOUT claiming an outcome — StoreKit/
///      RevenueCat own any in-flight transaction independent of the view, and the authoritative
///      CustomerInfo path still resolves the final entitlement.
///
/// The entitlement signal fed in here is always RevenueCat's RAW Pro entitlement, never the
/// Developer Pro Override-affected `isPro` — an override is not a purchase.
struct PurchaseFlow: Equatable {
    typealias State = SubscriptionManager.PurchaseState

    private(set) var state: State = .idle
    private(set) var restoreFeedback: RestoreFeedback?
    /// Snapshot of the raw RevenueCat entitlement when the current restore began.
    private(set) var restoreWasProBefore = false
    /// True once an entitlement arrival already settled (and reported) the current restore, so the
    /// paywall's own late `onRestoreCompleted` for that same attempt can't report it a second time.
    private var restoreSettledByEntitlement = false

    /// A purchase or restore is currently pending — new ones must not start, and the Restore
    /// button is disabled.
    var isBusy: Bool { state == .purchasing || state == .restoring }

    /// The state a restore that found an active Pro entitlement resolves to — shared by
    /// `SubscriptionManager.state(forRestoreOutcome:wasProBefore:)` and the entitlement
    /// reconciliation below so the two can never disagree.
    static func stateForActiveRestore(wasProBefore: Bool) -> State {
        wasProBefore ? .info("85Blends Pro is active.") : .restored
    }

    mutating func purchaseStarted() {
        state = .purchasing
    }

    /// `state` is the already-mapped terminal state (`SubscriptionManager.state(forPurchaseOutcome:)`).
    mutating func purchaseFinished(state resulting: State) {
        state = resulting
    }

    mutating func restoreStarted(wasProBefore: Bool) {
        state = .restoring
        restoreWasProBefore = wasProBefore
        restoreSettledByEntitlement = false
        restoreFeedback = nil
    }

    /// Records a restore result. `viaPaywallCallback` is `true` for RevenueCatUI's
    /// `.onRestoreCompleted`/`.onRestoreFailure`, whose delivery is not guaranteed and may arrive
    /// after `entitlementApplied` already settled this attempt (then it is ignored); an awaited
    /// `SubscriptionManager.restorePurchases()` result is always final. The result alert is only
    /// queued while the paywall is on screen, so it can never surface later over something else.
    mutating func restoreFinished(state resulting: State, feedback: RestoreFeedback, viaPaywallCallback: Bool, paywallPresented: Bool) {
        if viaPaywallCallback && restoreSettledByEntitlement {
            restoreSettledByEntitlement = false
            return
        }
        restoreSettledByEntitlement = false
        state = resulting
        restoreFeedback = paywallPresented ? feedback : nil
    }

    /// An authoritative RevenueCat entitlement was just applied. See this type's header.
    mutating func entitlementApplied(revenueCatIsPro: Bool, paywallPresented: Bool) {
        guard revenueCatIsPro else { return }
        switch state {
        case .purchasing:
            state = .succeeded
        case .restoring where restoreWasProBefore == false:
            // Only a Free → Pro transition during a restore is attributable to it. A user who was
            // ALREADY Pro keeps `.restoring` until the restore call itself reports — an unrelated
            // CustomerInfo refresh must not report a restore result that hasn't happened yet.
            state = Self.stateForActiveRestore(wasProBefore: false)
            restoreFeedback = paywallPresented ? .restored : nil
            restoreSettledByEntitlement = true
        default:
            break
        }
    }

    /// The paywall left the screen. Ends any pending transient state without claiming an outcome
    /// and drops an unacknowledged result alert so it can't reappear on the next presentation.
    mutating func paywallDismissed() {
        if isBusy {
            state = .idle
        }
        restoreFeedback = nil
    }

    mutating func dismissRestoreFeedback() {
        restoreFeedback = nil
    }
}
