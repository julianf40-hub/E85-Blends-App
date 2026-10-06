//
//  PushRegistrationService.swift
//  EightyFiveBlends
//
//  App-level foundation for APNs push registration — the iOS prerequisite for Price Alerts. It
//  owns exactly four things: asking for notification permission, calling
//  `registerForRemoteNotifications()`, receiving the APNs token, and exposing where all that
//  stands (`state`) so the later Price Alerts integration can switch over it.
//
//  What it deliberately does NOT do (this is a foundation, not the feature):
//    - Nothing is sent anywhere. The token is not registered with price-alerts-api or Supabase;
//      that is the next phase, and it owns the installation credentials that call needs.
//    - Nothing runs at launch. No existing user is prompted, registered or otherwise affected by
//      this file's existence; a future flow decides when `requestAuthorizationAndRegister()` (a
//      user opting in) or `refreshRegistrationIfAuthorized()` (a returning, already-opted-in
//      user) is called.
//    - The token is never persisted. It lives only in `state` for this process. A persisted token
//      is a stale-token hazard (an iCloud/device restore would resurrect another device's token),
//      and iOS hands the current token back quickly whenever `registerForRemoteNotifications()`
//      is called, so there is nothing worth caching. The token is also never logged — see
//      PushDeviceToken, which redacts every description path.
//
//  Capability note: remote registration only succeeds when the app carries the Push Notifications
//  capability (the `aps-environment` entitlement). This repository's entitlements do not include
//  it at the time of writing, so on a real device the OS answers with a registration failure and
//  `state` becomes `.failed(.registrationFailed(...))`. That is the intended, non-fatal behavior
//  until the capability is enabled — nothing here retries, loops, or crashes.
//
//  The system dependencies (permission status, the permission prompt, `register...`) sit behind
//  `PushRegistrationSystem` so the whole state machine is unit-testable without UserNotifications
//  or UIKit. The production implementation is UIKitPushRegistrationSystem; the AppDelegate
//  forwards the two APNs callbacks here. See EightyFiveBlendsTests/PushRegistrationTests.swift.
//

import Foundation
import Observation

/// The system calls the registration flow depends on. (Implicitly MainActor, like every
/// declaration in this module — `registerForRemoteNotifications()` must run on the main thread.)
protocol PushRegistrationSystem {
    /// The current notification-permission answer. Never prompts.
    func authorizationStatus() async -> PushAuthorizationStatus
    /// Shows the system permission prompt. Only ever called when the status is `.notDetermined`.
    func requestAuthorization() async throws -> Bool
    /// Asks the OS to register with APNs. The answer arrives later, via the AppDelegate callbacks
    /// that forward to `PushRegistrationService.handleDeviceToken(_:)` /
    /// `handleRegistrationFailure(_:)`.
    func registerForRemoteNotifications()
}

@MainActor
@Observable
final class PushRegistrationService {
    private(set) var state: PushRegistrationState = .notRequested

    private let system: any PushRegistrationSystem
    /// Coalesces overlapping calls: a second call made while one is awaiting the system returns
    /// immediately instead of racing it (and instead of showing a second prompt).
    @ObservationIgnored private var isRequestInFlight = false

    init(system: any PushRegistrationSystem) {
        self.system = system
    }

    /// The APNs token, once registered. `nil` in every other state.
    var currentToken: PushDeviceToken? {
        if case .registered(let token) = state {
            return token
        }
        return nil
    }

    // MARK: - Opting in

    /// For a user who is opting in to push-backed features. Prompts for permission ONLY when the
    /// system says it has never been asked (`.notDetermined`) — a denied or already-granted user
    /// is never prompted — then registers with APNs. Safe to call repeatedly: overlapping calls
    /// coalesce, an outstanding registration or an already-held token is not re-requested, and a
    /// denied user simply stays `.denied`. Call `refreshRegistrationIfAuthorized()` to deliberately
    /// ask the OS for the current token again.
    func requestAuthorizationAndRegister() async {
        guard isRequestInFlight == false else { return }
        isRequestInFlight = true
        defer { isRequestInFlight = false }

        switch await system.authorizationStatus() {
        case .denied:
            state = .denied
        case .authorized:
            beginRegistration()
        case .notDetermined:
            let granted: Bool
            do {
                granted = try await system.requestAuthorization()
            } catch {
                state = .failed(.authorizationRequestFailed)
                return
            }
            if granted {
                beginRegistration()
            } else {
                state = .denied
            }
        }
    }

    // MARK: - Returning users

    /// For a returning user who has already opted in: asks the OS for the current token again so
    /// a rotated token is noticed, and reflects a permission the user revoked in Settings. NEVER
    /// prompts. A call is one request to the OS and nothing more — no result of it (including a
    /// failure) triggers another, so there is no registration loop.
    func refreshRegistrationIfAuthorized() async {
        guard isRequestInFlight == false else { return }
        isRequestInFlight = true
        defer { isRequestInFlight = false }

        switch await system.authorizationStatus() {
        case .authorized:
            if currentToken == nil {
                state = .authorizedAwaitingToken
            }
            system.registerForRemoteNotifications()
        case .denied:
            state = .denied
        case .notDetermined:
            break
        }
    }

    private func beginRegistration() {
        switch state {
        case .authorizedAwaitingToken, .registered:
            // A registration is already outstanding, or a token is already held: do not ask the
            // OS again. (refreshRegistrationIfAuthorized() is the deliberate way to re-ask.)
            return
        case .notRequested, .denied, .failed:
            state = .authorizedAwaitingToken
            system.registerForRemoteNotifications()
        }
    }

    // MARK: - APNs callbacks (forwarded by AppDelegate)

    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. Handles first delivery,
    /// repeated delivery of the same token (a no-op — observers see no change) and rotation (the
    /// new token replaces the old one). An empty or implausible payload is a failed registration,
    /// but never discards a good token already held.
    func handleDeviceToken(_ deviceToken: Data) {
        // A token that arrives after the user denied permission is not one this install should
        // act on; the next refresh/opt-in re-reads the real permission.
        if state == .denied { return }

        guard let token = PushDeviceToken(deviceToken: deviceToken) else {
            if currentToken == nil {
                state = .failed(.invalidToken)
            }
            return
        }

        let newState = PushRegistrationState.registered(token)
        if state != newState {
            state = newState
        }
    }

    /// `application(_:didFailToRegisterForRemoteNotificationsWithError:)`. Expected on simulators
    /// without push support and on builds without the Push Notifications capability. Recorded as
    /// state and nothing else — no retry — and never discards a token already held.
    func handleRegistrationFailure(_ error: Error) {
        guard currentToken == nil else { return }
        let nsError = error as NSError
        state = .failed(.registrationFailed(domain: nsError.domain, code: nsError.code))
    }
}
