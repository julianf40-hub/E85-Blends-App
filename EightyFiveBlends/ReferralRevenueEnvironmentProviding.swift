//
//  ReferralRevenueEnvironmentProviding.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — iOS referral client foundation. Determines whether this install is running in
//  the App Store SANDBOX or PRODUCTION environment — required by referral-api's `bootstrap`
//  action (revenuecat_environment) BEFORE any purchase, since a referral attribution must be
//  applied before the qualifying purchase happens (see referral-api's own task spec).
//
//  This deliberately does NOT use RevenueCat's `EntitlementInfo.isSandbox` (see
//  RevenueCatSubscriptionService.isSandboxEnvironment): that field is only populated once an
//  entitlement RECORD exists, which requires a purchase attempt to have already happened — exactly
//  what referral bootstrap must run before. It also deliberately does NOT infer environment from
//  `#if DEBUG`, the bundle receipt filename, or Pro status: TestFlight builds are Release
//  configuration (never DEBUG) but ARE sandbox — any of those would misclassify a TestFlight
//  installation as PRODUCTION.
//
//  StoreKit 2's `AppTransaction` is the authoritative source used instead: it reflects this
//  app's own original download/install environment and is available from first launch, on any
//  build channel, with no purchase required — introduced in iOS 16.0, well within this app's
//  minimum deployment targets (17.6 App Store / 26.4 Internal — see CLAUDE.md), so no
//  availability fallback is needed.
//
//  CORRECTNESS HARDENING PASS (2.4.0) — VERIFIED ONLY: an `.unverified` AppTransaction is no
//  longer treated as authoritative. `AppTransaction.shared`'s cryptographic signature check exists
//  specifically to guard against a tampered/replayed transaction; accepting `.unverified` here
//  would mean the SANDBOX-vs-PRODUCTION routing decision for referral attribution timing could be
//  spoofed by exactly the same class of attack StoreKit's own verification is meant to catch. An
//  unverified result now maps to `nil` — "try again later" — like any other unavailable signal,
//  never a guess.
//
//  TestFlight still correctly maps to SANDBOX under this stricter rule: a TestFlight install's own
//  AppTransaction verifies successfully (Apple signs it) and its `environment` reports `.sandbox`
//  — TestFlight builds are Release-configuration but are never production App Store purchases, so
//  this is `.verified(.sandbox)`, not `.unverified`. Requiring verification does not reintroduce
//  the DEBUG/receipt-filename/Pro-status misclassification this file's own header already rules
//  out — those remain unused.
//
//  BOUNDED WAIT (85Blends 2.4.0, Part A of the referral onboarding/paywall pass) — a real-device
//  report showed Refer & Earn stuck on an indefinite generic spinner because `AppTransaction.shared`
//  had no explicit bound; `currentEnvironment()` now always returns within `timeout`, racing the
//  real StoreKit call against a plain `Task.sleep` via `firstResult(operation:timeout:)` below.
//  Never guesses on timeout — it returns exactly what an unavailable signal already returns, `nil`
//  — and `ReferralManager.performBootstrap()` treats a timeout identically to any other
//  unavailable-signal case: `.waitingForStoreEnvironment` + `ReferralServiceError.notConfigured`,
//  never a permanently-stuck bootstrap attempt. `firstResult` deliberately races two UNSTRUCTURED
//  `Task`s joined by a `CheckedContinuation`, not two `TaskGroup` children: a `TaskGroup`'s
//  enclosing `withTaskGroup` call cannot return until every child task has actually finished
//  (cancellation is cooperative, and `AppTransaction.shared` is not guaranteed to observe it
//  promptly) — so a slow/hung `AppTransaction.shared` could still block the "timed out" result from
//  ever being returned. Racing via unstructured Tasks avoids that: the loser simply keeps running
//  in the background, unobserved and harmless, while the winner's result is returned immediately.
//

import Foundation
import StoreKit

protocol ReferralRevenueEnvironmentProviding: Sendable {
    /// `nil` when no authoritative signal could be obtained this call — AppTransaction
    /// unreachable, unavailable, unverified, or the bounded wait timed out (see this file's
    /// header). Callers must treat that as "try again later," never guess.
    func currentEnvironment() async -> ReferralRevenueEnvironment?
}

struct StoreKitReferralRevenueEnvironmentProvider: ReferralRevenueEnvironmentProviding {
    /// Injectable so tests can substitute a near-instant bound instead of waiting out the real
    /// production value — see this file's own "BOUNDED WAIT" header. A nearby value (6-8s) is
    /// fine; this stays a little under the low end of that range so referral setup resolves
    /// promptly on a real device without ever guessing.
    var timeout: Duration = Self.defaultTimeout
    static let defaultTimeout: Duration = .seconds(5)

    func currentEnvironment() async -> ReferralRevenueEnvironment? {
        await firstResult(
            operation: { await Self.resolveVerifiedEnvironment() },
            timeout: {
                try? await Task.sleep(for: timeout)
                return nil
            }
        )
    }

    /// The exact pre-existing VERIFIED-ONLY mapping — unchanged by the bounded-wait addition
    /// above. Not independently unit-tested in this target: constructing a real
    /// `VerificationResult<AppTransaction>` (verified or unverified) requires StoreKitTest's
    /// `SKTestSession`, which needs a running host application/UI-test target this Swift Testing
    /// unit-test suite does not have — see ReferralManagerTests.swift's own
    /// `provider_roundTripsBothCases` header for the identical, already-established rationale.
    private static func resolveVerifiedEnvironment() async -> ReferralRevenueEnvironment? {
        guard let result = try? await AppTransaction.shared else { return nil }

        // VERIFIED ONLY — see this file's header. An unverified result is deliberately discarded
        // here rather than read for its environment value, however plausible that value might be.
        guard case .verified(let transaction) = result else { return nil }

        switch transaction.environment {
        case .production:
            return .production
        case .sandbox, .xcode:
            return .sandbox
        default:
            return nil
        }
    }
}

/// Races two async closures and returns whichever produces a result FIRST. Generic and
/// StoreKit-agnostic on purpose — see this file's own "BOUNDED WAIT" header for exactly why this
/// uses unstructured `Task`s joined by a continuation rather than a `TaskGroup` (whose enclosing
/// call cannot return until every child finishes, even a cancelled one that never observes
/// cancellation). The loser is never explicitly cancelled — it simply keeps running in the
/// background; `FirstResumeGuard` ensures only the FIRST result is ever delivered to the caller,
/// and the loser's own eventual result is silently discarded.
func firstResult<T: Sendable>(
    operation: @escaping @Sendable () async -> T,
    timeout: @escaping @Sendable () async -> T
) async -> T {
    await withCheckedContinuation { continuation in
        let resumeGuard = FirstResumeGuard<T>()
        Task {
            let result = await operation()
            await resumeGuard.resume(with: result, continuation: continuation)
        }
        Task {
            let result = await timeout()
            await resumeGuard.resume(with: result, continuation: continuation)
        }
    }
}

/// Ensures a `CheckedContinuation` is resumed exactly once even though two independent,
/// unstructured `Task`s race to resume it — resuming a `CheckedContinuation` more than once is a
/// runtime trap, and this actor's own serialized `hasResumed` check is what makes "first result
/// wins, second is silently discarded" safe under real concurrency (not just in the common case
/// where one result happens to arrive well before the other).
private actor FirstResumeGuard<T: Sendable> {
    private var hasResumed = false

    func resume(with value: T, continuation: CheckedContinuation<T, Never>) {
        guard hasResumed == false else { return }
        hasResumed = true
        continuation.resume(returning: value)
    }
}
