//
//  ReferralAwareProPurchaseCoordinatorTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.0 — Refer & Earn paywall integration. Tests
//  ReferralAwareProPurchaseCoordinator.purchase(normalizedCode:alreadyAppliedCode:applyReferralCode:purchase:)
//  in full isolation: every test here uses plain local closures and counters — never a real
//  ReferralManager/SubscriptionManager, no networking, no RevenueCat/StoreKit. This is exactly
//  what that type's own header promises is possible. `@MainActor` because the coordinator itself
//  is `@MainActor` (see that file). Reuses TestGate/TestFlag already defined in
//  ReferralManagerTests.swift (same test target, no import needed).
//
//  PRE-PURCHASE-RETRY REGRESSION (85Blends 2.4.0 pre-merge pass) — a real sequence: a Free user
//  applies a referral code, the apply succeeds (backend attribution is now immutable), and the
//  user then cancels Apple's own StoreKit purchase sheet before it completes. The paywall's local
//  `referralCodeInput` is never cleared (the field is simply hidden once applied), so a second
//  Unlock tap used to see a non-empty, STALE `normalizedCode` and re-show the confirmation dialog,
//  which could re-call `applyReferralCode` on an already-applied code and block a perfectly valid
//  purchase retry behind a `referralAlreadyApplied` failure. `alreadyAppliedCode` fixes this: see
//  the "Already-applied backend state wins over stale local input" MARK section below.
//

import Testing
import Foundation
@testable import EightyFiveBlends

/// Lets the cooperative scheduler run everything currently runnable, so a test can assert a
/// negative ("purchase has NOT started yet") deterministically instead of via a `Task.sleep`
/// guess — mirrors ReferralManagerTests.swift's own private `settleScheduler()` exactly (not
/// reachable from this file, so redefined locally).
private func settleScheduler(iterations: Int = 20) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}

private func makeStatus(referredByCode: String?) -> ReferralStatus {
    ReferralStatus(
        referralCode: "ABCD2345",
        qualifiedReferrals: 0,
        pendingReferrals: 0,
        earnedMonthsAvailable: 0,
        fulfilledMonths: 0,
        nextMilestoneNumber: 1,
        nextRewardAt: 5,
        referralsNeeded: 5,
        canApplyReferralCode: false,
        referredByCode: referredByCode,
        referredStatus: referredByCode == nil ? nil : "pending"
    )
}

/// Counts calls without introducing a data race: every test here runs entirely on the
/// @MainActor (the coordinator itself is @MainActor-isolated), so a plain non-actor counter class
/// is safe — no two closures in these tests ever run concurrently off that same executor.
@MainActor
private final class CallRecorder {
    private(set) var applyCallCount = 0
    private(set) var lastAppliedCode: String?
    private(set) var purchaseCallCount = 0

    func applyReferralCode(_ code: String) {
        applyCallCount += 1
        lastAppliedCode = code
    }

    func purchase() {
        purchaseCallCount += 1
    }
}

@MainActor
struct ReferralAwareProPurchaseCoordinatorTests {
    // MARK: A. Blank code purchases immediately, with no apply step at all

    @Test("A blank normalized code purchases immediately — apply is never called")
    func blankCode_purchasesImmediately_neverApplies() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "",
            alreadyAppliedCode: nil,
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .purchased)
        #expect(recorder.applyCallCount == 0)
        #expect(recorder.purchaseCallCount == 1)
    }

    // MARK: B. Invalid (non-empty, malformed) code — neither apply nor purchase runs

    @Test(
        "A non-empty code that fails local format validation returns .invalidCode without calling apply or purchase",
        arguments: ["SHORT", "TOOLONGCODE9", "ABCD234O"] // trailing char is a disallowed 'O'
    )
    func invalidCode_neverAppliesOrPurchases(code: String) async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: code,
            alreadyAppliedCode: nil,
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .invalidCode)
        #expect(recorder.applyCallCount == 0)
        #expect(recorder.purchaseCallCount == 0)
    }

    // MARK: C. Valid code, backend-confirmed — apply then purchase, in that order

    @Test("A valid code whose backend-confirmed status echoes the same code applies, then purchases, and reports .purchased")
    func validCode_confirmedByBackend_appliesThenPurchases() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "ABCD2345",
            alreadyAppliedCode: nil,
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .purchased)
        #expect(recorder.applyCallCount == 1)
        #expect(recorder.lastAppliedCode == "ABCD2345")
        #expect(recorder.purchaseCallCount == 1)
    }

    @Test("The exact normalized code string is forwarded to applyReferralCode unchanged — never re-derived or re-normalized")
    func validCode_forwardedExactlyUnchanged() async {
        let recorder = CallRecorder()
        _ = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "ZYXW9876",
            alreadyAppliedCode: nil,
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )

        #expect(recorder.lastAppliedCode == "ZYXW9876")
    }

    // MARK: D/E. apply throws — purchase never runs, message uses the shared error copy

    @Test("A thrown ReferralServiceError never reaches purchase, and its message is exactly ReferralPresentation's own shared copy")
    func applyThrowsServiceError_neverPurchases_usesSharedErrorCopy() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "ABCD2345",
            alreadyAppliedCode: nil,
            applyReferralCode: { _ in throw ReferralServiceError.api(.referralCodeNotFound) },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .applyFailed(message: ReferralPresentation.userFacingMessage(for: .api(.referralCodeNotFound))))
        #expect(recorder.purchaseCallCount == 0)
    }

    @Test("A non-ReferralServiceError thrown by applyReferralCode is mapped to the safe .network fallback copy — never its own localizedDescription")
    func applyThrowsUnexpectedError_mapsToSafeNetworkFallback() async {
        struct SomeOtherError: Error, LocalizedError {
            var errorDescription: String? { "raw underlying description, must never surface" }
        }
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "ABCD2345",
            alreadyAppliedCode: nil,
            applyReferralCode: { _ in throw SomeOtherError() },
            purchase: { recorder.purchase() }
        )

        guard case .applyFailed(let message) = outcome else {
            Issue.record("Expected .applyFailed, got \(outcome)")
            return
        }
        #expect(message.contains("raw underlying description") == false)
        #expect(recorder.purchaseCallCount == 0)
    }

    // MARK: F. Backend-returned status doesn't echo the submitted code — defense in depth

    @Test("A backend response whose referredByCode doesn't match the submitted code reports .confirmationMismatch and never purchases")
    func mismatchedConfirmation_neverPurchases() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "ABCD2345",
            alreadyAppliedCode: nil,
            applyReferralCode: { _ in makeStatus(referredByCode: "SOMEOTHR") },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .confirmationMismatch)
        #expect(recorder.purchaseCallCount == 0)
    }

    @Test("A backend response with a nil referredByCode (should never happen for a successful apply) also reports .confirmationMismatch, never purchasing on an unconfirmed attribution")
    func nilConfirmation_neverPurchases() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "ABCD2345",
            alreadyAppliedCode: nil,
            applyReferralCode: { _ in makeStatus(referredByCode: nil) },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .confirmationMismatch)
        #expect(recorder.purchaseCallCount == 0)
    }

    // MARK: G/H. purchase() is invoked at most once, across every outcome

    @Test(
        "purchase() is called at most once for any single coordinator invocation, regardless of outcome",
        arguments: [
            ("", true),           // blank code -> purchases
            ("ABCD2345", true),   // confirmed -> purchases
            ("BADCODE!", false),  // invalid -> never purchases
        ] as [(String, Bool)]
    )
    func purchase_calledAtMostOnce(code: String, shouldPurchase: Bool) async {
        let recorder = CallRecorder()
        _ = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: code,
            alreadyAppliedCode: nil,
            applyReferralCode: { submitted in makeStatus(referredByCode: submitted) },
            purchase: { recorder.purchase() }
        )
        #expect(recorder.purchaseCallCount == (shouldPurchase ? 1 : 0))
    }

    // MARK: I. Ordering — apply must fully complete before purchase is ever invoked

    @Test("purchase() is not invoked until applyReferralCode's own await has resolved — the ordering guarantee this type exists for")
    func purchaseNeverStartsBeforeApplyCompletes() async {
        let applyGate = TestGate()
        let purchaseStarted = TestFlag()
        let applyObservedPurchaseNotYetStarted = TestFlag()

        let task = Task { @MainActor in
            await ReferralAwareProPurchaseCoordinator.purchase(
                normalizedCode: "ABCD2345",
                alreadyAppliedCode: nil,
                applyReferralCode: { code in
                    await applyGate.wait()
                    await applyObservedPurchaseNotYetStarted.set(await purchaseStarted.get() == false)
                    return makeStatus(referredByCode: code)
                },
                purchase: {
                    await purchaseStarted.set(true)
                }
            )
        }

        // Give the apply closure a chance to reach its gate before opening it — proves purchase
        // genuinely waits on apply, rather than merely happening to run after it by coincidence.
        await settleScheduler()
        #expect(await purchaseStarted.get() == false)

        applyGate.open()
        _ = await task.value

        #expect(await applyObservedPurchaseNotYetStarted.get())
        #expect(await purchaseStarted.get())
    }

    // MARK: J. The coordinator's own await genuinely completes only after purchase's await does

    @Test("The coordinator call does not return until purchase()'s own async work has finished — not fire-and-forget")
    func coordinatorAwaitsPurchaseToCompletion() async {
        let purchaseGate = TestGate()
        let purchaseCompleted = TestFlag()

        let task = Task { @MainActor in
            await ReferralAwareProPurchaseCoordinator.purchase(
                normalizedCode: "",
                alreadyAppliedCode: nil,
                applyReferralCode: { code in makeStatus(referredByCode: code) },
                purchase: {
                    await purchaseGate.wait()
                    await purchaseCompleted.set(true)
                }
            )
        }

        await settleScheduler()
        #expect(await purchaseCompleted.get() == false)

        purchaseGate.open()
        _ = await task.value

        #expect(await purchaseCompleted.get())
    }

    // MARK: - Already-applied backend state wins over stale local input (regression: cancelled-purchase retry)
    //
    // See this file's own "PRE-PURCHASE-RETRY REGRESSION" header. In every test below,
    // `normalizedCode` stands in for the paywall's stale, hidden `referralCodeInput` — it must
    // never be read at all once `alreadyAppliedCode` is non-empty.

    @Test("Phase 7.A: already-applied + the SAME stale input purchases directly — apply is never re-called")
    func alreadyApplied_sameStaleInput_purchasesWithoutReapplying() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "5SDC95NB",
            alreadyAppliedCode: "5SDC95NB",
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .purchased)
        #expect(recorder.applyCallCount == 0)
        #expect(recorder.purchaseCallCount == 1)
    }

    @Test("Phase 7.B: already-applied + a DIFFERENT valid stale input still purchases directly — backend attribution wins, apply never re-called")
    func alreadyApplied_differentValidStaleInput_purchasesWithoutReapplying() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "ABCD2345",
            alreadyAppliedCode: "5SDC95NB",
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .purchased)
        #expect(recorder.applyCallCount == 0)
        #expect(recorder.purchaseCallCount == 1)
    }

    @Test("Phase 7.C: already-applied + a MALFORMED stale input still purchases directly — the hidden field can never block a legitimate retry")
    func alreadyApplied_malformedStaleInput_purchasesWithoutBlocking() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "BAD!",
            alreadyAppliedCode: "5SDC95NB",
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .purchased)
        #expect(recorder.applyCallCount == 0)
        #expect(recorder.purchaseCallCount == 1)
    }

    @Test("Phase 7.D (load-bearing): first apply-then-cancel, then a retry with the stale field still populated — apply count stays at 1 while purchase count advances to 2")
    func firstApplyThenCancelledPurchase_retryHonorsBackendStateAndNeverReapplies() async {
        let recorder = CallRecorder()

        // First invocation: no backend attribution exists yet — a genuinely new code is applied
        // and confirmed, then purchase() runs (SubscriptionManager's own purchase flow; the
        // coordinator itself doesn't own or observe StoreKit's cancel outcome — see this type's
        // own header — so "the user cancelled Apple's sheet" is simulated simply by the purchase
        // closure returning normally, exactly as it already does on any purchase() outcome).
        let firstOutcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "5SDC95NB",
            alreadyAppliedCode: nil,
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )
        #expect(firstOutcome == .purchased)
        #expect(recorder.applyCallCount == 1)
        #expect(recorder.purchaseCallCount == 1)

        // Second invocation: the user tapped Unlock again after cancelling Apple's purchase
        // sheet. Backend attribution now exists ("5SDC95NB"), but the paywall's own stale,
        // hidden referralCodeInput/normalizedCode is intentionally still "5SDC95NB" too — this is
        // exactly the bug scenario, and alreadyAppliedCode must make it irrelevant.
        let secondOutcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "5SDC95NB",
            alreadyAppliedCode: "5SDC95NB",
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )
        #expect(secondOutcome == .purchased)

        // The load-bearing assertions: apply is NEVER called a second time (no
        // referralAlreadyApplied risk), while purchase legitimately runs again for the retry.
        #expect(recorder.applyCallCount == 1)
        #expect(recorder.purchaseCallCount == 2)
    }

    @Test("Phase 7.E: no applied code + a valid NEW code still applies before purchasing — existing ordering is unchanged by alreadyAppliedCode's addition")
    func noAppliedCode_validNewCode_stillAppliesBeforePurchasing() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "5SDC95NB",
            alreadyAppliedCode: nil,
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .purchased)
        #expect(recorder.applyCallCount == 1)
        #expect(recorder.lastAppliedCode == "5SDC95NB")
        #expect(recorder.purchaseCallCount == 1)
    }

    @Test("Phase 7.F: no applied code + an invalid code neither applies nor purchases — existing behavior is unchanged by alreadyAppliedCode's addition")
    func noAppliedCode_invalidCode_neverAppliesOrPurchases() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "BAD!",
            alreadyAppliedCode: nil,
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .invalidCode)
        #expect(recorder.applyCallCount == 0)
        #expect(recorder.purchaseCallCount == 0)
    }

    @Test("An empty alreadyAppliedCode string is treated identically to nil — never mistaken for a real applied code")
    func emptyStringAlreadyAppliedCode_treatedAsAbsent() async {
        let recorder = CallRecorder()
        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: "5SDC95NB",
            alreadyAppliedCode: "",
            applyReferralCode: { code in
                recorder.applyReferralCode(code)
                return makeStatus(referredByCode: code)
            },
            purchase: { recorder.purchase() }
        )

        #expect(outcome == .purchased)
        #expect(recorder.applyCallCount == 1)
        #expect(recorder.purchaseCallCount == 1)
    }
}
