//
//  PushRegistrationTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts iOS foundation — the APNs push-registration state machine (PushRegistrationService),
//  the token value type (PushDeviceToken) and their safety properties: deterministic token
//  encoding, no duplicate permission prompts, no registration loop, graceful denied/failed/
//  simulator paths, token rotation, and a token that never appears in any description.
//  The UserNotifications/UIKit implementation of the system seam (UIKitPushRegistrationSystem) is
//  exercised only on device; everything decision-bearing is here, against a fake.
//

import Foundation
import Observation
import Testing
@testable import EightyFiveBlends

/// A scriptable stand-in for the system calls behind the registration flow.
@MainActor
private final class FakePushSystem: PushRegistrationSystem {
    var status: PushAuthorizationStatus
    var userGrantsPermission = true
    var requestError: Error?
    /// Awaited at the start of `authorizationStatus()`, so a test can hold one call open while a
    /// second one arrives.
    var beforeStatusAnswer: (() async -> Void)?

    private(set) var promptCount = 0
    private(set) var registerCount = 0

    init(status: PushAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> PushAuthorizationStatus {
        await beforeStatusAnswer?()
        return status
    }

    func requestAuthorization() async throws -> Bool {
        promptCount += 1
        if let requestError { throw requestError }
        status = userGrantsPermission ? .authorized : .denied
        return userGrantsPermission
    }

    func registerForRemoteNotifications() {
        registerCount += 1
    }
}

private struct PromptFailure: Error {}

/// `withObservationTracking`'s `onChange` is `@Sendable`, so it cannot mutate a captured `var`.
/// A reference type is the standard stand-in; the tests using it are single-threaded.
private nonisolated final class ObserverNotificationFlag: @unchecked Sendable {
    private(set) var hasFired = false
    func markFired() { hasFired = true }
}

struct PushRegistrationTests {
    private func tokenBytes(_ byte: UInt8, count: Int = 32) -> Data {
        Data(repeating: byte, count: count)
    }

    // MARK: - Token conversion

    @Test("Token conversion is deterministic, lowercase hexadecimal")
    func token_conversionIsDeterministic() throws {
        let bytes = Data([0x00, 0x0F, 0xA5, 0xFF, 0x10, 0xBC, 0xDE, 0x01, 0x7E, 0x80])

        let first = try #require(PushDeviceToken(deviceToken: bytes))
        let second = try #require(PushDeviceToken(deviceToken: bytes))

        #expect(first.hexString == "000fa5ff10bcde017e80")
        #expect(first == second)
        #expect(first.hexString == first.hexString.lowercased())
        #expect(first.byteCount == 10)
    }

    @Test("Different bytes give different tokens, and every byte value encodes to two characters")
    func token_distinguishesBytesAndKeepsLeadingZeros() throws {
        // The largest token the backend accepts, covering every byte value twice.
        let largest = Data((0..<PushDeviceToken.maximumByteCount).map { UInt8($0 % 256) })

        let token = try #require(PushDeviceToken(deviceToken: largest))

        #expect(token.hexString.count == PushDeviceToken.maximumByteCount * 2)
        #expect(token.hexString.hasPrefix("000102030405060708090a0b0c0d0e0f"))
        let first = try #require(PushDeviceToken(deviceToken: tokenBytes(0x01)))
        let second = try #require(PushDeviceToken(deviceToken: tokenBytes(0x02)))
        #expect(first != second)
    }

    @Test("Empty or implausible token data is rejected, never padded or truncated")
    func token_rejectsInvalidData() {
        #expect(PushDeviceToken(deviceToken: Data()) == nil)
        #expect(PushDeviceToken(deviceToken: tokenBytes(0xAB, count: PushDeviceToken.minimumByteCount - 1)) == nil)
        #expect(PushDeviceToken(deviceToken: tokenBytes(0xAB, count: PushDeviceToken.maximumByteCount + 1)) == nil)
        #expect(PushDeviceToken(deviceToken: tokenBytes(0xAB, count: PushDeviceToken.minimumByteCount)) != nil)
        #expect(PushDeviceToken(deviceToken: tokenBytes(0xAB, count: PushDeviceToken.maximumByteCount)) != nil)
    }

    @Test("The accepted token size is exactly what price-alerts-api accepts (16...1024 hex characters)")
    func token_boundsMatchBackendValidation() {
        #expect(PushDeviceToken.minimumByteCount * 2 == 16)
        #expect(PushDeviceToken.maximumByteCount * 2 == 1024)
    }

    @Test("A token never appears in any description, reflection or interpolation of itself or its state")
    func token_isRedactedEverywhere() throws {
        let token = try #require(PushDeviceToken(deviceToken: tokenBytes(0xAB)))
        let hex = token.hexString
        #expect(hex.isEmpty == false)

        var dumped = ""
        dump(token, to: &dumped)
        var dumpedState = ""
        dump(PushRegistrationState.registered(token), to: &dumpedState)

        let renderings = [
            "\(token)",
            String(describing: token),
            String(reflecting: token),
            token.description,
            token.debugDescription,
            dumped,
            "\(PushRegistrationState.registered(token))",
            String(describing: PushRegistrationState.registered(token)),
            String(reflecting: PushRegistrationState.registered(token)),
            dumpedState,
        ]
        for rendering in renderings {
            #expect(rendering.contains(hex) == false, "token leaked in: \(rendering)")
            #expect(rendering.lowercased().contains("abab") == false, "token bytes leaked in: \(rendering)")
        }
        #expect(token.description.contains("redacted"))
    }

    // MARK: - Permission prompts

    @MainActor
    @Test("A user who was never asked is prompted exactly once, then registered")
    func optIn_promptsOnceWhenNotDetermined() async {
        let system = FakePushSystem(status: .notDetermined)
        let service = PushRegistrationService(system: system)

        await service.requestAuthorizationAndRegister()
        await service.requestAuthorizationAndRegister()
        await service.requestAuthorizationAndRegister()

        #expect(system.promptCount == 1)
        #expect(system.registerCount == 1)
        #expect(service.state == .authorizedAwaitingToken)
    }

    @MainActor
    @Test("An already-authorized user is never prompted")
    func optIn_neverPromptsWhenAuthorized() async {
        let system = FakePushSystem(status: .authorized)
        let service = PushRegistrationService(system: system)

        await service.requestAuthorizationAndRegister()

        #expect(system.promptCount == 0)
        #expect(system.registerCount == 1)
        #expect(service.state == .authorizedAwaitingToken)
    }

    @MainActor
    @Test("A denied user is never prompted and never registered")
    func optIn_deniedIsRespected() async {
        let system = FakePushSystem(status: .denied)
        let service = PushRegistrationService(system: system)

        await service.requestAuthorizationAndRegister()
        await service.requestAuthorizationAndRegister()

        #expect(system.promptCount == 0)
        #expect(system.registerCount == 0)
        #expect(service.state == .denied)
    }

    @MainActor
    @Test("A user who declines the prompt ends up denied, with nothing registered and no second prompt")
    func optIn_decliningThePrompt() async {
        let system = FakePushSystem(status: .notDetermined)
        system.userGrantsPermission = false
        let service = PushRegistrationService(system: system)

        await service.requestAuthorizationAndRegister()
        await service.requestAuthorizationAndRegister()

        #expect(system.promptCount == 1)
        #expect(system.registerCount == 0)
        #expect(service.state == .denied)
    }

    @MainActor
    @Test("A permission request that throws is a failure state, not a crash, and registers nothing")
    func optIn_promptFailure() async {
        let system = FakePushSystem(status: .notDetermined)
        system.requestError = PromptFailure()
        let service = PushRegistrationService(system: system)

        await service.requestAuthorizationAndRegister()

        #expect(system.registerCount == 0)
        #expect(service.state == .failed(.authorizationRequestFailed))
    }

    @MainActor
    @Test("Two overlapping opt-in calls coalesce into one prompt and one registration")
    func optIn_overlappingCallsCoalesce() async {
        let system = FakePushSystem(status: .notDetermined)
        system.beforeStatusAnswer = { await Task.yield() }
        let service = PushRegistrationService(system: system)

        async let first: Void = service.requestAuthorizationAndRegister()
        async let second: Void = service.requestAuthorizationAndRegister()
        _ = await (first, second)

        #expect(system.promptCount == 1)
        #expect(system.registerCount == 1)
    }

    // MARK: - No registration loop

    @MainActor
    @Test("Repeated opt-in calls never re-register while a registration is outstanding or a token is held")
    func registration_isNotRepeated() async {
        let system = FakePushSystem(status: .authorized)
        let service = PushRegistrationService(system: system)

        await service.requestAuthorizationAndRegister()
        await service.requestAuthorizationAndRegister()
        #expect(system.registerCount == 1)

        service.handleDeviceToken(tokenBytes(0xAB))
        await service.requestAuthorizationAndRegister()
        await service.requestAuthorizationAndRegister()
        #expect(system.registerCount == 1)
    }

    @MainActor
    @Test("A registration failure is recorded and nothing more — no automatic retry")
    func registration_failureDoesNotRetry() async {
        let system = FakePushSystem(status: .authorized)
        let service = PushRegistrationService(system: system)
        await service.requestAuthorizationAndRegister()

        service.handleRegistrationFailure(NSError(domain: NSCocoaErrorDomain, code: 3010))
        service.handleRegistrationFailure(NSError(domain: NSCocoaErrorDomain, code: 3010))

        #expect(system.registerCount == 1)
        #expect(service.state == .failed(.registrationFailed(domain: NSCocoaErrorDomain, code: 3010)))
    }

    @MainActor
    @Test("After a failure the next explicit opt-in tries once more and can succeed")
    func registration_canRecoverAfterFailure() async {
        let system = FakePushSystem(status: .authorized)
        let service = PushRegistrationService(system: system)
        await service.requestAuthorizationAndRegister()
        service.handleRegistrationFailure(NSError(domain: NSCocoaErrorDomain, code: 3010))

        await service.requestAuthorizationAndRegister()
        #expect(system.registerCount == 2)
        #expect(service.state == .authorizedAwaitingToken)

        service.handleDeviceToken(tokenBytes(0xAB))
        #expect(service.currentToken != nil)
    }

    // MARK: - Token callbacks

    @MainActor
    @Test("The first token moves the service to registered and exposes the token")
    func token_firstDelivery() throws {
        let service = PushRegistrationService(system: FakePushSystem(status: .authorized))

        service.handleDeviceToken(tokenBytes(0xAB))

        let expected = try #require(PushDeviceToken(deviceToken: tokenBytes(0xAB)))
        #expect(service.state == .registered(expected))
        #expect(service.currentToken == expected)
    }

    @MainActor
    @Test("Delivering the same token again is a true no-op: state is unchanged and observers are not notified")
    func token_repeatedDeliveryIsSilent() throws {
        let service = PushRegistrationService(system: FakePushSystem(status: .authorized))
        service.handleDeviceToken(tokenBytes(0xAB))
        let before = service.state

        let notification = ObserverNotificationFlag()
        withObservationTracking {
            _ = service.state
        } onChange: {
            notification.markFired()
        }
        service.handleDeviceToken(tokenBytes(0xAB))

        #expect(service.state == before)
        #expect(notification.hasFired == false)
    }

    @MainActor
    @Test("A rotated token replaces the old one")
    func token_rotationUpdatesState() throws {
        let service = PushRegistrationService(system: FakePushSystem(status: .authorized))
        service.handleDeviceToken(tokenBytes(0xAB))

        service.handleDeviceToken(tokenBytes(0xCD))

        let rotated = try #require(PushDeviceToken(deviceToken: tokenBytes(0xCD)))
        #expect(service.state == .registered(rotated))
        #expect(service.currentToken?.hexString == String(repeating: "cd", count: 32))
    }

    @MainActor
    @Test("An empty or implausible callback is a failed registration")
    func token_emptyCallbackIsHandled() {
        let service = PushRegistrationService(system: FakePushSystem(status: .authorized))

        service.handleDeviceToken(Data())
        #expect(service.state == .failed(.invalidToken))
        #expect(service.currentToken == nil)

        service.handleDeviceToken(tokenBytes(0xAB, count: 3))
        #expect(service.state == .failed(.invalidToken))
    }

    @MainActor
    @Test("A bad callback never discards a good token already held")
    func token_badCallbackKeepsGoodToken() throws {
        let service = PushRegistrationService(system: FakePushSystem(status: .authorized))
        service.handleDeviceToken(tokenBytes(0xAB))
        let good = try #require(service.currentToken)

        service.handleDeviceToken(Data())
        service.handleRegistrationFailure(NSError(domain: NSCocoaErrorDomain, code: 3010))

        #expect(service.currentToken == good)
        #expect(service.state == .registered(good))
    }

    @MainActor
    @Test("A token that arrives after the user denied permission is not acted on")
    func token_ignoredWhenDenied() async {
        let system = FakePushSystem(status: .denied)
        let service = PushRegistrationService(system: system)
        await service.requestAuthorizationAndRegister()

        service.handleDeviceToken(tokenBytes(0xAB))

        #expect(service.state == .denied)
        #expect(service.currentToken == nil)
    }

    // MARK: - Simulator / no-push-capability path

    @MainActor
    @Test("Where remote notifications cannot work (simulator, no capability) the service lands in a non-fatal failed state")
    func simulatorOrMissingCapability_isNonFatal() async {
        let system = FakePushSystem(status: .authorized)
        let service = PushRegistrationService(system: system)

        await service.requestAuthorizationAndRegister()
        // What UIKit reports when remote notifications are unavailable.
        service.handleRegistrationFailure(NSError(domain: NSCocoaErrorDomain, code: 3000))

        #expect(service.state == .failed(.registrationFailed(domain: NSCocoaErrorDomain, code: 3000)))
        #expect(service.currentToken == nil)
        // The service stays fully usable.
        await service.requestAuthorizationAndRegister()
        #expect(service.state == .authorizedAwaitingToken)
    }

    @MainActor
    @Test("Nothing happens until something asks: a new service has requested nothing")
    func newService_isIdle() {
        let system = FakePushSystem(status: .authorized)
        let service = PushRegistrationService(system: system)

        #expect(service.state == .notRequested)
        #expect(service.currentToken == nil)
        #expect(system.promptCount == 0)
        #expect(system.registerCount == 0)
    }

    // MARK: - Refresh for returning users

    @MainActor
    @Test("Refresh never prompts, and does nothing for a user who was never asked")
    func refresh_neverPrompts() async {
        let system = FakePushSystem(status: .notDetermined)
        let service = PushRegistrationService(system: system)

        await service.refreshRegistrationIfAuthorized()

        #expect(system.promptCount == 0)
        #expect(system.registerCount == 0)
        #expect(service.state == .notRequested)
    }

    @MainActor
    @Test("Refresh re-asks the OS for the current token so a rotation is noticed, keeping the old token until it answers")
    func refresh_picksUpRotation() async throws {
        let system = FakePushSystem(status: .authorized)
        let service = PushRegistrationService(system: system)
        service.handleDeviceToken(tokenBytes(0xAB))
        let old = try #require(service.currentToken)

        await service.refreshRegistrationIfAuthorized()
        #expect(system.registerCount == 1)
        #expect(service.currentToken == old)

        service.handleDeviceToken(tokenBytes(0xCD))
        #expect(service.currentToken?.hexString == String(repeating: "cd", count: 32))
    }

    @MainActor
    @Test("Refresh reflects a permission the user revoked in Settings")
    func refresh_reflectsRevokedPermission() async {
        let system = FakePushSystem(status: .authorized)
        let service = PushRegistrationService(system: system)
        service.handleDeviceToken(tokenBytes(0xAB))

        system.status = .denied
        await service.refreshRegistrationIfAuthorized()

        #expect(service.state == .denied)
        #expect(system.registerCount == 0)
    }
}
