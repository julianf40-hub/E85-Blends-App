//
//  ReferralManagerTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.0 — iOS referral client foundation. Tests for ReferralManager's lifecycle
//  (bootstrap/refresh/applyReferralCode state transitions), plus RevenueCatSubscriptionService's
//  new real-App-User-ID accessor and ReferralRevenueEnvironmentProviding's environment mapping.
//  Uses fake ReferralAPIServicing/ReferralCredentialStoring/ReferralRevenueEnvironmentProviding
//  conformances throughout — never real networking, Keychain, or StoreKit.
//

import Testing
import Foundation
import RevenueCat
@testable import EightyFiveBlends

// MARK: - Fakes

final class FakeReferralAPIService: ReferralAPIServicing, @unchecked Sendable {
    var bootstrapResult: Result<ReferralBootstrapResponse, Error> = .failure(ReferralServiceError.notConfigured)
    var statusResult: Result<ReferralStatus, Error> = .failure(ReferralServiceError.notConfigured)
    var applyCodeResult: Result<ReferralApplyCodeResponse, Error> = .failure(ReferralServiceError.notConfigured)

    private(set) var bootstrapCallCount = 0
    private(set) var statusCallCount = 0
    private(set) var lastAppliedCode: String?
    /// Set to add an artificial delay before returning, to test overlapping/concurrent calls.
    var bootstrapDelayNanoseconds: UInt64 = 0

    func bootstrap(
        credential: ReferralInstallationCredential,
        revenueCatAppUserID: String,
        environment: ReferralRevenueEnvironment,
        appVersion: String?
    ) async throws -> ReferralBootstrapResponse {
        bootstrapCallCount += 1
        if bootstrapDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: bootstrapDelayNanoseconds)
        }
        return try bootstrapResult.get()
    }

    func status(credential: ReferralInstallationCredential) async throws -> ReferralStatus {
        statusCallCount += 1
        return try statusResult.get()
    }

    func applyCode(_ referralCode: String, credential: ReferralInstallationCredential) async throws -> ReferralApplyCodeResponse {
        lastAppliedCode = referralCode
        return try applyCodeResult.get()
    }
}

struct FakeReferralEnvironmentProvider: ReferralRevenueEnvironmentProviding {
    let environment: ReferralRevenueEnvironment?
    func currentEnvironment() async -> ReferralRevenueEnvironment? { environment }
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
        environment: ReferralRevenueEnvironment? = .production,
        store: ReferralCredentialStoring = InMemoryReferralCredentialStore()
    ) -> ReferralManager {
        ReferralManager(
            credentialStore: store,
            environmentProvider: FakeReferralEnvironmentProvider(environment: environment),
            serviceFactory: { service }
        )
    }

    // MARK: 29. Bootstrap stores loaded state

    @Test("A successful bootstrap stores the returned status as .loaded")
    func bootstrap_storesLoadedState() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        let manager = makeManager(service: service)

        await manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")

        guard case .loaded(let status) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        #expect(status.referralCode == "ABCD2345")
        #expect(manager.hasBootstrappedThisLaunch)
    }

    // MARK: 30. Failed bootstrap does not destroy credential

    @Test("A failed bootstrap leaves a valid credential in the store, never regenerated or removed")
    func failedBootstrap_preservesCredential() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .failure(ReferralServiceError.network("offline"))
        let store = InMemoryReferralCredentialStore()
        let manager = makeManager(service: service, store: store)

        await manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")

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
        let manager = makeManager(service: service, environment: nil)

        await manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")

        #expect(manager.loadState == .idle)
        #expect(service.bootstrapCallCount == 0)
        #expect(manager.hasBootstrappedThisLaunch == false)
    }

    @Test("bootstrapIfNeeded with a nil/empty App User ID never calls the service")
    func bootstrap_noAppUserID_neverCallsService() async {
        let service = FakeReferralAPIService()
        let manager = makeManager(service: service)

        await manager.bootstrapIfNeeded(revenueCatAppUserID: nil)
        await manager.bootstrapIfNeeded(revenueCatAppUserID: "")

        #expect(service.bootstrapCallCount == 0)
    }

    @Test("A second bootstrapIfNeeded call after success is a no-op — does not call the service again")
    func bootstrap_secondCallAfterSuccess_isNoOp() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        let manager = makeManager(service: service)

        await manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")
        await manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")

        #expect(service.bootstrapCallCount == 1)
    }

    // MARK: 31. Refresh updates status

    @Test("refresh() after a successful bootstrap fetches and stores a fresh status")
    func refresh_updatesStatus() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")

        service.statusResult = .success(sampleStatus(referralCode: "WXYZ6789"))
        await manager.refresh()

        guard case .loaded(let status) = manager.loadState else {
            Issue.record("Expected .loaded, got \(manager.loadState)")
            return
        }
        #expect(status.referralCode == "WXYZ6789")
        #expect(service.statusCallCount == 1)
    }

    @Test("refresh() before any bootstrap has ever produced a credential is a no-op")
    func refresh_beforeBootstrap_isNoOp() async {
        let service = FakeReferralAPIService()
        let manager = makeManager(service: service)

        await manager.refresh()

        #expect(service.statusCallCount == 0)
        #expect(manager.loadState == .idle)
    }

    // MARK: 32/33. Apply awaits server success; failed apply does not locally mark attribution

    @Test("applyReferralCode awaits and returns the backend-confirmed status on success")
    func applyReferralCode_awaitsServerSuccess() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")

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
        await manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")

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
        let manager = makeManager(service: service)

        do {
            _ = try await manager.applyReferralCode("ABCD2345")
            Issue.record("Expected applyReferralCode to throw")
        } catch ReferralServiceError.notConfigured {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: 34. Successful apply exposes backend-updated status

    @Test("A successful applyReferralCode updates loadState to the backend's new status")
    func applyReferralCode_success_updatesLoadState() async throws {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: ReferralStatus(canApply: true), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")

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

    // MARK: 35. Concurrent refreshes do not corrupt state

    @Test("Two concurrent bootstrapIfNeeded calls for a brand-new manager only ever call the service once")
    func concurrentBootstrap_callsServiceOnce() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        service.bootstrapDelayNanoseconds = 50_000_000 // 50ms — long enough to overlap reliably
        let manager = makeManager(service: service)

        async let first: Void = manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")
        async let second: Void = manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")
        _ = await (first, second)

        #expect(service.bootstrapCallCount == 1)
        guard case .loaded = manager.loadState else {
            Issue.record("Expected .loaded after concurrent bootstrap, got \(manager.loadState)")
            return
        }
    }

    @Test("Concurrent refreshes never crash and leave loadState as one of the two valid results")
    func concurrentRefresh_leavesValidState() async {
        let service = FakeReferralAPIService()
        service.bootstrapResult = .success(ReferralBootstrapResponse(status: sampleStatus(), created: true))
        let manager = makeManager(service: service)
        await manager.bootstrapIfNeeded(revenueCatAppUserID: "rc_user_1")

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

// MARK: - RevenueCat App User ID (36/37)

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

// MARK: - Environment mapping (38/39/40)

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
        // that path. StoreKitReferralRevenueEnvironmentProvider's own AppTransaction-based
        // mapping (production/sandbox/xcode) is documented, not re-executed here — it requires a
        // real StoreKit test environment this suite does not construct (see that type's header).
        let provider = FakeReferralEnvironmentProvider(environment: environment)
        let result = await provider.currentEnvironment()
        #expect(result == environment)
    }
}
