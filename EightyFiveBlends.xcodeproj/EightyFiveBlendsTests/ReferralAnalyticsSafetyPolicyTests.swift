//
//  ReferralAnalyticsSafetyPolicyTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.1 — negative tests for ReferralAnalyticsSafetyPolicy and every gate it drives:
//  ReferralManager.ensureBootstrapped, ReferralAPIService.perform, AnalyticsService.track, and
//  AnalyticsService.send. This suite always runs inside an XCTest-hosted app, so the LIVE policy
//  is blocked here in every scheme/configuration — the blocked-path tests below use live-policy
//  instances with counting spies or an intercepting URLProtocol, so even a regressed gate could
//  never reach the network, Keychain, RevenueCat, or StoreKit.
//

import Foundation
import Testing
@testable import EightyFiveBlends

// MARK: - Spies

final class SafetyPolicyCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ key: String) {
        lock.withLock { counts[key, default: 0] += 1 }
    }

    var total: Int {
        lock.withLock { counts.values.reduce(0, +) }
    }
}

private struct SpyCredentialStore: ReferralCredentialStoring {
    let counter: SafetyPolicyCallCounter
    func loadCredential() throws -> ReferralInstallationCredential? {
        counter.record("credential.load")
        return nil
    }
    func save(_ credential: ReferralInstallationCredential) throws {
        counter.record("credential.save")
    }
}

private struct SpyEnvironmentProvider: ReferralRevenueEnvironmentProviding {
    let counter: SafetyPolicyCallCounter
    func currentEnvironment() async -> ReferralRevenueEnvironment? {
        counter.record("environment")
        return .sandbox
    }
}

private struct SpyIdentityProvider: ReferralRevenueCatIdentityProviding {
    let counter: SafetyPolicyCallCounter
    @MainActor
    func currentAppUserID() -> String? {
        counter.record("identity")
        return "rc_spy_user"
    }
}

/// Counts every request that reaches the transport and fails it — never a real network call.
final class SafetyPolicyCountingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requestCount = 0

    static var requestCount: Int { lock.withLock { _requestCount } }
    static func reset() { lock.withLock { _requestCount = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requestCount += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafetyPolicyCountingURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

// MARK: - Pure policy

struct ReferralAnalyticsSafetyPolicyEvaluationTests {
    private static let allowOverrideAttempts: [[String: String]] = [
        [:],
        ["ALLOW_PRODUCTION_WRITES": "1"],
        ["ALLOW_PRODUCTION_WRITES": "true", "REFERRAL_ALLOW_LIVE_WRITES": "YES"],
        ["ALLOW_PRODUCTION_WRITES": "not-a-bool"],
        ["ALLOW_PRODUCTION_WRITES": ""],
        ["ANALYTICS_ALLOW_LIVE": "1", "allowLiveWrites": "1"],
    ]

    @Test("INTERNAL_BUILD blocks live writes regardless of absent, malformed, or attempted allow overrides", arguments: allowOverrideAttempts)
    func internalBuild_alwaysBlocked(environment: [String: String]) {
        let policy = ReferralAnalyticsSafetyPolicy.evaluate(isInternalBuild: true, processEnvironment: environment)
        #expect(policy.allowsLiveWrites == false)
    }

    @Test("A hosted-test process blocks live writes, even with an allow override present")
    func hostedTest_blocked() {
        for key in ReferralAnalyticsSafetyPolicy.hostedTestEnvironmentKeys {
            let policy = ReferralAnalyticsSafetyPolicy.evaluate(
                isInternalBuild: false,
                processEnvironment: [key: "/tmp/x", "ALLOW_PRODUCTION_WRITES": "1"]
            )
            #expect(policy.isHostedTestProcess)
            #expect(policy.allowsLiveWrites == false)
        }
    }

    @Test("Ordinary non-test, non-Internal (Release) behavior is unchanged: live writes allowed", arguments: allowOverrideAttempts)
    func ordinaryRelease_allowed(environment: [String: String]) {
        let policy = ReferralAnalyticsSafetyPolicy.evaluate(isInternalBuild: false, processEnvironment: environment)
        #expect(policy.isHostedTestProcess == false)
        #expect(policy.allowsLiveWrites)
    }

    @Test("The live policy in this XCTest-hosted process detects the app-host test signal and blocks writes")
    func livePolicy_blockedInHostedTests() {
        #expect(ReferralAnalyticsSafetyPolicy.live.isHostedTestProcess)
        #expect(ReferralAnalyticsSafetyPolicy.live.allowsLiveWrites == false)
        #expect(ReferralAnalyticsSafetyPolicy.live.isInternalBuild == ReferralAnalyticsSafetyPolicy.isInternalBuildCompiled)
    }

    @Test("Only a session intercepted by an .xctest-defined URLProtocol counts as a test transport")
    func interceptedSessionPredicate() {
        #expect(ReferralAnalyticsSafetyPolicy.isInterceptedTestSession(URLSession.shared) == false)
        #expect(ReferralAnalyticsSafetyPolicy.isInterceptedTestSession(URLSession(configuration: .ephemeral)) == false)
        #expect(ReferralAnalyticsSafetyPolicy.isInterceptedTestSession(SafetyPolicyCountingURLProtocol.makeSession()))
    }
}

// MARK: - ReferralManager gate

@MainActor
struct ReferralManagerSafetyGateTests {
    /// Live-policy initializer (blocked in this hosted process) with every dependency a counting
    /// spy, so ANY identity/Keychain/StoreKit/service-factory access would be observed.
    private func makeBlockedManager(counter: SafetyPolicyCallCounter) -> ReferralManager {
        ReferralManager(
            credentialStore: SpyCredentialStore(counter: counter),
            environmentProvider: SpyEnvironmentProvider(counter: counter),
            identityProvider: SpyIdentityProvider(counter: counter),
            serviceFactory: {
                counter.record("serviceFactory")
                return FakeReferralAPIService()
            }
        )
    }

    @Test("bootstrap/refresh/apply/claim on a blocked manager never touch identity, Keychain, StoreKit, or the service factory")
    func blockedManager_zeroDependencyAccess() async {
        let counter = SafetyPolicyCallCounter()
        let manager = makeBlockedManager(counter: counter)

        await manager.bootstrapIfNeeded()
        await manager.refresh()
        await #expect(throws: ReferralServiceError.notConfigured) {
            _ = try await manager.applyReferralCode("ABCD2345")
        }
        await #expect(throws: ReferralServiceError.notConfigured) {
            _ = try await manager.claimReward(requestedProductID: nil)
        }

        #expect(counter.total == 0)
        #expect(manager.hasBootstrappedThisLaunch == false)
        #expect(manager.bootstrappedEnvironment == nil)
        // Honest blocked state: explicitly failed — never .loaded (success) and never a
        // waiting/loading state that would imply setup is still in progress.
        #expect(manager.loadState == .failed(.notConfigured))
        if case .loaded = manager.loadState {
            Issue.record("A blocked manager must never report .loaded")
        }
    }

    @Test("Retries and concurrent calls on a blocked manager stay blocked with zero dependency access")
    func blockedManager_retryAndConcurrency() async {
        let counter = SafetyPolicyCallCounter()
        let manager = makeBlockedManager(counter: counter)

        for _ in 0..<3 {
            await manager.bootstrapIfNeeded()
            await manager.refresh()
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { @MainActor in
                    switch index % 4 {
                    case 0: await manager.bootstrapIfNeeded()
                    case 1: await manager.refresh()
                    case 2: _ = try? await manager.applyReferralCode("ABCD2345")
                    default: _ = try? await manager.claimReward(requestedProductID: "pro_monthly")
                    }
                }
            }
        }

        #expect(counter.total == 0)
        #expect(manager.hasBootstrappedThisLaunch == false)
        #expect(manager.bootstrappedEnvironment == nil)
        #expect(manager.loadState == .failed(.notConfigured))
    }

    @Test("The test-double initializer stays blocked when any live dependency type is injected")
    func testDoubleInit_withLiveDependency_staysBlocked() async {
        let counter = SafetyPolicyCallCounter()
        let manager = ReferralManager(
            testDoubleCredentialStore: KeychainReferralCredentialStore(),
            environmentProvider: SpyEnvironmentProvider(counter: counter),
            identityProvider: SpyIdentityProvider(counter: counter),
            serviceFactory: {
                counter.record("serviceFactory")
                return FakeReferralAPIService()
            }
        )

        await manager.bootstrapIfNeeded()
        await #expect(throws: ReferralServiceError.notConfigured) {
            _ = try await manager.applyReferralCode("ABCD2345")
        }

        #expect(counter.total == 0)
        #expect(manager.hasBootstrappedThisLaunch == false)
        #expect(manager.loadState == .failed(.notConfigured))
    }
}

// MARK: - ReferralAPIService gate

@Suite(.serialized)
struct ReferralAPIServiceSafetyGateTests {
    @Test("A live-policy ReferralAPIService sends zero requests for every referral action")
    func blockedService_zeroRequests() async throws {
        SafetyPolicyCountingURLProtocol.reset()
        // Default initializer → live policy (blocked here); the session is still intercepted so a
        // regressed gate could only ever hit the counting protocol, never the network.
        let service = try ReferralAPIService(session: SafetyPolicyCountingURLProtocol.makeSession())
        let credential = ReferralInstallationCredential.generate()

        await #expect(throws: ReferralServiceError.notConfigured) {
            _ = try await service.bootstrap(credential: credential, revenueCatAppUserID: "rc", environment: .sandbox, appVersion: "2.4.1")
        }
        await #expect(throws: ReferralServiceError.notConfigured) {
            _ = try await service.status(credential: credential)
        }
        await #expect(throws: ReferralServiceError.notConfigured) {
            _ = try await service.applyCode("ABCD2345", credential: credential)
        }
        await #expect(throws: ReferralServiceError.notConfigured) {
            _ = try await service.claimReward(requestedProductID: nil, credential: credential)
        }

        #expect(SafetyPolicyCountingURLProtocol.requestCount == 0)
    }
}

// MARK: - AnalyticsService gate

@Suite(.serialized)
@MainActor
struct AnalyticsServiceSafetyGateTests {
    @Test("track never dispatches a Task (and so never builds a service) while the live policy is blocked")
    func blockedTrack_noDispatch() {
        var dispatchCount = 0
        AnalyticsService.track(.stationViewed, properties: AnalyticsEventProperties(), now: .now) { _ in
            dispatchCount += 1
        }
        #expect(dispatchCount == 0)
    }

    @Test("A live-policy AnalyticsService.send sends zero requests and never reads the reporter ID")
    func blockedSend_zeroRequestsAndZeroReporterIDAccess() async throws {
        SafetyPolicyCountingURLProtocol.reset()
        let counter = SafetyPolicyCallCounter()
        // Normal initializer → live policy (blocked here), with a counting reporter-ID spy and an
        // intercepted session so a regressed gate could never reach the network.
        let service = try AnalyticsService(
            session: SafetyPolicyCountingURLProtocol.makeSession(),
            reporterIDProvider: {
                counter.record("reporterID")
                return "00000000-0000-4000-8000-000000000000"
            }
        )

        var thrownError: Error?
        do {
            try await service.send(eventName: .stationViewed, properties: AnalyticsEventProperties(), occurredAt: .now)
        } catch {
            thrownError = error
        }

        guard case .notConfigured? = thrownError as? AnalyticsServiceError else {
            Issue.record("Expected AnalyticsServiceError.notConfigured, got \(String(describing: thrownError))")
            return
        }
        #expect(counter.total == 0)
        #expect(SafetyPolicyCountingURLProtocol.requestCount == 0)
    }
}
