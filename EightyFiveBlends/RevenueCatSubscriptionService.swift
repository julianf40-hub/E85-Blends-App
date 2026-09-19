//
//  RevenueCatSubscriptionService.swift
//  EightyFiveBlends
//
//  85Blends 2.3.0 — RevenueCat authoritative subscription cutover.
//  85Blends 2.4.0 — extended to three plans (Monthly/3-Month/Annual, see ProPlan.swift), all
//  granting the SAME `pro` entitlement below. See "KEY AUTHORITY INVARIANT" — that invariant is
//  exactly what made this extension safe: nothing about entitlement resolution reads a product ID
//  or cares which of the three plans a customer purchased.
//
//  RevenueCat is the application-level subscription management layer for 85Blends: it loads the
//  subscription offering, initiates purchases, restores purchases, interprets CustomerInfo, and
//  determines whether `pro` is active. Apple/StoreKit still performs the underlying App Store
//  transaction (the products are `com.85blends.subscription.monthly`/`.threemonth`/`.annual` — see
//  ProPlan.swift) — RevenueCat is configured with `purchasesAreCompletedBy: .revenueCat`, so
//  RevenueCat owns purchasing end to end rather than observing transactions 85Blends' own StoreKit
//  code would otherwise complete.
//
//  A fourth, LEGACY product — `com.85blends.subscription.quarterly` — remains attached to `pro`
//  in RevenueCat but lives only in a separate, non-`default` offering (`pro_240_draft`). This file
//  only ever queries the `default` offering (`offeringID` below, unchanged) — the legacy product
//  is never seen, resolved, or purchasable through this code, with no special-casing required.
//
//  KEY AUTHORITY INVARIANT: `revenueCatIsPro` below — derived from
//  `CustomerInfo.entitlements["pro"]?.isActive == true` — is the ONLY real subscription
//  entitlement source in this app. `SubscriptionManager.isPro` reads it directly (Internal/Debug
//  builds may still layer the Developer Pro Override on top — see SubscriptionManager.swift).
//  There is no StoreKit-side entitlement authority left to agree or disagree with, and NOTHING in
//  this invariant is plan-aware — see the 85Blends 2.3.0 RevenueCat cutover report for the
//  previous shadow-observation architecture this replaces.
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
/// has exactly one Pro entitlement across its three plans (see ProPlan.swift), so this is not a
/// general-purpose billing abstraction. `purchase(package:)` already takes an arbitrary `Package`,
/// so all three plans share this exact same boundary with no per-plan change needed here.
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
    static let shared = RevenueCatSubscriptionService(client: LiveRevenueCatClient())

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

    /// Offering/package resolution state for ONE `ProPlan`'s package. Kept distinct from
    /// `notLoaded` vs `loading` vs terminal-failure states so the paywall (via SubscriptionManager)
    /// can tell "haven't tried yet" from "tried and failed" — the same distinction
    /// `hasAttemptedProductLoad` made for StoreKit product loading before the 2.3.0 RevenueCat
    /// cutover. 85Blends 2.4.0 three-plan paywall — this enum's SHAPE is unchanged from the
    /// single-plan era; what changed is that `packageAvailability` below now holds one of these
    /// PER PLAN instead of a single value, so one plan failing to resolve can never affect the
    /// other two (see `loadOfferings()`).
    enum PackageAvailability: Equatable {
        case notLoaded
        case loading
        case ready(Package)
        case offeringUnavailable
        case packageUnavailable
        /// The resolved package's underlying Apple product ID did not match this plan's own
        /// `ProPlan.productID`. Never purchased — see `resolvePackage(...)`. This is also what
        /// protects against the legacy `com.85blends.subscription.quarterly` product: if it were
        /// ever (incorrectly) assigned to one of the `default` offering's monthly/threeMonth/
        /// annual slots, its product ID would never match any `ProPlan.productID` and this case
        /// would reject it exactly like any other unexpected product — see this file's header for
        /// the primary protection (querying only the `default` offering, never `pro_240_draft`,
        /// where the legacy product actually lives).
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

    /// A typed alternative to `Result<Bool, String>` (which does not compile — `Swift.Result`
    /// requires `Failure: Error`, and a bare `String` doesn't conform). `pro` is derived strictly
    /// from the returned CustomerInfo, exactly like `PurchaseOutcome` above.
    enum RestoreOutcome: Equatable {
        case proActive
        case noActivePro
        case failed(String)
    }

    /// 85Blends 2.3.2 — describes ONLY whether this process has received its first-ever
    /// authoritative CustomerInfo answer, never whether the user is Pro (see `revenueCatIsPro`
    /// for that — a deliberately separate question, per this PR's own explicit requirement that
    /// entitlement authority never change). Fixes a real cold-launch bug: `revenueCatIsPro`
    /// starts `false` and `configureIfNeeded()`'s CustomerInfo fetch is asynchronous, so the very
    /// first SwiftUI frame could previously only ever see "not Pro" and had no way to tell an
    /// unresolved entitlement apart from a genuinely Free one — Stations (now the default launch
    /// tab) would flash its Free/Classic UI before swapping to the Pro premium map once RevenueCat
    /// resolved. `isInitialEntitlementResolutionPending` below is what callers (StationsView, via
    /// SubscriptionManager) should actually read to avoid presenting "unknown" as "Free."
    enum InitialEntitlementResolutionState: Equatable {
        case notStarted
        case resolving
        /// Reached exactly once per process, forward-only, on the FIRST successful fetch,
        /// FIRST failed fetch, or missing/blank SDK key alike (see `configureIfNeeded()`'s
        /// missing-key branch and `markInitialEntitlementResolutionCompleteIfNeeded()`) — never
        /// re-entered afterward, so a later foreground refresh, purchase, restore, or
        /// customerInfoStream update can never re-arm a "still resolving" presentation. A
        /// missing key or a failed first fetch still reaches `.resolved` (with `revenueCatIsPro`
        /// at its safe `false` default) rather than leaving Stations behind an indefinite
        /// loading shell — see sections 7-8 of this feature's task.
        case resolved
    }

    // MARK: - Observable state (now authoritative — see this type's header)

    private(set) var configurationState: ConfigurationState = .notConfigured
    /// The real, authoritative RevenueCat Pro entitlement:
    /// `customerInfo.entitlements["pro"]?.isActive == true`. `SubscriptionManager.isPro` reads
    /// this directly (Internal/Debug may still layer the Developer Override on top).
    private(set) var revenueCatIsPro: Bool = false
    private(set) var initialEntitlementResolutionState: InitialEntitlementResolutionState = .notStarted
    private(set) var customerInfoLastUpdatedAt: Date?
    private(set) var maskedAppUserID: String?
    /// 85Blends 2.4.0 — one resolution state per `ProPlan`, populated together by a single
    /// `loadOfferings()` call (see that function). A plan absent from this dictionary has simply
    /// never had a load attempted yet — `packageAvailability(for:)` below treats that identically
    /// to `.notLoaded`, so callers never need to special-case "missing key."
    private(set) var packageAvailability: [ProPlan: PackageAvailability] = [:]
    /// `true`/`false` once a `pro` entitlement record has been seen (active or not — RevenueCat
    /// still reports sandbox-vs-production for an expired/inactive entitlement); `nil` if no
    /// entitlement record has ever been observed. Diagnostics-only.
    private(set) var isSandboxEnvironment: Bool?
    private(set) var lastErrorDescription: String?

    var isConfigured: Bool { configurationState == .configured }

    /// True until this process's FIRST authoritative CustomerInfo answer arrives (or is
    /// determined unreachable — see `InitialEntitlementResolutionState.resolved`'s own header).
    /// This is the "have we resolved yet" question — completely independent of `revenueCatIsPro`
    /// (the "is the user Pro" question) — so a presentation gate can tell "entitlement unknown"
    /// apart from "entitlement known to be Free," which `revenueCatIsPro == false` alone cannot.
    var isInitialEntitlementResolutionPending: Bool {
        initialEntitlementResolutionState != .resolved
    }

    /// This plan's resolution state — `.notLoaded` if no load has ever been attempted for it yet.
    func packageAvailability(for plan: ProPlan) -> PackageAvailability {
        packageAvailability[plan] ?? .notLoaded
    }

    /// The resolved, validated package for this plan — non-nil only once its own
    /// `packageAvailability(for:)` is `.ready`. This is what `SubscriptionManager.purchasePro(_:)`
    /// passes to `purchase(_:)`.
    func package(for plan: ProPlan) -> Package? {
        if case .ready(let package) = packageAvailability(for: plan) { return package }
        return nil
    }

    // MARK: - Private

    private let client: RevenueCatClient
    private var customerInfoObservationTask: Task<Void, Never>?

    /// `client` is injectable for testing (see this type's header). Deliberately NOT a default
    /// parameter value — `LiveRevenueCatClient()` is instead constructed explicitly at `.shared`'s
    /// declaration below. A default argument expression is not guaranteed to inherit this
    /// initializer's `@MainActor` isolation, which is what produced Xcode's "Call to main
    /// actor-isolated initializer in a synchronous nonisolated context" warning on the previous
    /// `init(client: RevenueCatClient = LiveRevenueCatClient())` form. Requiring an explicit
    /// argument at every call site (both `.shared` and tests) avoids that ambiguity entirely.
    init(client: RevenueCatClient) {
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
            // No SDK key means no CustomerInfo fetch will ever happen this process — the
            // initial resolution must not hang a presentation gate behind an indefinite loading
            // shell (section 8). `revenueCatIsPro` stays at its safe `false` default.
            initialEntitlementResolutionState = .resolved
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
        initialEntitlementResolutionState = .resolving

        // CustomerInfo and offerings load concurrently, exactly as before this feature —
        // Stations only ever needs the entitlement determination (CustomerInfo), never the
        // paywall's package/offering, to know what to render (section 10). Neither `await`
        // here waits on the other; `markInitialEntitlementResolutionCompleteIfNeeded()` (called
        // from inside `refreshCustomerInfoNow()`/`apply(_:)`, not from here) completes as soon
        // as the CustomerInfo half finishes, regardless of how long offerings takes.
        async let customerInfoLoad: Void = refreshCustomerInfoNow()
        async let offeringsLoad: Void = loadOfferings()
        _ = await (customerInfoLoad, offeringsLoad)
    }

    // MARK: - CustomerInfo observation

    /// Reactive entitlement updates (Phase 16): renewals, expirations, refunds/revocations, and
    /// restores observed elsewhere all flow through this stream without requiring a relaunch.
    /// `Purchases.shared.customerInfoStream` is non-throwing (`AsyncStream<CustomerInfo>` in
    /// RevenueCat 5.85.0) — no do/catch here, since one around a non-throwing sequence is dead
    /// code (Xcode flagged the previous `for try await` form as an unreachable catch block).
    private func startObservingCustomerInfo() {
        customerInfoObservationTask?.cancel()
        customerInfoObservationTask = Task { [weak self] in
            for await customerInfo in Purchases.shared.customerInfoStream {
                guard let self, Task.isCancelled == false else { return }
                self.apply(customerInfo)
            }
        }
    }

    private func apply(_ customerInfo: CustomerInfo) {
        let entitlement = customerInfo.entitlements[Self.proEntitlementID]
        revenueCatIsPro = Self.isProEntitlementActive(entitlementIsActive: entitlement?.isActive)
        isSandboxEnvironment = entitlement?.isSandbox
        customerInfoLastUpdatedAt = Date()
        maskedAppUserID = Self.maskedAppUserID(from: Purchases.shared.appUserID)
        // Covers every success path that produces a real CustomerInfo answer — a refresh, a
        // purchase, a restore, and every customerInfoStream emission alike — so whichever one
        // happens to complete first this process is what resolves the initial state. A no-op
        // once already resolved (see the helper's own header).
        markInitialEntitlementResolutionCompleteIfNeeded()
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
            // A terminal failure on the FIRST process-launch refresh must still end the initial
            // resolution window (section 7) — with no authoritative answer, `revenueCatIsPro`
            // simply stays at its safe `false` (Free) default rather than leaving Stations
            // behind an indefinite loading shell. A no-op on every later (e.g. foreground)
            // refresh failure, since this is already `.resolved` by then.
            markInitialEntitlementResolutionCompleteIfNeeded()
        }
    }

    /// Forward-only, idempotent completion of the initial entitlement-resolution window (section
    /// 6) — called from every path that produces a first-ever authoritative answer OR determines
    /// one is unreachable this process: a successful `apply(_:)`, a failed initial
    /// `refreshCustomerInfoNow()`, and a missing/blank SDK key in `configureIfNeeded()`. Never
    /// reverses `.resolved` back to `.resolving`/`.notStarted` — see
    /// `isInitialEntitlementResolutionPending`'s own header for why a later foreground refresh,
    /// purchase, restore, or stream update must never re-arm a "still resolving" presentation.
    private func markInitialEntitlementResolutionCompleteIfNeeded() {
        guard initialEntitlementResolutionState != .resolved else { return }
        initialEntitlementResolutionState = .resolved
    }

    // MARK: - Offering / package loading

    /// Resolves the `default` offering's `$rc_monthly`/`$rc_three_month`/`$rc_annual` packages —
    /// one call, one network fetch, all three plans resolved independently from the SAME
    /// `Offerings` response. Each plan's package is validated against its own `ProPlan.productID`
    /// before it is ever eligible to purchase — see `resolvePackage(...)`. Safe to call repeatedly
    /// (e.g. every paywall presentation, for freshness).
    ///
    /// 85Blends 2.4.0 three-plan paywall — one plan failing to resolve (offering misconfigured for
    /// just that plan, or genuinely unavailable) never affects the other two: each plan gets its
    /// own independent `PackageAvailability` in the dictionary below, computed from the same
    /// fetched `Offering` but never short-circuiting on another plan's failure.
    func loadOfferings() async {
        guard configurationState == .configured else { return }
        // Any one plan still `.loading` means the whole batch is in flight — all three are always
        // set to `.loading` together, immediately below, so checking one is equivalent to checking
        // all three; this is just the re-entrancy guard, unchanged in spirit from the single-plan
        // era's `guard packageAvailability != .loading`.
        guard packageAvailability(for: .monthly) != .loading else { return }
        for plan in ProPlan.allCases { packageAvailability[plan] = .loading }
        do {
            let offerings = try await client.fetchOfferings()
            // Strictly `default` — no `?? offerings.current` fallback. RevenueCat's own "current
            // offering" designation is dashboard state this app cannot verify or control, and the
            // live project has a second, legacy offering (`pro_240_draft`, where the retired
            // `com.85blends.subscription.quarterly` product lives) that must never be silently
            // substituted in just because someone marked it current. Missing `default` here always
            // means `offeringExists: false` below — every plan resolves to `.offeringUnavailable`
            // (the normal retry/error paywall state), never a silent fallback to another offering.
            let offering = offerings.offering(identifier: Self.offeringID)
            var errorMessages: [String] = []
            for plan in ProPlan.allCases {
                let package = Self.package(for: plan, in: offering)
                let resolution = Self.resolvePackage(
                    offeringExists: offering != nil,
                    packageExists: package != nil,
                    packageProductID: package?.storeProduct.productIdentifier,
                    expectedProductID: plan.productID
                )
                switch resolution {
                case .ready:
                    packageAvailability[plan] = .ready(package!)
                case .offeringUnavailable:
                    packageAvailability[plan] = .offeringUnavailable
                    errorMessages.append("RevenueCat offering \"\(Self.offeringID)\" is unavailable.")
                case .packageUnavailable:
                    packageAvailability[plan] = .packageUnavailable
                    errorMessages.append("RevenueCat \(plan.rawValue) package is unavailable in the \"\(Self.offeringID)\" offering.")
                case .unexpectedProduct(let productID):
                    packageAvailability[plan] = .unexpectedProduct(productID)
                    let message = "RevenueCat \(plan.rawValue) package maps to unexpected product \"\(productID)\" (expected \(plan.productID)) — refusing to purchase."
                    errorMessages.append(message)
                    #if DEBUG || INTERNAL_BUILD
                    print("[85Blends][RevenueCat] \(message)")
                    #endif
                }
            }
            // The offering itself failing is reported once per plan above (each independently
            // lands on `.offeringUnavailable`) — de-duplicated here so `lastErrorDescription`
            // never repeats the identical offering-missing message three times.
            lastErrorDescription = errorMessages.isEmpty ? nil : Array(Set(errorMessages)).sorted().joined(separator: " ")
        } catch {
            for plan in ProPlan.allCases { packageAvailability[plan] = .offeringUnavailable }
            lastErrorDescription = error.localizedDescription
        }
    }

    /// The RevenueCat SDK's own standard package-identifier convenience accessor for this plan
    /// (`$rc_monthly`/`$rc_three_month`/`$rc_annual`) — one small switch, isolated here so
    /// `loadOfferings()` above stays a plain loop with no per-plan special-casing.
    private static func package(for plan: ProPlan, in offering: Offering?) -> Package? {
        switch plan {
        case .monthly: offering?.monthly
        case .threeMonth: offering?.threeMonth
        case .annual: offering?.annual
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
    func restore() async -> RestoreOutcome {
        do {
            let customerInfo = try await client.restorePurchases()
            apply(customerInfo)
            return revenueCatIsPro ? .proActive : .noActivePro
        } catch {
            lastErrorDescription = error.localizedDescription
            return .failed(error.localizedDescription)
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

    /// 85Blends 2.4.0 — called once per `ProPlan` (see `loadOfferings()`), never hardcoded to
    /// "monthly" — `packageExists`/`expectedProductID` are supplied fresh per call, so the exact
    /// same validation rule (offering exists → package exists → product ID matches exactly) is
    /// applied identically and independently to Monthly, 3-Month, and Annual. This is also the
    /// only gate a resolved package must pass to become purchasable at all, which is what makes it
    /// structurally impossible for the legacy `com.85blends.subscription.quarterly` product to
    /// ever resolve as `.ready` — its product ID cannot equal any `ProPlan.productID`.
    static func resolvePackage(
        offeringExists: Bool,
        packageExists: Bool,
        packageProductID: String?,
        expectedProductID: String
    ) -> PackageResolution {
        guard offeringExists else { return .offeringUnavailable }
        guard packageExists, let packageProductID else { return .packageUnavailable }
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
