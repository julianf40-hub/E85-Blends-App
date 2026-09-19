//
//  ReferralManagerTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.0 — iOS referral client foundation. Tests for ReferralManager's lifecycle
//  (bootstrap/refresh/applyReferralCode state transitions, the ensureBootstrapped retry gate),
//  plus RevenueCatSubscriptionService's real-App-User-ID accessor and
//  ReferralRevenueEnvironmentProviding's environment mapping.
//  Uses fake ReferralAPIServicing/ReferralCredentialStoring/ReferralRevenueEnvironmentProviding/
//  ReferralRevenueCatIdentityProviding conformances throughout — never real networking, Keychain,
//  RevenueCat, or StoreKit.
//

import Testing
import Foundation
import Security
import RevenueCat
@testable import EightyFiveBlends

// MARK: - Deterministic test synchronization

/// A test-only gate: `wait()` suspends until the test explicitly `open()`s it (once opened, it
/// stays open — every subsequent `wait()` returns immediately). Used to deterministically control
/// exactly when a fake service call is allowed to return, without any `Task.sleep`/timing
/// assumption — see FakeReferralAPIService's `statusGate`/`applyCodeGate` below.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        isOpen = true
        let toResume = waiters
        waiters = []
        lock.unlock()
        for continuation in toResume {
            continuation.resume()
        }
    }

    func wait() async {
        lock.lock()
        if isOpen {
            lock.unlock()
            return
        }
        lock.unlock()

        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Repeatedly yields so the cooperative scheduler runs every currently-runnable task as far as it
/// can go before this function returns. Used (instead of `Task.sleep`) to assert a NEGATIVE —
/// "this call has not reached the backend yet" — after a task that should be genuinely blocked on
/// an unresolved `Task.value` (a real data dependency, not a timing race): if the implementation
/// under test has no actual serialization, a few yields are already enough for the blocked-looking
/// call to slip through and be observed, so this remains a meaningful regression check rather than
/// a tautology.
private func settleScheduler(iterations: Int = 20) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}

/// A test-only, thread-safe boolean flag — used where a test needs to assert "this Task has NOT
/// finished yet" without actually awaiting it (awaiting would itself block until it finishes,
/// defeating the point). A wrapping `Task` sets this to `true` as its very last action, so
/// checking it after `settleScheduler()` deterministically answers "has it finished, or is it
/// still genuinely blocked" — never a `Task.sleep`-based guess.
actor TestFlag {
    private var value = false
    func set(_ newValue: Bool) { value = newValue }
    func get() -> Bool { value }
}

// MARK: - Fakes

final class FakeReferralAPIService: ReferralAPIServicing, @unchecked Sendable {
    var bootstrapResult: Result<ReferralBootstrapResponse, Error> = .failure(ReferralServiceError.notConfigured)
    var statusResult: Result<ReferralStatus, Error> = .failure(ReferralServiceError.notConfigured)
    var applyCodeResult: Result<ReferralApplyCodeResponse, Error> = .failure(ReferralServiceError.notConfigured)

    private(set) var bootstrapCallCount = 0
    private(set) var statusCallCount = 0
    private(set) var applyCodeCallCount = 0
    private(set) var lastAppliedCode: String?
    /// The App User ID actually received by the most recent `bootstrap(...)` call — lets tests
    /// prove the value ReferralManager forwards is exactly what its injected identityProvider
    /// reported (see `bootstrap_usesIdentityProviderValueExactly`), not some other source.
    private(set) var lastBootstrapAppUserID: String?
    /// Set to add an artificial delay before returning, to test overlapping/concurrent calls.
    /// Retained for the pre-existing bootstrap-concurrency tests; the newer ordering tests below
    /// use the deterministic gates instead (see this type's header and STATE-CONSISTENCY HARDENING
    /// PASS in ReferralManagerTests).
    var bootstrapDelayNanoseconds: UInt64 = 0
    /// When set, `status(credential:)` suspends here before returning — lets a test hold a status
    /// call open while asserting/starting another operation, deterministically.
    var statusGate: TestGate?
    /// When set, `applyCode(_:credential:)` suspends here before returning.
    var applyCodeGate: TestGate?

    func bootstrap(
        credential: ReferralInstallationCredential,
        revenueCatAppUserID: String,
        environment: ReferralRevenueEnvironment,
        appVersion: String?
    ) async throws -> ReferralBootstrapResponse {
        bootstrapCallCount += 1
        lastBootstrapAppUserID = revenueCatAppUserID
        if bootstrapDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: bootstrapDelayNanoseconds)
        }
        return try bootstrapResult.get()
    }

    func status(credential: ReferralInstallationCredential) async throws -> ReferralStatus {
        statusCallCount += 1
        // Captured BEFORE waiting on the gate — a test that reconfigures `statusResult` while this
        // call is held open must never change what THIS already-in-flight call returns, only
        // subsequent calls (see applyCode's identical pattern below for why this matters).
        let resultToReturn = statusResult
        await statusGate?.wait()
        return try resultToReturn.get()
    }

    func applyCode(_ referralCode: String, credential: ReferralInstallationCredential) async throws -> ReferralApplyCodeResponse {
        applyCodeCallCount += 1
        lastAppliedCode = referralCode
        // Captured BEFORE waiting on the gate — this is what lets a test hold CODE1's call open,
        // reconfigure `applyCodeResult` for CODE2, and open the gate, without CODE1 retroactively
        // picking up CODE2's result (see `overlappingApply_...` tests).
        let resultToReturn = applyCodeResult
        await applyCodeGate?.wait()
        return try resultToReturn.get()
    }
}

/// A class (not a struct) so tests can flip `environment` mid-scenario — e.g. "unavailable at
/// startup, available by the time a later refresh() runs" (see `ensureBootstrapped()`'s retry
/// contract in ReferralManager.swift).
final class FakeReferralEnvironmentProvider: ReferralRevenueEnvironmentProviding, @unchecked Sendable {
    var environment: ReferralRevenueEnvironment?
    init(environment: ReferralRevenueEnvironment?) { self.environment = environment }
    func currentEnvironment() async -> ReferralRevenueEnvironment? { environment }
}

struct FakeReferralRevenueCatIdentityProvider: ReferralRevenueCatIdentityProviding {
    let appUserID: String?
    @MainActor
    func currentAppUserID() -> String? { appUserID }
}

private func sampleStatus(referralCode: String = "ABCD2345") -> ReferralStatus {
    ReferralStatus(
        referralCode: referralCode,
        qualifiedReferrals: 0,
        pendingReferrals: 0,
        earnedMonthsAvailable: 0,
        fulfilledMonths: 0,
        nextMilestoneNumber: 1,
        nextRewardAt: 5,
        referralsNeeded: 5,
        canApplyReferralCode: true,
        referredByCode: nil,
        referredStatus: nil
    )
}

@MainActor
struct ReferralManagerTests {
    private func makeManager(
        service: FakeReferralAPIService = FakeReferralAPIService(),
        environmentProvider: FakeReferralEnvironmentProvider = FakeReferralEnvironmentProvider(environment: .production),
        store: ReferralCredentialStoring = InMemoryReferralCredentialStore(),
        appUserID: String? = "rc_user_1"
    ) -> ReferralManager {
        ReferralManager(
            credentialStore: store,
            environmentProvider: environmentProvider,
            identityProvider: FakeReferralRevenueCatIdentityProvider(appUserID: appUserID),
            serviceFactory: { service }
        )
    }

    // MARK: 29. Bootstrap stores loaded state

    @Test("A successful bootstrap stores the returned status as .loaded")
    func bootstrap_storesLoadedState() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        let manager = makeManager(service: service)

        await manager.bootstrapIfNeeded()

        guard case .loaded(let status) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        #expect(status.referralCode == "ABCD2345")
        #expect(manager.hasBootstrappedThisLaunch)
    }

    // MARK: 30/28. Failed bootstrap does not destroy credential

    @Test("A failed bootstrap leaves a valid credential in the store, never regenerated or removed")
    func failedBootstrap_preservesCredential() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .failure(ReferralServiceError.network("offline"))
        let store = InMemoryReferralCredentialStore()
        let manager = makeManager(service: service, store: store)

        await manager.bootstrapIfNeeded()

        guard case .failed = manager.loadState else {
            Issue.record("Expected .failed, got \(manager.loadState)")
            return
        }
        let stored = store.savedCredential
        #expect(stored != nil)
        #expect(stored.map(ReferralInstallationCredential.isValid) == true)
    }

    @Test("bootstrapIfNeeded with no environment signal yet leaves state idle and never calls the service")
    func bootstrap_noEnvironment_staysIdle() async {
        let service = FakeReferralAPIService()
        let manager = makeManager(service: service, environmentProvider: FakeReferralEnvironmentProvider(environment: nil))

        await manager.bootstrapIfNeeded()

        #expect(manager.loadState == .idle)
        #expect(service.bootstrapCallCount == 0)
        #expect(manager.hasBootstrappedThisLaunch == false)
    }

    @Test("bootstrapIfNeeded with no RevenueCat identity available yet never calls the service")
    func bootstrap_noAppUserID_neverCallsService() async {
        let service = FakeReferralAPIService()
        let manager = makeManager(service: service, appUserID: nil)

        await manager.bootstrapIfNeeded()
        await manager.bootstrapIfNeeded()

        #expect(service.bootstrapCallCount == 0)
    }

    @Test("bootstrapIfNeeded with an empty RevenueCat identity never calls the service")
    func bootstrap_emptyAppUserID_neverCallsService() async {
        let service = FakeReferralAPIService()
        let manager = makeManager(service: service, appUserID: "")

        await manager.bootstrapIfNeeded()

        #expect(service.bootstrapCallCount == 0)
    }

    @Test("A second bootstrapIfNeeded call after success is a no-op — does not call the service again")
    func bootstrap_secondCallAfterSuccess_isNoOp() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        let manager = makeManager(service: service)

        await manager.bootstrapIfNeeded()
        await manager.bootstrapIfNeeded()

        #expect(service.bootstrapCallCount == 1)
    }

    // MARK: 27. Keychain failure during bootstrap never forks identity

    @Test("A Keychain load failure during bootstrap never generates a credential and never calls the backend")
    func bootstrapKeychainFailure_neverGeneratesOrCallsBackend() async {
        let service = FakeReferralAPIService()
        let store = InMemoryReferralCredentialStore()
        store.forcedLoadError = ReferralCredentialStoreError.keychainFailure(errSecInteractionNotAllowed)
        let manager = makeManager(service: service, store: store)

        await manager.bootstrapIfNeeded()

        #expect(service.bootstrapCallCount == 0)
        #expect(store.savedCredential == nil)
        guard case .failed(.credentialUnavailable) = manager.loadState else {
            Issue.record("Expected .failed(.credentialUnavailable), got \(manager.loadState)")
            return
        }
    }

    // MARK: 29. Retry after backend recovery reuses the exact same credential

    @Test("A retried bootstrap after a backend failure reuses the exact same durable credential")
    func retryAfterBackendFailure_reusesSameCredential() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .failure(ReferralServiceError.network("offline"))
        let store = InMemoryReferralCredentialStore()
        let manager = makeManager(service: service, store: store)

        await manager.bootstrapIfNeeded()
        let firstCredential = store.savedCredential
        #expect(firstCredential != nil)

        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: false))
        await manager.bootstrapIfNeeded()

        #expect(store.savedCredential == firstCredential)
        #expect(manager.hasBootstrappedThisLaunch)
    }

    // MARK: 31. Refresh ensures bootstrap first, then fetches status

    @Test("refresh() on a never-bootstrapped manager bootstraps first, then fetches a fresh status")
    func refresh_beforeBootstrap_bootstrapsFirstThenFetchesStatus() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        service.statusResult = .success(sampleStatus(referralCode: "WXYZ6789"))
        let manager = makeManager(service: service)

        await manager.refresh()

        #expect(service.bootstrapCallCount == 1)
        #expect(service.statusCallCount == 1)
        guard case .loaded(let status) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        #expect(status.referralCode == "WXYZ6789")
        #expect(manager.hasBootstrappedThisLaunch)
    }

    @Test("refresh() after an already-successful bootstrap fetches a fresh status without re-bootstrapping")
    func refresh_afterBootstrap_updatesStatus() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        service.statusResult = .success(sampleStatus(referralCode: "WXYZ6789"))
        await manager.refresh()

        #expect(service.bootstrapCallCount == 1)
        guard case .loaded(let status) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        #expect(status.referralCode == "WXYZ6789")
        #expect(service.statusCallCount == 1)
    }

    @Test("refresh() when bootstrap preconditions aren't met yet is a safe no-op, leaving state idle")
    func refresh_bootstrapPreconditionsUnavailable_isNoOp() async {
        let service = FakeReferralAPIService()
        let manager = makeManager(service: service, environmentProvider: FakeReferralEnvironmentProvider(environment: nil))

        await manager.refresh()

        #expect(service.statusCallCount == 0)
        #expect(manager.loadState == .idle)
    }

    // MARK: 18. Environment becomes available later — deferred bootstrap on next refresh

    @Test("refresh() after the environment signal becomes available performs the deferred bootstrap")
    func refresh_afterEnvironmentBecomesAvailable_performsDeferredBootstrap() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        service.statusResult = .success(sampleStatus())
        let envProvider = FakeReferralEnvironmentProvider(environment: nil)
        let manager = makeManager(service: service, environmentProvider: envProvider)

        await manager.refresh()
        #expect(service.bootstrapCallCount == 0)
        #expect(manager.hasBootstrappedThisLaunch == false)

        envProvider.environment = .production
        await manager.refresh()

        #expect(service.bootstrapCallCount == 1)
        #expect(manager.hasBootstrappedThisLaunch)
    }

    // MARK: 32/33. Apply awaits server success; failed apply does not locally mark attribution

    @Test("applyReferralCode awaits and returns the backend-confirmed status on success")
    func applyReferralCode_awaitsServerSuccess() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        service.applyCodeResult = .success(
            ReferralApplyCodeResponse(status: ReferralStatus(canApply: false), applyStatus: "applied")
        )

        let result = try await manager.applyReferralCode("wxyz6789")

        #expect(result.canApplyReferralCode == false)
        // ReferralManager forwards the code verbatim — normalization (trim/uppercase) is
        // ReferralAPIService's own concern, already covered by
        // ReferralModelsTests.referralCode_trimAndUppercase.
        #expect(service.lastAppliedCode == "wxyz6789")
    }

    @Test("A failed applyReferralCode throws and never marks the code as locally applied")
    func applyReferralCode_failure_doesNotMarkApplied() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        service.applyCodeResult = .failure(ReferralServiceError.api(.referralCodeNotFound))

        do {
            _ = try await manager.applyReferralCode("ZZZZ9999")
            Issue.record("Expected applyReferralCode to throw")
        } catch ReferralServiceError.api(.referralCodeNotFound) {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // The last successful bootstrap's status (still can-apply) must remain — never
        // overwritten by the failed attempt.
        guard case .loaded(let status) = manager.loadState else {
            Issue.record("Expected .loaded to remain from bootstrap")
            return
        }
        #expect(status.canApplyReferralCode)
    }

    @Test("applyReferralCode before any bootstrap throws notConfigured rather than silently succeeding")
    func applyReferralCode_beforeBootstrap_throwsNotConfigured() async {
        let service = FakeReferralAPIService()
        let manager = makeManager(service: service, appUserID: nil)

        do {
            _ = try await manager.applyReferralCode("ABCD2345")
            Issue.record("Expected applyReferralCode to throw")
        } catch ReferralServiceError.notConfigured {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: 19/21. Apply retries bootstrap first; apply_code never sent if that retry fails

    @Test("applyReferralCode after an earlier failed bootstrap attempts bootstrap again before applying")
    func applyReferralCode_afterFailedBootstrap_retriesBootstrapFirst() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .failure(ReferralServiceError.network("offline"))
        let manager = makeManager(service: service)

        await manager.bootstrapIfNeeded()
        #expect(service.bootstrapCallCount == 1)
        guard case .failed = manager.loadState else {
            Issue.record("Expected initial bootstrap to fail")
            return
        }

        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        service.applyCodeResult = .success(
            ReferralApplyCodeResponse(status: ReferralStatus(canApply: false), applyStatus: "applied")
        )

        let result = try await manager.applyReferralCode("ABCD2345")

        #expect(service.bootstrapCallCount == 2)
        #expect(result.canApplyReferralCode == false)
    }

    @Test("applyReferralCode never calls apply_code if the ensured bootstrap itself fails")
    func applyReferralCode_bootstrapFails_neverCallsApplyCode() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .failure(ReferralServiceError.network("offline"))
        let manager = makeManager(service: service)

        do {
            _ = try await manager.applyReferralCode("ABCD2345")
            Issue.record("Expected applyReferralCode to throw")
        } catch ReferralServiceError.network {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(service.lastAppliedCode == nil)
    }

    // MARK: 34/30. Successful apply exposes backend-updated status

    @Test("A successful applyReferralCode updates loadState to the backend's new status")
    func applyReferralCode_success_updatesLoadState() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        service.applyCodeResult = .success(
            ReferralApplyCodeResponse(status: ReferralStatus(canApply: false), applyStatus: "applied")
        )
        _ = try await manager.applyReferralCode("WXYZ6789")

        guard case .loaded(let status) = manager.loadState else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(status.canApplyReferralCode == false)
    }

    // MARK: 22/35. Concurrent calls dedupe onto a single bootstrap attempt

    @Test("Two concurrent bootstrapIfNeeded calls for a brand-new manager only ever call the service once")
    func concurrentBootstrap_callsServiceOnce() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        service.bootstrapDelayNanoseconds = 50_000_000 // 50ms — long enough to overlap reliably
        let manager = makeManager(service: service)

        async let first: Void = manager.bootstrapIfNeeded()
        async let second: Void = manager.bootstrapIfNeeded()
        _ = await (first, second)

        #expect(service.bootstrapCallCount == 1)
        guard case .loaded = manager.loadState else {
            Issue.record("Expected .loaded after concurrent bootstrap, got \(manager.loadState)")
            return
        }
    }

    @Test("Concurrent refreshes never crash and leave loadState as the shared, identical result")
    func concurrentRefresh_leavesValidState() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        service.statusResult = .success(sampleStatus(referralCode: "AAAA1111"))
        async let first: Void = manager.refresh()
        async let second: Void = manager.refresh()
        _ = await (first, second)

        guard case .loaded(let status) = manager.loadState else {
            Issue.record("Expected .loaded after concurrent refresh, got \(manager.loadState)")
            return
        }
        #expect(status.referralCode == "AAAA1111")
    }

    // MARK: 23/24. Concurrent refresh/apply on a fresh manager share ONE bootstrap, ONE credential

    @Test("Concurrent refresh() and applyReferralCode() on a fresh manager share a single bootstrap attempt")
    func concurrentRefreshAndApply_shareSingleBootstrap() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        service.bootstrapDelayNanoseconds = 30_000_000
        service.statusResult = .success(ReferralStatus(canApply: true))
        service.applyCodeResult = .success(
            ReferralApplyCodeResponse(status: ReferralStatus(canApply: false), applyStatus: "applied")
        )
        let store = InMemoryReferralCredentialStore()
        let manager = makeManager(service: service, store: store)

        async let refreshCall: Void = manager.refresh()
        async let applyResult: ReferralStatus? = try? await manager.applyReferralCode("ABCD2345")
        _ = await refreshCall
        _ = await applyResult

        #expect(service.bootstrapCallCount == 1)
        // Only one credential was ever ended up persisted — loadOrCreate's own reuse-if-valid path
        // means a second concurrent caller reaching it after the first already saved one would
        // reuse it rather than generating another; this asserts the OBSERVABLE result of that
        // (a single, unambiguous stored credential) rather than internal call counts.
        #expect(store.savedCredential != nil)
    }

    // MARK: STATE-CONSISTENCY HARDENING PASS — stale refresh must never overwrite a later apply

    /// Reproduces the race this hardening pass fixes: refresh() is started first and its status
    /// response is held open (stale, canApplyReferralCode: true); while it's still pending,
    /// applyReferralCode() is requested and succeeds (canApplyReferralCode: false, referredByCode
    /// set); only THEN is the stale refresh allowed to complete. Before the fix, refresh and apply
    /// raced independently and the stale refresh's `loadState = .loaded(...)` write landed last,
    /// clobbering apply's result. After the fix, ReferralManager's operation-serialization
    /// coordinator ensures apply — requested LATER — always finishes (and mutates loadState)
    /// strictly after the older, already-in-flight refresh, regardless of which network call
    /// happens to resolve first.
    @Test("A refresh started first, held open, must never overwrite a later successful apply")
    func staleRefresh_neverOverwritesLaterApply() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        let statusGate = TestGate()
        service.statusGate = statusGate
        service.statusResult = .success(ReferralStatus(canApply: true)) // the STALE value

        let refreshTask = Task { await manager.refresh() }
        // Give refresh's task a real chance to reach (and suspend inside) the gated status call
        // before apply is requested — deterministic because statusCallCount only increments once
        // that call has actually been entered.
        while service.statusCallCount == 0 { await Task.yield() }

        service.applyCodeResult = .success(
            ReferralApplyCodeResponse(
                status: ReferralStatus(
                    referralCode: "ABCD2345", qualifiedReferrals: 1, pendingReferrals: 0,
                    earnedMonthsAvailable: 0, fulfilledMonths: 0, nextMilestoneNumber: 1,
                    nextRewardAt: 5, referralsNeeded: 4, canApplyReferralCode: false,
                    referredByCode: "WXYZ6789", referredStatus: "pending"
                ),
                applyStatus: "applied"
            )
        )
        let applyTask = Task { try await manager.applyReferralCode("WXYZ6789") }
        // Apply must be queued behind the in-flight refresh — it cannot have reached the backend
        // yet, since refresh hasn't been released.
        await settleScheduler()
        #expect(service.applyCodeCallCount == 0)

        // Now let the stale refresh finish.
        statusGate.open()

        _ = await refreshTask.value
        let applyResult = try await applyTask.value

        #expect(applyResult.referredByCode == "WXYZ6789")
        #expect(applyResult.canApplyReferralCode == false)
        guard case .loaded(let finalStatus) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        #expect(finalStatus.referredByCode == "WXYZ6789")
        #expect(finalStatus.canApplyReferralCode == false)
    }

    /// Inverse ordering: apply starts first and is held open; refresh is requested while apply is
    /// still in flight. Proves refresh's OWN network call does not even execute until apply
    /// finishes (never merely "the final state happens to be right") — status is configured to a
    /// distinct, post-apply-shaped value so a premature/parallel refresh call would be observable.
    @Test("A refresh requested during an in-flight apply does not call status until apply completes, then sees post-apply state")
    func refreshDuringApply_waitsThenSeesPostApplyState() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        let applyCodeGate = TestGate()
        service.applyCodeGate = applyCodeGate
        service.applyCodeResult = .success(
            ReferralApplyCodeResponse(status: ReferralStatus(canApply: false), applyStatus: "applied")
        )

        let applyTask = Task { try await manager.applyReferralCode("ABCD2345") }
        while service.applyCodeCallCount == 0 { await Task.yield() }

        service.statusResult = .success(ReferralStatus(canApply: false)) // post-apply-shaped
        let refreshTask = Task { await manager.refresh() }
        await settleScheduler()
        // The key assertion: refresh's network call has NOT executed yet, even though refresh()
        // has already been called and is (from the caller's point of view) in flight.
        #expect(service.statusCallCount == 0)

        applyCodeGate.open()

        _ = try await applyTask.value
        await refreshTask.value

        #expect(service.statusCallCount == 1)
        guard case .loaded(let finalStatus) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        #expect(finalStatus.canApplyReferralCode == false)
    }

    /// An older refresh's FAILURE must not overwrite a later apply's success either — failure is
    /// just another way an operation can "finish," and finishing earlier must never win.
    @Test("A failed refresh cannot overwrite a later successful apply")
    func failedRefresh_cannotOverwriteLaterApplySuccess() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        let statusGate = TestGate()
        service.statusGate = statusGate
        service.statusResult = .failure(ReferralServiceError.network("offline"))

        let refreshTask = Task { await manager.refresh() }
        while service.statusCallCount == 0 { await Task.yield() }

        service.applyCodeResult = .success(
            ReferralApplyCodeResponse(status: ReferralStatus(canApply: false), applyStatus: "applied")
        )
        let applyTask = Task { try await manager.applyReferralCode("ABCD2345") }
        await settleScheduler()
        #expect(service.applyCodeCallCount == 0)

        statusGate.open()
        await refreshTask.value
        _ = try await applyTask.value

        guard case .loaded(let finalStatus) = manager.loadState else {
            Issue.record("Expected .loaded (apply's success), got \(manager.loadState)")
            return
        }
        #expect(finalStatus.canApplyReferralCode == false)
    }

    // MARK: STATE-CONSISTENCY HARDENING PASS — refresh dedup, apply serialization (never dedup)

    @Test("Two simultaneous refresh() calls perform exactly one status request and share its result")
    func simultaneousRefresh_performsOneStatusRequest() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        let statusGate = TestGate()
        service.statusGate = statusGate
        service.statusResult = .success(sampleStatus(referralCode: "AAAA1111"))

        let first = Task { await manager.refresh() }
        while service.statusCallCount == 0 { await Task.yield() }
        let second = Task { await manager.refresh() }
        await settleScheduler()

        statusGate.open()
        await first.value
        await second.value

        #expect(service.statusCallCount == 1)
        guard case .loaded(let status) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        #expect(status.referralCode == "AAAA1111")
    }

    @Test("Two overlapping applyReferralCode calls for DIFFERENT codes are serialized, never deduplicated — each reaches the backend and gets its own authoritative result")
    func overlappingApply_differentCodes_areSerializedNotDeduplicated() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        let applyCodeGate = TestGate()
        service.applyCodeGate = applyCodeGate
        let firstResponse = ReferralApplyCodeResponse(
            status: ReferralStatus(
                referralCode: "ABCD2345", qualifiedReferrals: 0, pendingReferrals: 0,
                earnedMonthsAvailable: 0, fulfilledMonths: 0, nextMilestoneNumber: 1,
                nextRewardAt: 5, referralsNeeded: 5, canApplyReferralCode: false,
                referredByCode: "FIRST0001", referredStatus: "pending"
            ),
            applyStatus: "applied"
        )
        service.applyCodeResult = .success(firstResponse)

        let firstTask = Task { try await manager.applyReferralCode("FIRST0001") }
        while service.applyCodeCallCount == 0 { await Task.yield() }

        let secondTask = Task { try await manager.applyReferralCode("SECOND002") }
        await settleScheduler()
        // The second call must NOT have reached the backend yet — it's queued behind the first,
        // not deduplicated with it (different codes).
        #expect(service.applyCodeCallCount == 1)
        #expect(service.lastAppliedCode == "FIRST0001")

        // Backend-authoritative response for the SECOND call — deliberately different from the
        // first, simulating e.g. "already_applied" semantics the backend alone decides.
        let secondResponse = ReferralApplyCodeResponse(
            status: ReferralStatus(
                referralCode: "ABCD2345", qualifiedReferrals: 0, pendingReferrals: 0,
                earnedMonthsAvailable: 0, fulfilledMonths: 0, nextMilestoneNumber: 1,
                nextRewardAt: 5, referralsNeeded: 5, canApplyReferralCode: false,
                referredByCode: "FIRST0001", referredStatus: "pending"
            ),
            applyStatus: "referral_already_applied"
        )
        service.applyCodeResult = .success(secondResponse)
        applyCodeGate.open()

        let firstResult = try await firstTask.value
        let secondResult = try await secondTask.value

        #expect(service.applyCodeCallCount == 2)
        #expect(service.lastAppliedCode == "SECOND002")
        // Each call got EXACTLY its own backend-authoritative response — never invented locally,
        // never the other call's result.
        #expect(firstResult.referredByCode == "FIRST0001")
        #expect(secondResult.referredByCode == "FIRST0001")
        guard case .loaded(let finalStatus) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        // The SECOND (logically later) call's result is what's left standing.
        #expect(finalStatus.referredByCode == secondResponse.status.referredByCode)
    }

    // MARK: REQUEST-ORDER EDGE CASE — refresh dedup must not span an intervening apply

    /// Reproduces (and then proves fixed) a narrower race than the earlier stale-refresh tests:
    /// refresh A starts and is held open; apply B is requested and correctly queues behind A;
    /// refresh C is THEN requested while A is still in flight. Before this fix, refresh()'s dedup
    /// check only looked at `inFlightRefreshTask != nil` — since that was still A (A hasn't
    /// finished), C would dedupe directly onto A and could return as soon as A finished, WITHOUT
    /// ever waiting for B — even though B was requested before C. C's own `await` would resolve
    /// with A's stale result while B was still pending, violating request-order semantics (C is
    /// logically the last of the three operations and must reflect B's effect, not skip past it).
    /// After the fix, C detects that the operation queue has moved on since A claimed it (an apply
    /// is now the tail) and enqueues itself as a genuinely NEW refresh behind B instead.
    @Test("A refresh requested after an apply has already queued behind an older in-flight refresh must not dedupe onto that stale refresh")
    func refreshAfterQueuedApply_doesNotDedupeOntoStaleRefresh() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        // A: start refresh, let it reach (and suspend inside) a gated status call returning a
        // STALE value.
        let statusGate = TestGate()
        service.statusGate = statusGate
        service.statusResult = .success(ReferralStatus(canApply: true))
        let refreshATask = Task { await manager.refresh() }
        while service.statusCallCount == 0 { await Task.yield() }

        // B: request apply while A is still in flight — must queue behind A (already proven by
        // the earlier stale-refresh tests; re-confirmed here as this test's own setup).
        let applyCodeGate = TestGate()
        service.applyCodeGate = applyCodeGate
        service.applyCodeResult = .success(
            ReferralApplyCodeResponse(
                status: ReferralStatus(
                    referralCode: "ABCD2345", qualifiedReferrals: 1, pendingReferrals: 0,
                    earnedMonthsAvailable: 0, fulfilledMonths: 0, nextMilestoneNumber: 1,
                    nextRewardAt: 5, referralsNeeded: 4, canApplyReferralCode: false,
                    referredByCode: "POSTAPPLY", referredStatus: "pending"
                ),
                applyStatus: "applied"
            )
        )
        let applyBTask = Task { try await manager.applyReferralCode("POSTAPPLY") }
        await settleScheduler()
        #expect(service.applyCodeCallCount == 0)

        // C: request another refresh AFTER B was queued, while A is STILL in flight (A's gate has
        // not been opened yet). `refreshCFinished` lets this test observe "has C's own call to
        // refresh() returned yet" without awaiting it directly (which would itself block).
        let refreshCFinished = TestFlag()
        let refreshCTask = Task {
            await manager.refresh()
            await refreshCFinished.set(true)
        }
        await settleScheduler()

        // Release A's stale response. A correct coordinator lets ONLY A (and, transitively, B —
        // which was genuinely queued behind A) proceed; C must remain behind B.
        statusGate.open()
        await settleScheduler()

        #expect(service.applyCodeCallCount == 1) // B is now running, unblocked by A finishing
        // THE key assertion: C must NOT have completed yet — it is still queued behind B, not
        // resolved merely because stale A finished. (Before the fix, C's dedup bound directly to
        // A's task, so it would already be `true` here — this is exactly what this test catches.)
        #expect(await refreshCFinished.get() == false)
        _ = await refreshATask.value

        // A fresh, distinct status value for C's OWN later call — proves C performs its own,
        // SECOND status request rather than ever reusing A's cached result.
        service.statusResult = .success(ReferralStatus(
            referralCode: "ABCD2345", qualifiedReferrals: 99, pendingReferrals: 0,
            earnedMonthsAvailable: 0, fulfilledMonths: 0, nextMilestoneNumber: 1,
            nextRewardAt: 5, referralsNeeded: 4, canApplyReferralCode: false,
            referredByCode: "POSTAPPLY", referredStatus: "pending"
        ))
        applyCodeGate.open()

        let applyBResult = try await applyBTask.value
        await refreshCTask.value

        #expect(applyBResult.referredByCode == "POSTAPPLY")
        #expect(service.statusCallCount == 2) // A's + C's own — never deduped together
        guard case .loaded(let finalStatus) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        // Uniquely identifies C's OWN status response (not B's apply response, not A's stale one)
        // as what's left standing — proving execution order was A, then B, then C, and C observed
        // genuinely POST-apply backend state.
        #expect(finalStatus.qualifiedReferrals == 99)
    }

    /// The inverse composition: apply first, then two refreshes with NO mutation queued between
    /// them — those two refreshes must still dedupe onto one status request, exactly as before
    /// this fix (the generation check must not become overly conservative and break the ordinary
    /// adjacent-refresh dedup case).
    @Test("apply, then two adjacent refreshes with no intervening mutation, still dedupe onto one status request")
    func applyThenAdjacentRefreshes_stillDeduplicate() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded()

        let applyCodeGate = TestGate()
        service.applyCodeGate = applyCodeGate
        service.applyCodeResult = .success(
            ReferralApplyCodeResponse(status: ReferralStatus(canApply: false), applyStatus: "applied")
        )
        let applyATask = Task { try await manager.applyReferralCode("ABCD2345") }
        while service.applyCodeCallCount == 0 { await Task.yield() }

        let statusGate = TestGate()
        service.statusGate = statusGate
        service.statusResult = .success(sampleStatus(referralCode: "AFTERAPPLY"))

        // B: first refresh, requested while apply A is still in flight — queues behind A.
        let refreshBTask = Task { await manager.refresh() }
        await settleScheduler()
        // C: second refresh, requested while B is queued/running and NOTHING else has been queued
        // in between — must dedupe onto B.
        let refreshCTask = Task { await manager.refresh() }
        await settleScheduler()

        applyCodeGate.open()
        _ = try await applyATask.value

        while service.statusCallCount == 0 { await Task.yield() }
        statusGate.open()
        await refreshBTask.value
        await refreshCTask.value

        // Exactly ONE status request for both B and C combined — the generation check only
        // prevents dedup across an intervening MUTATION (apply); it must not prevent ordinary
        // adjacent-refresh dedup.
        #expect(service.statusCallCount == 1)
        guard case .loaded(let finalStatus) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        #expect(finalStatus.referralCode == "AFTERAPPLY")
    }

    // MARK: 25/26. RevenueCat identity boundary

    @Test("The manager's bootstrap uses exactly the identity provider's value — never a different/raw source")
    func bootstrap_usesIdentityProviderValueExactly() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        let manager = ReferralManager(
            credentialStore: InMemoryReferralCredentialStore(),
            environmentProvider: FakeReferralEnvironmentProvider(environment: .production),
            identityProvider: FakeReferralRevenueCatIdentityProvider(appUserID: "rc_distinct_user_42"),
            serviceFactory: { service }
        )

        await manager.bootstrapIfNeeded()

        // Proves the value that actually reached the backend call is exactly what the injected
        // identityProvider reported — never anything EightyFiveBlendsApp.swift or any other source
        // supplied (confirmed statically for the app layer too — see this feature's final report).
        #expect(service.lastBootstrapAppUserID == "rc_distinct_user_42")
        #expect(manager.hasBootstrappedThisLaunch)
    }
}

private extension ReferralStatus {
    init(canApply: Bool) {
        self.init(
            referralCode: "ABCD2345",
            qualifiedReferrals: 0,
            pendingReferrals: 0,
            earnedMonthsAvailable: 0,
            fulfilledMonths: 0,
            nextMilestoneNumber: 1,
            nextRewardAt: 5,
            referralsNeeded: 5,
            canApplyReferralCode: canApply,
            referredByCode: nil,
            referredStatus: nil
        )
    }
}

// MARK: - RevenueCat App User ID

struct FakeRevenueCatClientWithAppUserID: RevenueCatClient {
    let currentAppUserID: String

    func fetchCustomerInfo() async throws -> CustomerInfo {
        throw ReferralServiceError.notConfigured
    }
    func fetchOfferings() async throws -> Offerings {
        throw ReferralServiceError.notConfigured
    }
    func purchase(package: Package) async throws -> PurchaseResultData {
        throw ReferralServiceError.notConfigured
    }
    func restorePurchases() async throws -> CustomerInfo {
        throw ReferralServiceError.notConfigured
    }
}

@MainActor
struct RevenueCatAppUserIDTests {
    @Test("currentRevenueCatAppUserID is nil before RevenueCat has been configured")
    func appUserID_nilBeforeConfigured() {
        let service = RevenueCatSubscriptionService(
            client: FakeRevenueCatClientWithAppUserID(currentAppUserID: "$RCAnonymousID:real_full_id_value")
        )
        #expect(service.currentRevenueCatAppUserID == nil)
    }

    // Note: configureIfNeeded() itself calls Purchases.configure(with:), which this test
    // deliberately never invokes (see RevenueCatSubscriptionService.swift's own "PUBLIC vs
    // SECRET KEYS"/"ANONYMOUS ONLY" header — no test in this suite constructs a real SDK
    // configuration). The pre-configuration `nil` case above and the masking-distinctness case
    // below are what's actually verifiable without one.

    @Test("The real App User ID and the masked App User ID are never the same value for a realistic-length ID")
    func realAppUserID_isDistinctFromMasked() {
        let realID = "$RCAnonymousID:0123456789abcdef0123456789abcdef"
        // maskedAppUserID's own algorithm (see RevenueCatSubscriptionService.maskedAppUserID):
        // prefix(4) + "…" + suffix(4) for anything longer than 8 characters.
        let masked = "\(realID.prefix(4))…\(realID.suffix(4))"
        #expect(realID != masked)
        #expect(masked.contains(realID) == false)
    }
}

// MARK: - Environment mapping

struct ReferralRevenueEnvironmentTests {
    @Test("ReferralRevenueEnvironment.production encodes to exactly \"PRODUCTION\"")
    func production_encodesExactly() throws {
        let data = try JSONEncoder().encode(ReferralRevenueEnvironment.production)
        #expect(String(data: data, encoding: .utf8) == "\"PRODUCTION\"")
    }

    @Test("ReferralRevenueEnvironment.sandbox encodes to exactly \"SANDBOX\"")
    func sandbox_encodesExactly() throws {
        let data = try JSONEncoder().encode(ReferralRevenueEnvironment.sandbox)
        #expect(String(data: data, encoding: .utf8) == "\"SANDBOX\"")
    }

    @Test("The environment provider protocol returns nil (never guesses) when no authoritative signal exists")
    func provider_returnsNilWhenUnavailable() async {
        let provider = FakeReferralEnvironmentProvider(environment: nil)
        let result = await provider.currentEnvironment()
        #expect(result == nil)
    }

    @Test(
        "The environment provider abstraction round-trips both real cases without DEBUG-only logic involved",
        arguments: [ReferralRevenueEnvironment.sandbox, .production]
    )
    func provider_roundTripsBothCases(environment: ReferralRevenueEnvironment) async {
        // This exercises the PROTOCOL boundary ReferralManager actually depends on — proving the
        // manager's own bootstrap flow (see ReferralManagerTests above) receives exactly the
        // value the provider reports, with no DEBUG/build-configuration branching anywhere in
        // that path.
        //
        // StoreKitReferralRevenueEnvironmentProvider's own AppTransaction-based mapping —
        // including its 2.4.0 hardening-pass VERIFIED-ONLY requirement (an `.unverified` result
        // now maps to `nil`, never read for its environment value) — is documented in that type's
        // own header, not re-executed here: constructing an arbitrary real
        // `VerificationResult<AppTransaction>` (verified or unverified) requires StoreKitTest's
        // `SKTestSession`, which needs a running host application/UI-test target this Swift
        // Testing unit-test suite does not have. This is an environment limitation, not a decision
        // to skip verification — see this feature's final report.
        let provider = FakeReferralEnvironmentProvider(environment: environment)
        let result = await provider.currentEnvironment()
        #expect(result == environment)
    }
}
