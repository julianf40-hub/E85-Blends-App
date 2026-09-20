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
//  ever being returned. Racing via unstructured Tasks avoids that: the winner's result is returned
//  immediately, and the loser receives a best-effort cancellation REQUEST (see `RaceTaskRegistry`
//  below). Two things are true about that request, and neither is optional:
//    1. It can never be silently lost due to registration timing — `RaceTaskRegistry` remembers a
//       cancellation requested before the loser's `Task` handle is even registered, and applies it
//       the instant registration happens (see that type's own header for the race this closes).
//    2. It is still only a REQUEST. Cancellation in Swift is cooperative: a cancellable operation
//       like `Task.sleep` stops promptly once cancelled, but if `AppTransaction.shared` itself
//       never checks `Task.isCancelled`/`Task.checkCancellation()`, the unstructured Task wrapping
//       it can remain suspended until StoreKit itself eventually returns — this file does NOT, and
//       cannot, guarantee that a genuinely non-cooperative `AppTransaction.shared` can never leak a
//       suspended Task. What IS guaranteed regardless: `firstResult` itself still returns within
//       `timeout` every time, since the winner is decided independently of whether the loser ever
//       actually stops.
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
/// cancellation). `FirstResumeGuard` ensures only the FIRST result is ever delivered to the
/// caller; the loser is then explicitly `.cancel()`-ed via `RaceTaskRegistry` below — best-effort
/// cleanup only (see this file's header), never something the caller's own result depends on.
func firstResult<T: Sendable>(
    operation: @escaping @Sendable () async -> T,
    timeout: @escaping @Sendable () async -> T
) async -> T {
    await withCheckedContinuation { continuation in
        let resumeGuard = FirstResumeGuard<T>()
        let registry = RaceTaskRegistry()

        let operationTask = Task {
            let result = await operation()
            if await resumeGuard.resume(with: result, continuation: continuation) {
                registry.cancelTimeoutTask()
            }
        }
        let timeoutTask = Task {
            let result = await timeout()
            if await resumeGuard.resume(with: result, continuation: continuation) {
                registry.cancelOperationTask()
            }
        }
        // Registration happens immediately after both task handles are created. If a racer wins
        // before registration completes, RaceTaskRegistry's sticky cancellation-request flags
        // preserve the request and apply it once the sibling handle is registered — see that
        // type's own header for the exact race this closes. RaceTaskRegistry is a plain
        // NSLock-backed class specifically so this registration needs no `await` (this closure
        // isn't async), matching this test target's existing TestGate/TestFlag pattern for the
        // same reason.
        registry.register(operationTask: operationTask, timeoutTask: timeoutTask)
    }
}

/// Ensures a `CheckedContinuation` is resumed exactly once even though two independent,
/// unstructured `Task`s race to resume it — resuming a `CheckedContinuation` more than once is a
/// runtime trap, and this actor's own serialized `hasResumed` check is what makes "first result
/// wins, second is silently discarded" safe under real concurrency (not just in the common case
/// where one result happens to arrive well before the other). Returns whether THIS call was the
/// one that actually won — `firstResult` uses that to cancel the loser exactly once, never twice
/// and never for the winner itself.
private actor FirstResumeGuard<T: Sendable> {
    private var hasResumed = false

    @discardableResult
    func resume(with value: T, continuation: CheckedContinuation<T, Never>) -> Bool {
        guard hasResumed == false else { return false }
        hasResumed = true
        continuation.resume(returning: value)
        return true
    }
}

/// Holds the two racing `Task` handles so the winner can cancel its sibling — a plain
/// `NSLock`-backed class (not an actor) so `register(operationTask:timeoutTask:)` can be called
/// synchronously right after both `Task`s are created, from `firstResult`'s own non-async
/// continuation body.
///
/// PRE-REGISTRATION CANCELLATION RACE (closed) — a newly created `Task` can begin running on a
/// different OS thread immediately, genuinely in parallel with the thread still executing
/// `firstResult`'s synchronous continuation body. If a racer's own closure completes near-
/// instantly (a trivially fast `operation`/`timeout`, exactly as several of this file's own tests
/// deliberately construct), it can win `FirstResumeGuard` and call `cancelTimeoutTask()`/
/// `cancelOperationTask()` BEFORE `register(operationTask:timeoutTask:)` has run on the other
/// thread — at which point the naive version of this type (read the stored `Task?`, call
/// `.cancel()` if non-nil) would find `nil` and silently drop the cancellation request forever,
/// even though the loser's handle is registered moments later. `operationCancellationRequested`/
/// `timeoutCancellationRequested` close that window: a cancellation requested before registration
/// is remembered and applied the instant `register` actually stores that task's handle, so a
/// cancellation request can never be silently lost purely due to timing — see
/// `EightyFiveBlendsTests/ReferralManagerTests.swift`'s own `RaceTaskRegistryTests` for
/// deterministic (gate-based, not timing-based) proof of exactly this ordering. `Task.cancel()`
/// itself is only ever invoked AFTER releasing `lock`, never while held.
///
/// Not `private` (this file's other single-use-site types stay `private`) specifically so
/// `RaceTaskRegistryTests` can construct and drive one directly with full control over call
/// order — the only way to test the pre-registration race deterministically rather than via
/// scheduling luck.
final class RaceTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var operationCancellationRequested = false
    private var timeoutCancellationRequested = false

    func register(operationTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        self.operationTask = operationTask
        self.timeoutTask = timeoutTask
        let shouldCancelOperation = operationCancellationRequested
        let shouldCancelTimeout = timeoutCancellationRequested
        lock.unlock()

        if shouldCancelOperation {
            operationTask.cancel()
        }
        if shouldCancelTimeout {
            timeoutTask.cancel()
        }
    }

    func cancelOperationTask() {
        lock.lock()
        if let operationTask {
            lock.unlock()
            operationTask.cancel()
        } else {
            operationCancellationRequested = true
            lock.unlock()
        }
    }

    func cancelTimeoutTask() {
        lock.lock()
        if let timeoutTask {
            lock.unlock()
            timeoutTask.cancel()
        } else {
            timeoutCancellationRequested = true
            lock.unlock()
        }
    }
}
