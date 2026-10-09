//
//  ProActivationTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.1 (GitHub issue #122) — regression tests for the explicit "Activate Pro" action that
//  reconciles an Apple Offer Code redeemed OUTSIDE the app. These exercise the real production types
//  (`ProActivationRunner`, `ProActivationProgress`) and the real pure functions they sit beside; only
//  the three runner seams are faked, mirroring how `ReferralPresentation.reconcileAfterRedemption`
//  is tested. The fakes model exactly one thing — the single RevenueCat entitlement flag
//  (`revenueCatIsPro`) and the existing `syncAfterExternalRedemption()` call — and never grant Pro
//  themselves: a test only sees Pro when the fake "sync" explicitly flips that flag, the way a real
//  CustomerInfo applied through `apply(_:)` would.
//
//  What this CANNOT prove (same limit as SubscriptionManagerTests.swift's header): RevenueCat's
//  `CustomerInfo` has no constructible fake, and `RevenueCatSubscriptionService` can't reach
//  `.configured` without a real SDK key, so that Apple's redemption is actually imported by
//  `Purchases.shared.syncPurchases()` is a TestFlight/manual fact (see the PR's QA matrix).
//  Unchanged-by-inspection: EightyFiveBlendsApp's scenePhase handler still only calls
//  `refreshCustomerInfoNow()`, and no foreground/appear/timer path calls the sync.
//

import Testing
import Foundation
@testable import EightyFiveBlends

// MARK: - Test doubles

/// The three seams `ProActivationRunner.shared` wires to the live singletons.
@MainActor
private final class ActivationHarness {
    var isConfigured = true
    /// Stands in for `RevenueCatSubscriptionService.revenueCatIsPro`.
    var isPro = false
    /// What the existing `syncAfterExternalRedemption()` Bool would be: "the call worked".
    var syncReturns = true
    /// Runs inside the fake sync — lets a test play the part of a CustomerInfo being applied.
    var duringSync: (@MainActor () async -> Void)?
    private(set) var syncCalls = 0
    var joined = 0

    func makeRunner() -> ProActivationRunner {
        ProActivationRunner(
            isConfigured: { self.isConfigured },
            isProActive: { self.isPro },
            sync: {
                self.syncCalls += 1
                await self.duringSync?()
                return self.syncReturns
            }
        )
    }
}

/// Holds a fake sync open so a test can start overlapping requests while it is provably in flight.
/// Tracks EVERY waiter, so if single-flight ever regresses and a second sync starts, the test fails
/// on its `syncCalls` expectation instead of hanging on a leaked continuation.
@MainActor
private final class SyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var hasEntered = false

    func pass() async {
        hasEntered = true
        guard isOpen == false else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume() }
    }

    /// Bounded, so a regression fails the test instead of hanging the run.
    func waitUntilEntered() async -> Bool {
        for _ in 0..<1_000 {
            if hasEntered { return true }
            await Task.yield()
        }
        return hasEntered
    }
}

/// `#expect`/`#require` evaluate their argument on an immutable copy, so a mutating call such as
/// `begin()` can't appear inside them — bind it first.
private func beginAttempt(_ progress: inout ProActivationProgress) throws -> Int {
    let token = progress.begin()
    return try #require(token)
}

// MARK: - A. Outcome decision (ProActivationRunner)

@MainActor
struct ProActivationRunnerTests {

    @Test("External redemption that RevenueCat confirms → .proActive after exactly one sync")
    func externalRedemption_returnsActivePro() async {
        let harness = ActivationHarness()
        harness.duringSync = { harness.isPro = true }
        let outcome = await harness.makeRunner().run()
        #expect(outcome == .proActive)
        #expect(harness.syncCalls == 1)
    }

    @Test("A sync that succeeds but leaves no active entitlement is .notConfirmed — never success")
    func syncSucceeds_withoutEntitlement_isNotConfirmed() async {
        let harness = ActivationHarness()
        harness.syncReturns = true
        let outcome = await harness.makeRunner().run()
        #expect(outcome == .notConfirmed)
        #expect(outcome != .proActive)
        #expect(harness.isPro == false)
    }

    @Test("A failed sync is .failed and does not invent an entitlement")
    func syncFails_isFailed() async {
        let harness = ActivationHarness()
        harness.syncReturns = false
        let outcome = await harness.makeRunner().run()
        #expect(outcome == .failed)
        #expect(harness.syncCalls == 1)
        #expect(harness.isPro == false)
    }

    @Test("Already Pro → .alreadyPro with NO sync (no needless alias/transfer exposure)")
    func alreadyPro_skipsSync() async {
        let harness = ActivationHarness()
        harness.isPro = true
        let outcome = await harness.makeRunner().run()
        #expect(outcome == .alreadyPro)
        #expect(harness.syncCalls == 0)
    }

    @Test("RevenueCat not configured → .unavailable with no sync attempted")
    func notConfigured_isUnavailable() async {
        let harness = ActivationHarness()
        harness.isConfigured = false
        let outcome = await harness.makeRunner().run()
        #expect(outcome == .unavailable)
        #expect(harness.syncCalls == 0)
    }

    @Test("Double tap: a second request while the first sync is in flight joins it — one sync, same outcome")
    func doubleTap_sharesOneSync() async {
        let harness = ActivationHarness()
        let gate = SyncGate()
        harness.duringSync = { await gate.pass(); harness.isPro = true }
        let runner = harness.makeRunner()

        let first = Task { await runner.run() }
        #expect(await gate.waitUntilEntered())      // the first sync is now suspended mid-flight

        let second = Task { harness.joined += 1; return await runner.run() }
        while harness.joined < 1 { await Task.yield() }   // joined, and suspended inside run()
        gate.open()

        #expect(await first.value == .proActive)
        #expect(await second.value == .proActive)
        #expect(harness.syncCalls == 1)
    }

    @Test("Many overlapping requests (re-presented paywall, two screens) still produce a single sync")
    func manyOverlappingRequests_produceOneSync() async {
        let harness = ActivationHarness()
        let gate = SyncGate()
        harness.syncReturns = true
        harness.duringSync = { await gate.pass() }
        let runner = harness.makeRunner()

        let first = Task { await runner.run() }
        #expect(await gate.waitUntilEntered())

        let joiners = (0..<5).map { _ in Task { harness.joined += 1; return await runner.run() } }
        while harness.joined < 5 { await Task.yield() }
        gate.open()

        var outcomes = [await first.value]
        for joiner in joiners { outcomes.append(await joiner.value) }
        #expect(outcomes.allSatisfy { $0 == .notConfirmed })
        #expect(harness.syncCalls == 1)
    }

    @Test("The in-flight slot is released: a manual retry after completion does a fresh check")
    func retryAfterCompletion_runsAFreshSync() async {
        let harness = ActivationHarness()
        let runner = harness.makeRunner()

        #expect(await runner.run() == .notConfirmed)
        #expect(harness.syncCalls == 1)

        harness.duringSync = { harness.isPro = true }   // RevenueCat has caught up by the retry
        #expect(await runner.run() == .proActive)
        #expect(harness.syncCalls == 2)
    }

    @Test("Scene change mid-sync: a foreground refresh that applies Pro while the sync is outstanding wins, with no extra sync")
    func sceneChangeMidSync_authoritativeEntitlementWins() async {
        let harness = ActivationHarness()
        harness.syncReturns = false                       // the sync itself reports failure …
        harness.duringSync = { harness.isPro = true }     // … but the foreground refresh applied Pro meanwhile
        let outcome = await harness.makeRunner().run()
        #expect(outcome == .proActive)                    // the entitlement, not the sync Bool, decides
        #expect(harness.syncCalls == 1)                   // the transition caused no second sync
    }

    @Test("A transient failure never clears an existing Pro entitlement")
    func transientFailure_keepsExistingPro() async {
        let harness = ActivationHarness()
        harness.isPro = true
        harness.syncReturns = false
        #expect(await harness.makeRunner().run() == .alreadyPro)
        #expect(harness.isPro)
        // The production rule behind refreshCustomerInfoNow()'s catch block, pinned alongside.
        #expect(RevenueCatSubscriptionService.revenueCatIsProAfterFailedRefresh(previousValue: true))
    }
}

// MARK: - B. Presentation state (ProActivationProgress)

struct ProActivationProgressTests {

    @Test("Starts idle with no message")
    func startsIdle() {
        let progress = ProActivationProgress()
        #expect(progress.phase == .idle)
        #expect(progress.message == nil)
    }

    @Test("Double tap: begin() while an attempt is in flight is refused")
    func doubleTap_isRefused() {
        var progress = ProActivationProgress()
        let token = progress.begin()
        #expect(token != nil)
        #expect(progress.phase == .checking)
        let duplicate = progress.begin()
        #expect(duplicate == nil)
        #expect(progress.phase == .checking)
    }

    @Test("Only an active entitlement ever maps to .activated; every other outcome is non-success")
    func outcomeMapping() {
        #expect(ProActivationProgress.phase(for: .proActive) == .activated)
        #expect(ProActivationProgress.phase(for: .alreadyPro) == .activated)
        #expect(ProActivationProgress.phase(for: .notConfirmed) == .notConfirmed)
        #expect(ProActivationProgress.phase(for: .failed) == .failed)
        #expect(ProActivationProgress.phase(for: .unavailable) == .failed)
    }

    @Test("finish() applies the outcome for the attempt in flight")
    func finish_appliesOutcome() throws {
        var progress = ProActivationProgress()
        let token = try beginAttempt(&progress)
        progress.finish(.notConfirmed, token: token)
        #expect(progress.phase == .notConfirmed)
    }

    @Test("A stale response cannot overwrite a newer attempt")
    func staleResponse_cannotOverwriteNewer() throws {
        var progress = ProActivationProgress()
        let stale = try beginAttempt(&progress)
        progress.reset()                                   // the screen was left mid-flight
        let current = try beginAttempt(&progress)       // and a newer attempt started

        progress.finish(.proActive, token: stale)          // the old response finally lands
        #expect(progress.phase == .checking)               // ignored

        progress.finish(.notConfirmed, token: current)
        #expect(progress.phase == .notConfirmed)
    }

    @Test("A response that arrives after the screen was left is inert")
    func responseAfterReset_isInert() throws {
        var progress = ProActivationProgress()
        let token = try beginAttempt(&progress)
        progress.reset()
        progress.finish(.proActive, token: token)
        #expect(progress.phase == .idle)
        #expect(progress.message == nil)
    }

    @Test("A finished attempt can't be overwritten by a duplicate completion")
    func duplicateCompletion_isIgnored() throws {
        var progress = ProActivationProgress()
        let token = try beginAttempt(&progress)
        progress.finish(.notConfirmed, token: token)
        progress.finish(.proActive, token: token)
        #expect(progress.phase == .notConfirmed)
    }

    @Test("After a non-success the user can try again")
    func retryAllowedAfterNonSuccess() throws {
        for outcome in [ProActivationOutcome.notConfirmed, .failed, .unavailable] {
            var progress = ProActivationProgress()
            let token = try beginAttempt(&progress)
            progress.finish(outcome, token: token)
            let retry = progress.begin()
            #expect(retry != nil)
            #expect(progress.phase == .checking)
        }
    }

    @Test("Copy is exact, and only the activated state ever says Pro is active")
    func copy() throws {
        #expect(ProActivationProgress.checkingMessage == "Checking your subscription…")
        #expect(ProActivationProgress.activatedMessage == "85Blends Pro is active.")
        #expect(ProActivationProgress.notConfirmedMessage == "Activation can take a moment. Try again or Restore Purchases.")
        #expect(ProActivationProgress.failedMessage.contains("Restore Purchases"))

        for outcome in [ProActivationOutcome.proActive, .alreadyPro, .notConfirmed, .failed, .unavailable] {
            var progress = ProActivationProgress()
            let token = try beginAttempt(&progress)
            #expect(progress.message == ProActivationProgress.checkingMessage)
            progress.finish(outcome, token: token)
            let claimsActive = (progress.message ?? "").lowercased().contains("is active")
            #expect(claimsActive == (progress.phase == .activated))
        }
    }
}

// MARK: - C. Existing behavior this fix must not disturb

@MainActor
struct ProActivationDoesNotDisturbExistingBehaviorTests {

    @Test("Restore Purchases mappings are unchanged (Activate Pro neither calls nor reuses Restore)")
    func restorePurchases_unchanged() {
        #expect(SubscriptionManager.state(forRestoreOutcome: .proActive, wasProBefore: false) == .restored)
        #expect(SubscriptionManager.state(forRestoreOutcome: .proActive, wasProBefore: true) == .info("85Blends Pro is active."))
        #expect(SubscriptionManager.state(forRestoreOutcome: .noActivePro, wasProBefore: false) == .info("No active subscription found."))
        #expect(SubscriptionManager.state(forRestoreOutcome: .failed("x"), wasProBefore: false) == .failed("We couldn't restore your purchases. Please try again."))
        #expect(SubscriptionManager.restoreFeedback(for: .proActive) == .restored)
        #expect(SubscriptionManager.restoreFeedback(for: .noActivePro) == .noActiveSubscription)
        #expect(SubscriptionManager.restoreFeedback(for: .failed("x")) == .failed)
    }

    @Test("All plans, including the legacy quarterly product, stay governed by the single plan-agnostic `pro` entitlement")
    func planAgnosticEntitlement() {
        let legacyQuarterly = "com.85blends.subscription.quarterly"
        #expect(RevenueCatSubscriptionService.proEntitlementID == "pro")
        #expect(ProPlan.allCases.map(\.productID) == [
            "com.85blends.subscription.monthly",
            "com.85blends.subscription.threemonth",
            "com.85blends.subscription.annual",
        ])
        #expect(ProPlan.allCases.map(\.productID).contains(legacyQuarterly) == false)
        // The decision takes only the entitlement's own flag — no product or plan input exists.
        #expect(RevenueCatSubscriptionService.isProEntitlementActive(entitlementIsActive: true))
        #expect(RevenueCatSubscriptionService.isProEntitlementActive(entitlementIsActive: nil) == false)
    }

    @Test("Referral entry stays closed to a Pro user, and an unconfirmed activation changes nothing")
    func referralEligibility_unaffectedByActivation() async {
        func eligibility(isPro: Bool) -> ReferralPresentation.EntryEligibility {
            ReferralPresentation.entryEligibility(
                canApplyReferralCode: true,
                isCurrentlyPro: isPro,
                isEntitlementResolutionPending: false,
                hasAuthoritativeProStatus: true
            )
        }
        #expect(eligibility(isPro: false) == .allowed)

        let unconfirmed = ActivationHarness()
        _ = await unconfirmed.makeRunner().run()                  // sync worked, no entitlement
        #expect(eligibility(isPro: unconfirmed.isPro) == .allowed)

        let confirmed = ActivationHarness()
        confirmed.duringSync = { confirmed.isPro = true }
        #expect(await confirmed.makeRunner().run() == .proActive)
        #expect(eligibility(isPro: confirmed.isPro) == .blockedAlreadyPro)
    }

    @Test("A confirmed activation propagates through the existing feature-gate and widget-mirror rules; an unconfirmed one publishes nothing")
    func proChangePropagates() async {
        let confirmed = ActivationHarness()
        confirmed.duringSync = { confirmed.isPro = true }
        #expect(await confirmed.makeRunner().run() == .proActive)

        let mirrored = NearbyE85WidgetAccessPublisher.mirroredStatus(
            isPro: confirmed.isPro, hasAuthoritativeProStatus: true, isDebugProOverrideActive: false
        )
        #expect(mirrored == .pro)
        #expect(NearbyE85WidgetAccessPublisher.transition(previous: .free, current: mirrored) == .publish(.pro))
        #if DEBUG || INTERNAL_BUILD
        #expect(SubscriptionManager.effectivePro(override: .off, revenueCatIsPro: confirmed.isPro))
        #endif

        // No authoritative answer applied → nothing is mirrored, so nothing can be downgraded either.
        let unconfirmed = ActivationHarness()
        #expect(await unconfirmed.makeRunner().run() == .notConfirmed)
        #expect(NearbyE85WidgetAccessPublisher.mirroredStatus(
            isPro: unconfirmed.isPro, hasAuthoritativeProStatus: false, isDebugProOverrideActive: false
        ) == nil)
        #expect(NearbyE85WidgetAccessPublisher.transition(previous: nil, current: nil) == .hold)
    }
}
