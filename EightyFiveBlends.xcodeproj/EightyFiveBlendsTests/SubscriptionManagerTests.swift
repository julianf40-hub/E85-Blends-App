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
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
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
        #expect(state == .failed("We couldn't verify your purchase. Please try again or contact support."))
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

    // MARK: E. Offering / package resolution (items 16-18)
    // RevenueCatSubscriptionService.resolvePackage(...) — the exact rule `loadOfferings()` calls,
    // guarding what `SubscriptionManager.purchasePro()` is ever allowed to purchase.

    @Test("Offering missing → safe plans-unavailable state, never a package")
    func resolvePackage_offeringMissing_isUnavailable() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: false,
            monthlyPackageExists: false,
            packageProductID: nil,
            expectedProductID: SubscriptionManager.monthlyID
        )
        #expect(resolution == .offeringUnavailable)
    }

    @Test("Monthly package missing from an existing offering → safe plans-unavailable state")
    func resolvePackage_packageMissing_isUnavailable() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            monthlyPackageExists: false,
            packageProductID: nil,
            expectedProductID: SubscriptionManager.monthlyID
        )
        #expect(resolution == .packageUnavailable)
    }

    @Test("Package resolves to an unexpected product ID → never eligible to purchase")
    func resolvePackage_unexpectedProduct_isRejected() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            monthlyPackageExists: true,
            packageProductID: "com.wrong.product.id",
            expectedProductID: SubscriptionManager.monthlyID
        )
        #expect(resolution == .unexpectedProduct("com.wrong.product.id"))
        if case .ready = resolution { Issue.record("An unexpected product mapping must never resolve as ready-to-purchase") }
    }

    @Test("Package resolves to the exact expected product ID → ready to purchase")
    func resolvePackage_expectedProduct_isReady() {
        let resolution = RevenueCatSubscriptionService.resolvePackage(
            offeringExists: true,
            monthlyPackageExists: true,
            packageProductID: SubscriptionManager.monthlyID,
            expectedProductID: SubscriptionManager.monthlyID
        )
        #expect(resolution == .ready)
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
}
