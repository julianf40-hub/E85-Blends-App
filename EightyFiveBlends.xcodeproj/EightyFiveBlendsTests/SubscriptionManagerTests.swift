//
//  SubscriptionManagerTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the 85Blends 2.3.0 RevenueCat-authoritative subscription cutover: the pure decision
//  logic behind entitlement interpretation, Developer Override precedence, purchase/restore
//  outcome classification, and offering/package resolution. These are the actual rules
//  SubscriptionManager.isPro, .purchase(_:), .restorePurchases(), and
//  RevenueCatSubscriptionService.loadOfferings()/.purchase(_:)/.restore() call — not duplicate
//  reimplementations — so passing tests here directly verify production behavior.
//
//  Extended for 85Blends 2.4.0's three-plan Pro paywall (Monthly/3-Month/Annual, see ProPlan.swift):
//  resolvePackage(...)'s tests now cover all three plans plus explicit legacy-quarterly-product
//  rejection, and ProPlan.preferredDefault(among:) — the paywall's default-selection rule — gets
//  its own exhaustive coverage. Sections A-D (entitlement/purchase-outcome/restore-outcome) did
//  not change and needed no new tests — see section J below for why.
//
//  Note: this file lives in the `EightyFiveBlends.xcodeproj/EightyFiveBlendsTests` folder, which
//  is a real, wired `EightyFiveBlendsTests` PBXNativeTarget (a Swift Testing bundle target) —
//  see project.pbxproj's `PBXFileSystemSynchronizedRootGroup`/`fileSystemSynchronizedGroups` for
//  that target, and both shared schemes' `TestAction`/`TestableReference`. Every `.swift` file
//  placed in this folder is picked up automatically; no per-file pbxproj entry is needed. CLAUDE.
//  md's "no test target in the pbxproj" note predates this and is stale as of this file's own
//  current state — flagged for a documentation fix, not repeated here as fact.
//
//  What these tests can and cannot prove: RevenueCat's `CustomerInfo`, `Offerings`, `Package`,
//  and `PurchaseResultData` are SDK-defined types this codebase does not construct fakes of —
//  there is no publicly documented, version-stable way to build a `CustomerInfo` in-process for
//  RevenueCat 5.85.0 that this test suite can safely rely on. So every place those real SDK types
//  touch this app's logic is intentionally a single, trivial, directly-inspectable line (see
//  `RevenueCatSubscriptionService.apply(_:)`), and the actual *decisions* — is the entitlement
//  active, what purchase/restore outcome maps to what UI state, is the resolved package the right
//  one — are pulled out into pure static functions that take plain values. These tests exercise
//  those pure functions exhaustively. They cannot observe that RevenueCat's real SDK objects
//  actually have the shape these functions assume, that `configureIfNeeded()`/`purchase(_:)`
//  actually calls RevenueCat correctly, or that the paywall/Preferences diagnostics wire up to
//  the right properties end to end — those are call-site facts verified by direct code inspection
//  (see the final cutover report) and the manual TestFlight validation matrix (Phase 31 of that
//  report), not something this file tests. Item 13 and item 20 below are call-site/compile-time
//  facts for the same reason — noted rather than asserted.

import Testing
@testable import EightyFiveBlends

struct SubscriptionManagerTests {

    // MARK: A. RevenueCat CustomerInfo entitlement interpretation (items 1-4)
    // Mirrors `customerInfo.entitlements["pro"]?.isActive == true` exactly — see
    // RevenueCatSubscriptionService.apply(_:), the only call site.

    @Test("Active pro entitlement → real Pro = true")
    func activePro_isTrue() {
        #expect(RevenueCatSubscriptionService.isProEntitlementActive(entitlementIsActive: true))
    }

    @Test("No pro entitlement record at all → real Pro = false")
    func noPro_isFalse() {
        #expect(RevenueCatSubscriptionService.isProEntitlementActive(entitlementIsActive: nil) == false)
    }

    @Test("Pro entitlement exists but inactive → real Pro = false")
    func inactivePro_isFalse() {
        #expect(RevenueCatSubscriptionService.isProEntitlementActive(entitlementIsActive: false) == false)
    }

    @Test("Only the exact \"pro\" entitlement ID is ever consulted — an unrelated active entitlement never grants Pro")
    func unrelatedEntitlement_isFalse() {
        // apply(_:) only ever looks up customerInfo.entitlements["pro"] — an unrelated active
        // entitlement (e.g. a future non-Pro entitlement) is never even passed in here, so this
        // reduces to the exact same "no pro key" case as noPro_isFalse above.
        #expect(RevenueCatSubscriptionService.isProEntitlementActive(entitlementIsActive: nil) == false)
    }

    // MARK: B. Developer Pro Override precedence (items 5-9)
    // SubscriptionManager.effectivePro(override:revenueCatIsPro:) — the exact rule `isPro` calls
    // under `#if DEBUG || INTERNAL_BUILD`.

    @Test("Override Off, RevenueCat FREE → effective Free")
    func off_revenueCatFree_isFree() {
        #expect(SubscriptionManager.effectivePro(override: .off, revenueCatIsPro: false) == false)
    }

    @Test("Override Off, RevenueCat PRO → effective Pro")
    func off_revenueCatPro_isPro() {
        #expect(SubscriptionManager.effectivePro(override: .off, revenueCatIsPro: true))
    }

    @Test("Override Off: a CustomerInfo refresh flipping RevenueCat FREE → PRO updates effective state immediately")
    func off_refreshFreeToPro_updatesImmediately() {
        #expect(SubscriptionManager.effectivePro(override: .off, revenueCatIsPro: false) == false)
        #expect(SubscriptionManager.effectivePro(override: .off, revenueCatIsPro: true) == true)
    }

    @Test("Override Off: a CustomerInfo refresh flipping RevenueCat PRO → FREE updates effective state immediately")
    func off_refreshProToFree_updatesImmediately() {
        #expect(SubscriptionManager.effectivePro(override: .off, revenueCatIsPro: true) == true)
        #expect(SubscriptionManager.effectivePro(override: .off, revenueCatIsPro: false) == false)
    }

    @Test("Force Pro always wins, regardless of RevenueCat state")
    func forcePro_alwaysWins() {
        #expect(SubscriptionManager.effectivePro(override: .forcePro, revenueCatIsPro: false))
        #expect(SubscriptionManager.effectivePro(override: .forcePro, revenueCatIsPro: true))
    }

    @Test("Force Free always wins, regardless of RevenueCat state")
    func forceFree_alwaysWins() {
        #expect(SubscriptionManager.effectivePro(override: .forceFree, revenueCatIsPro: true) == false)
        #expect(SubscriptionManager.effectivePro(override: .forceFree, revenueCatIsPro: false) == false)
    }

    // MARK: C. Purchase outcome → UI state (items 10-13)
    // SubscriptionManager.state(forPurchaseOutcome:) — the exact rule `purchase(_:)` calls. Named
    // `state(for...:)`, not `purchaseState(for...:)`, to avoid colliding with the `purchaseState`
    // instance property on the same type (see SubscriptionManager.swift's MARK comment there).

    @Test("Purchase succeeds with active pro entitlement → effective Pro immediately (succeeded)")
    func purchase_proActivated_succeeds() {
        #expect(SubscriptionManager.state(forPurchaseOutcome: .proActivated) == .succeeded)
    }

    @Test("Purchase call doesn't throw but CustomerInfo shows no active pro → never falsely unlocks")
    func purchase_notEntitled_neverUnlocks() {
        let state = SubscriptionManager.state(forPurchaseOutcome: .notEntitled)
        #expect(state != .succeeded)
        #expect(state == .failed("We couldn't verify your purchase. Please try again or contact support@85blends.app."))
    }

    @Test("Purchase cancellation → does not unlock, and is handled non-destructively (idle, not an error)")
    func purchase_cancelled_isNonDestructive() {
        let state = SubscriptionManager.state(forPurchaseOutcome: .cancelled)
        #expect(state != .succeeded)
        #expect(state == .idle)
        if case .failed = state { Issue.record("Cancellation must never surface as an error state") }
    }

    @Test("Purchase error → does not falsely unlock")
    func purchase_error_neverUnlocks() {
        let state = SubscriptionManager.state(forPurchaseOutcome: .failed("network error"))
        #expect(state != .succeeded)
        #expect(state == .failed("network error"))
        // Note (item 13, code-inspection fact — see this file's header): the only way
        // RevenueCatSubscriptionService.purchase(_:) reaches its `.failed` case is its `catch`
        // block, which never calls `apply(_:)` — so `revenueCatIsPro` is provably untouched by a
        // thrown purchase error, independent of this state-mapping test.
    }

    // MARK: D. Restore outcome → UI state (items 14-15, plus a restore-failure case)
    // SubscriptionManager.state(forRestoreOutcome:wasProBefore:) — the exact rule
    // `restorePurchases()` calls. Takes RevenueCatSubscriptionService.RestoreOutcome, a typed
    // enum — not `Result<Bool, String>`, which doesn't compile (`Swift.Result` requires
    // `Failure: Error`, and a bare `String` doesn't conform).

    @Test("Restore returns active pro, was Free before → restored")
    func restore_activePro_freshRestore() {
        #expect(SubscriptionManager.state(forRestoreOutcome: .proActive, wasProBefore: false) == .restored)
    }

    @Test("Restore returns active pro, was already Pro → informational, not a duplicate purchase")
    func restore_activePro_alreadyActive() {
        #expect(
            SubscriptionManager.state(forRestoreOutcome: .proActive, wasProBefore: true)
                == .info("85Blends Pro is active.")
        )
    }

    @Test("Restore returns no active pro → remains Free, honest \"nothing to restore\" message")
    func restore_noActivePro_remainsFree() {
        let state = SubscriptionManager.state(forRestoreOutcome: .noActivePro, wasProBefore: false)
        #expect(state != .restored)
        #expect(state == .info("No active subscription found."))
    }

    @Test("Restore fails (e.g. network error) → friendly failure message, never falsely unlocks")
    func restore_failure_neverUnlocks() {
        let state = SubscriptionManager.state(forRestoreOutcome: .failed("network error"), wasProBefore: false)
        #expect(state != .restored)
        #expect(state != .succeeded)
        #expect(state == .failed("We couldn't restore your purchases. Please try again."))
    }

    // MARK: D2. ProPlan model — 85Blends 2.4.0 (plan identity/pricing metadata)
    // ProPlan.swift — a plain value type with no RevenueCat/SubscriptionManager dependency. These
    // are the exact product IDs configured live in App Store Connect / RevenueCat (see ProPlan.
    // swift's own header) — a typo here would silently break purchasing for that plan.

    @Test("Each ProPlan resolves to its own exact, distinct App Store product ID")
    func proPlan_productIDs_areExact() {
        #expect(ProPlan.monthly.productID == "com.85blends.subscription.monthly")
        #expect(ProPlan.threeMonth.productID == "com.85blends.subscription.threemonth")
        #expect(ProPlan.annual.productID == "com.85blends.subscription.annual")
    }

    @Test("ProPlan.allCases is exactly the three shipping plans — the legacy quarterly product is never one of them")
    func proPlan_allCases_excludesLegacyQuarterly() {
        #expect(ProPlan.allCases.count == 3)
        #expect(Set(ProPlan.allCases) == [.monthly, .threeMonth, .annual])
        #expect(ProPlan.allCases.map(\.productID).contains("com.85blends.subscription.quarterly") == false)
    }

    // MARK: D3. Equivalent-monthly pricing arithmetic — ProPlan.equivalentMonthlyAmount(price:plan:)
    // Pure `Decimal` arithmetic, no RevenueCat/StoreKit dependency — see ProPlan.swift and
    // ProUpgradeView.equivalentMonthlyLine(for:), the only call site (which always passes a real
    // loaded `StoreProduct.price`, never a fallback marketing string). Test prices are built via
    // `Decimal(string:)`, never a bare float literal — `Decimal`'s `ExpressibleByFloatLiteral`
    // conformance parses the literal as a `Double` first, which would silently reintroduce the
    // exact binary floating-point imprecision this whole feature exists to avoid. Production code
    // never has this problem: `StoreProduct.price` is a `Decimal` straight from StoreKit, with no
    // `Double` round-trip — only a hand-written test literal is at risk.

    @Test("Monthly has no equivalent-monthly amount — nothing to compare a 1-month plan against")
    func equivalentMonthlyAmount_monthly_isNil() {
        let price = Decimal(string: "3.99")!
        #expect(ProPlan.equivalentMonthlyAmount(price: price, plan: .monthly) == nil)
    }

    @Test("3-Month: $9.99 over 3 months is exactly $3.33/month")
    func equivalentMonthlyAmount_threeMonth_isExact() {
        let price = Decimal(string: "9.99")!
        #expect(ProPlan.equivalentMonthlyAmount(price: price, plan: .threeMonth) == Decimal(string: "3.33")!)
    }

    @Test("Annual: $24.99 over 12 months is exactly $2.0825/month before display rounding")
    func equivalentMonthlyAmount_annual_isExact() {
        let price = Decimal(string: "24.99")!
        #expect(ProPlan.equivalentMonthlyAmount(price: price, plan: .annual) == Decimal(string: "2.0825")!)
    }

    @Test("A non-U.S.-style numeric annual price still just divides by 12 — proves the arithmetic runs on real numeric price, not a hardcoded U.S. marketing constant")
    func equivalentMonthlyAmount_annual_nonUSPrice_dividesByTwelve() {
        let price = Decimal(string: "29.99")!
        #expect(ProPlan.equivalentMonthlyAmount(price: price, plan: .annual) == price / Decimal(12))
    }

    // MARK: E. Offering / package resolution (items 16-18, extended for 85Blends 2.4.0's 3 plans)
    // RevenueCatSubscriptionService.resolvePackage(...) — the exact rule `loadOfferings()` calls
    // once per `ProPlan` (never hardcoded to Monthly), guarding what
    // `SubscriptionManager.purchasePro(_:)` is ever allowed to purchase. Also what makes it
    // structurally impossible for the legacy `com.85blends.subscription.quarterly` product to ever
    // resolve as `.ready` — see the explicit rejection tests below.

    @Test("Offering missing → safe plans-unavailable state, never a package")
    func resolvePackage_offeringMissing_isUnavailable() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: false,
            packageExists: false,
            packageProductID: nil,
            expectedProductID: ProPlan.monthly.productID
        )
        #expect(resolution == .offeringUnavailable)
    }

    @Test("Package missing from an existing offering → safe plans-unavailable state")
    func resolvePackage_packageMissing_isUnavailable() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            packageExists: false,
            packageProductID: nil,
            expectedProductID: ProPlan.monthly.productID
        )
        #expect(resolution == .packageUnavailable)
    }

    @Test("Package resolves to an unexpected product ID → never eligible to purchase")
    func resolvePackage_unexpectedProduct_isRejected() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            packageExists: true,
            packageProductID: "com.wrong.product.id",
            expectedProductID: ProPlan.monthly.productID
        )
        #expect(resolution == .unexpectedProduct("com.wrong.product.id"))
        if case .ready = resolution { Issue.record("An unexpected product mapping must never resolve as ready-to-purchase") }
    }

    @Test("Package resolves to the exact expected product ID → ready to purchase (Monthly)")
    func resolvePackage_monthly_expectedProduct_isReady() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            packageExists: true,
            packageProductID: ProPlan.monthly.productID,
            expectedProductID: ProPlan.monthly.productID
        )
        #expect(resolution == .ready)
    }

    @Test("Package resolves to the exact expected product ID → ready to purchase (3-Month)")
    func resolvePackage_threeMonth_expectedProduct_isReady() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            packageExists: true,
            packageProductID: ProPlan.threeMonth.productID,
            expectedProductID: ProPlan.threeMonth.productID
        )
        #expect(resolution == .ready)
    }

    @Test("Package resolves to the exact expected product ID → ready to purchase (Annual)")
    func resolvePackage_annual_expectedProduct_isReady() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            packageExists: true,
            packageProductID: ProPlan.annual.productID,
            expectedProductID: ProPlan.annual.productID
        )
        #expect(resolution == .ready)
    }

    @Test("3-Month's own product ID is never accepted as a match for Monthly")
    func resolvePackage_crossPlanProductID_isRejected() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            packageExists: true,
            packageProductID: ProPlan.threeMonth.productID,
            expectedProductID: ProPlan.monthly.productID
        )
        #expect(resolution == .unexpectedProduct(ProPlan.threeMonth.productID))
    }

    // The legacy `com.85blends.subscription.quarterly` product only ever lives in RevenueCat's
    // separate `pro_240_draft` offering (see RevenueCatSubscriptionService.swift's header) — this
    // app's `loadOfferings()` never even queries that offering. These three tests are the second,
    // independent layer of protection: even if it somehow appeared as one of the `default`
    // offering's monthly/threeMonth/annual package slots, resolvePackage's product-ID equality
    // check rejects it exactly like any other wrong product, for every plan.

    @Test("Legacy quarterly product ID is explicitly rejected if ever seen where Monthly is expected")
    func resolvePackage_legacyQuarterly_rejectedForMonthly() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            packageExists: true,
            packageProductID: "com.85blends.subscription.quarterly",
            expectedProductID: ProPlan.monthly.productID
        )
        #expect(resolution == .unexpectedProduct("com.85blends.subscription.quarterly"))
    }

    @Test("Legacy quarterly product ID is explicitly rejected if ever seen where 3-Month is expected")
    func resolvePackage_legacyQuarterly_rejectedForThreeMonth() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            packageExists: true,
            packageProductID: "com.85blends.subscription.quarterly",
            expectedProductID: ProPlan.threeMonth.productID
        )
        #expect(resolution == .unexpectedProduct("com.85blends.subscription.quarterly"))
    }

    @Test("Legacy quarterly product ID is explicitly rejected if ever seen where Annual is expected")
    func resolvePackage_legacyQuarterly_rejectedForAnnual() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            packageExists: true,
            packageProductID: "com.85blends.subscription.quarterly",
            expectedProductID: ProPlan.annual.productID
        )
        #expect(resolution == .unexpectedProduct("com.85blends.subscription.quarterly"))
    }

    // Strict-`default`-offering note (not independently runtime-testable — same class of fact as
    // items 13/20/22 above): `loadOfferings()` reads `offerings.offering(identifier: "default")`
    // directly, with no `?? offerings.current` fallback. RevenueCat's SDK `Offerings`/`Offering`
    // types aren't constructible here (this file's own header explains why), so this can't be
    // driven end-to-end without a real fetch — but the code itself has nowhere left to reach
    // `pro_240_draft` (or any offering RevenueCat happens to mark "current") from: a missing
    // `default` offering makes `offeringExists` false for every plan, which `resolvePackage(...)`
    // above already proves maps to `.offeringUnavailable`, never a fallback resolution.

    // MARK: E2. Default plan selection / partial availability — ProPlan.preferredDefault(among:)
    // Pure function, no RevenueCat/SubscriptionManager dependency (see ProPlan.swift). This is
    // what ProUpgradeView.applyDefaultPlanSelectionIfNeeded() calls once real package availability
    // is known, so these tests exercise every possible availability combination (all 8 subsets of
    // the 3 plans) directly, without needing to fake RevenueCat's own package-loading state.

    @Test("No plan available → no default (paywall falls back to its load-error/retry state)")
    func preferredDefault_none_isNil() {
        #expect(ProPlan.preferredDefault(among: []) == nil)
    }

    @Test("Only Monthly available → Monthly is the default")
    func preferredDefault_onlyMonthly_isMonthly() {
        #expect(ProPlan.preferredDefault(among: [.monthly]) == .monthly)
    }

    @Test("Only 3-Month available → 3-Month is the default")
    func preferredDefault_onlyThreeMonth_isThreeMonth() {
        #expect(ProPlan.preferredDefault(among: [.threeMonth]) == .threeMonth)
    }

    @Test("Only Annual available → Annual is the default")
    func preferredDefault_onlyAnnual_isAnnual() {
        #expect(ProPlan.preferredDefault(among: [.annual]) == .annual)
    }

    @Test("Monthly + 3-Month available (no Annual) → 3-Month wins (better value than Monthly)")
    func preferredDefault_monthlyAndThreeMonth_isThreeMonth() {
        #expect(ProPlan.preferredDefault(among: [.monthly, .threeMonth]) == .threeMonth)
    }

    @Test("Monthly + Annual available (no 3-Month) → Annual wins")
    func preferredDefault_monthlyAndAnnual_isAnnual() {
        #expect(ProPlan.preferredDefault(among: [.monthly, .annual]) == .annual)
    }

    @Test("3-Month + Annual available (no Monthly) → Annual wins")
    func preferredDefault_threeMonthAndAnnual_isAnnual() {
        #expect(ProPlan.preferredDefault(among: [.threeMonth, .annual]) == .annual)
    }

    @Test("All three available → Annual wins (best value always preferred when possible)")
    func preferredDefault_allThree_isAnnual() {
        #expect(ProPlan.preferredDefault(among: [.monthly, .threeMonth, .annual]) == .annual)
    }

    // MARK: F. Refresh-failure cache behavior (item 19)

    @Test("A CustomerInfo refresh failure after a previously valid PRO state leaves entitlement untouched (RevenueCat cache semantics, not a hand-rolled one)")
    func refreshFailure_afterPro_preservesState() {
        #expect(RevenueCatSubscriptionService.revenueCatIsProAfterFailedRefresh(previousValue: true) == true)
    }

    @Test("A CustomerInfo refresh failure after a previously valid FREE state leaves entitlement untouched")
    func refreshFailure_afterFree_preservesState() {
        #expect(RevenueCatSubscriptionService.revenueCatIsProAfterFailedRefresh(previousValue: false) == false)
    }

    // MARK: G. Item 20 — documented, not runtime-testable
    //
    // "No Developer Override may leak into Release semantics." SubscriptionManager.isPro,
    // .effectivePro(...), .debugProOverride, and the entire DebugProOverride enum are wrapped in
    // `#if DEBUG || INTERNAL_BUILD` — an App Store Release build does not compile this code at
    // all, so there is no runtime override path to leak. This is a compiler guarantee verified by
    // code inspection (see the final cutover report), not something a unit test running in a
    // Debug test target can independently observe — a test binary that could see the override
    // would, by definition, not be a Release build.

    // MARK: H. Internal Pro Override reset / stale-state safety (items 21-22)
    //
    // resetDebugProOverride() and isDebugProOverrideActive are themselves #if DEBUG ||
    // INTERNAL_BUILD-only (see SubscriptionManager.swift), same as everything in section G — a
    // test binary that can see these symbols at all is, by construction, compiled with one of
    // those flags active. These tests exercise the reset mechanism itself (added after a stale
    // .forcePro override was found still active against a fresh, entitlement-free RevenueCat
    // sandbox customer); item 20 above already covers why the Release `#else` path can't leak an
    // override in the first place.
    //
    // These two touch the live `SubscriptionManager.shared` singleton (unlike sections A-F, which
    // test pure static functions with plain values) because resetDebugProOverride() and
    // isDebugProOverrideActive are themselves trivial state accessors, not decision logic to
    // extract — there is nothing to meaningfully isolate into a pure function here. Each restores
    // the singleton's original override value via `defer` so it doesn't leak state into whichever
    // test runs next.

    @Test("resetDebugProOverride() returns the override to .off from any prior state")
    func resetDebugProOverride_returnsToOff() {
        let manager = SubscriptionManager.shared
        let originalOverride = manager.debugProOverride
        defer { manager.debugProOverride = originalOverride }

        manager.debugProOverride = .forcePro
        #expect(manager.isDebugProOverrideActive)

        manager.resetDebugProOverride()

        #expect(manager.debugProOverride == .off)
        #expect(manager.isDebugProOverrideActive == false)
    }

    @Test("isDebugProOverrideActive is true for Force Pro and Force Free, false only for Off")
    func isDebugProOverrideActive_matchesNonOffCases() {
        let manager = SubscriptionManager.shared
        let originalOverride = manager.debugProOverride
        defer { manager.debugProOverride = originalOverride }

        manager.debugProOverride = .off
        #expect(manager.isDebugProOverrideActive == false)

        manager.debugProOverride = .forcePro
        #expect(manager.isDebugProOverrideActive)

        manager.debugProOverride = .forceFree
        #expect(manager.isDebugProOverrideActive)
    }

    // Item 22 — "production path remains RevenueCat-only" is a compile-time fact, not something a
    // Debug-compiled test binary can independently observe (identical reasoning to item 20).
    // `isPro`'s `#else` branch (SubscriptionManager.swift) is the ONLY code compiled into an App
    // Store Release build, and it reads `RevenueCatSubscriptionService.shared.revenueCatIsPro`
    // directly — `debugProOverride`, `resetDebugProOverride()`, and `isDebugProOverrideActive` do
    // not exist in that build at all, so there is no override path left to reset, leak, or
    // otherwise affect production semantics. Verified by code inspection (see this file's header
    // and the accompanying verification report), not a runtime assertion.

    // MARK: I. Initial entitlement resolution — the 2.3.2 Stations-flash fix (scenarios A-H)
    //
    // RevenueCatSubscriptionService.InitialEntitlementResolutionState/
    // isInitialEntitlementResolutionPending/markInitialEntitlementResolutionCompleteIfNeeded()
    // and SubscriptionManager.isInitialEntitlementResolutionPending. Unlike sections A-F above,
    // these aren't pure static functions taking plain values — they're async instance
    // orchestration (configureIfNeeded()/refreshCustomerInfoNow()/apply(_:)) that, exactly like
    // every other CustomerInfo-touching code path in this file (see this file's own header),
    // cannot be driven end-to-end in a unit test without a real, constructible `CustomerInfo` or
    // without configuring the live, global `Purchases.shared` SDK singleton as a side effect
    // (`configureIfNeeded()` calls `Purchases.configure(with:)` directly, independent of the
    // injectable `RevenueCatClient` — there is no way to exercise it in-process without that real
    // side effect). What IS directly testable is the enum contract itself: exactly what
    // `isInitialEntitlementResolutionPending` is actually defined as (`state != .resolved`) — see
    // below. Scenarios A-H are otherwise recorded as inspection facts, each pointing at the exact
    // production line that provides the guarantee, mirroring items 13/20/22's established
    // convention in this same file for the same class of untestable-in-process fact.

    @Test("Only .resolved is a non-pending state — .notStarted and .resolving both still read as pending")
    func initialEntitlementResolutionState_pendingContract() {
        #expect(RevenueCatSubscriptionService.InitialEntitlementResolutionState.notStarted != .resolved)
        #expect(RevenueCatSubscriptionService.InitialEntitlementResolutionState.resolving != .resolved)
        #expect(RevenueCatSubscriptionService.InitialEntitlementResolutionState.resolved == .resolved)
    }

    // A. "launch notStarted -> pending": `initialEntitlementResolutionState` is declared
    //    `= .notStarted` (RevenueCatSubscriptionService.swift) and `isInitialEntitlementResolutionPending`
    //    is `state != .resolved` — `.notStarted != .resolved` is `true` per the contract test above,
    //    so a freshly-constructed service (before configureIfNeeded() ever runs) is pending.
    //
    // B. "resolving -> pending": configureIfNeeded() sets `initialEntitlementResolutionState =
    //    .resolving` immediately after `configurationState = .configured`, before either of the
    //    concurrent CustomerInfo/offerings loads starts — `.resolving != .resolved` is `true` per
    //    the contract test above, so this window is also pending.
    //
    // C. "successful Pro first refresh -> not pending + Pro": refreshCustomerInfoNow()'s success
    //    path calls apply(_:), which sets `revenueCatIsPro` from the real entitlement AND
    //    unconditionally calls `markInitialEntitlementResolutionCompleteIfNeeded()` (which sets
    //    `.resolved` since the state is not already `.resolved`) in the same synchronous call —
    //    both land together, so Stations never observes "Pro" without also observing "resolved."
    //
    // D. "successful Free first refresh -> not pending + Free": identical code path to C —
    //    apply(_:) sets `revenueCatIsPro = false` and resolves in the same call regardless of
    //    which way the entitlement came back.
    //
    // E. "failed first refresh -> not pending": refreshCustomerInfoNow()'s catch branch calls
    //    `markInitialEntitlementResolutionCompleteIfNeeded()` right after preserving
    //    `revenueCatIsPro` via `revenueCatIsProAfterFailedRefresh` (tested in section F above) —
    //    a terminal failure still ends the pending window, with `revenueCatIsPro` at its safe
    //    default/previous value, never leaving Stations behind an indefinite loading shell.
    //
    // F. "missing configuration/key -> not pending eventually": configureIfNeeded()'s
    //    `guard let apiKey = RevenueCatConfiguration.publicSDKKey else { ... }` branch sets
    //    `initialEntitlementResolutionState = .resolved` directly, before returning — this is not
    //    "eventually," it's immediate, since there is no async fetch to wait for in this branch.
    //
    // G. "later foreground refresh does not become initial-pending again": nothing in this
    //    feature ever assigns `.notStarted`/`.resolving` after the fact —
    //    `markInitialEntitlementResolutionCompleteIfNeeded()` is the ONLY place
    //    `initialEntitlementResolutionState` is written after configureIfNeeded()'s own two
    //    initial writes (`.resolving`, and the missing-key `.resolved`), and it only ever writes
    //    `.resolved` (a no-op once already there) — there is no code path in this file that can
    //    move the state backward. EightyFiveBlendsApp's scenePhase -> .active handler calls
    //    refreshCustomerInfoNow() again, which reaches this same idempotent guard.
    //
    // H. "purchase/restore does not become initial-pending again": purchase(_:) and restore()
    //    both call apply(_:) on success, which reaches the same idempotent
    //    `markInitialEntitlementResolutionCompleteIfNeeded()` — never `.notStarted`/`.resolving`.
    //    Their failure (`catch`) branches never call apply(_:) or touch
    //    `initialEntitlementResolutionState` at all, so a failed purchase/restore cannot regress
    //    it either.

    // MARK: J. Purchase/restore/entitlement stay plan-agnostic — 85Blends 2.4.0
    //
    // Sections A-D above (entitlement interpretation, purchase outcome, restore outcome) did not
    // change for this feature and needed no new tests: `PurchaseOutcome`, `RestoreOutcome`, and
    // `isProEntitlementActive(entitlementIsActive:)` never took a product ID or plan parameter
    // before this feature and still don't — their signatures are the proof. Concretely:
    //   - SubscriptionManager.purchasePro(_:) resolves a plan to its Package via
    //     RevenueCatSubscriptionService.package(for:) and then calls the SAME purchase(_:) as
    //     before (SubscriptionManager.swift) — a missing package for the requested plan is
    //     guarded before that call (logged, no-op; see purchasePro(_:)'s own header), so
    //     purchase(_:) itself, and therefore purchaseOutcome(...)/state(forPurchaseOutcome:),
    //     never receives or needs to know which plan was purchased. Cancellation still maps to
    //     `.idle` (never an error), and a non-throwing-but-not-entitled result is still `.failed`
    //     — never `.succeeded` — regardless of which plan was attempted (section C above).
    //   - restorePurchases() takes no plan parameter at all and never did — a restore reactivates
    //     whatever `pro` entitlement RevenueCat's CustomerInfo reports, regardless of which of the
    //     three plans originally granted it (section D above).
    //   - isProEntitlementActive(entitlementIsActive:) and every canAccess* feature gate read only
    //     `entitlements["pro"]?.isActive` — never a product/plan identifier — so an existing
    //     Monthly subscriber's Pro access is byte-for-byte the same check as a new 3-Month or
    //     Annual subscriber's, both before and after this feature (section A above).
    // Verified by code inspection (this file's header explains why RevenueCat SDK types can't be
    // safely faked to exercise this end-to-end), the same reasoning already established for items
    // 13/20/22 above — not a new runtime assertion, since sections A-D's existing tests already
    // exhaustively cover these functions' actual, unchanged behavior.
}
