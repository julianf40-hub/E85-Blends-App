//
//  PushRegistrationState.swift
//  EightyFiveBlends
//
//  The vocabulary of the push-registration foundation (PushRegistrationService): where this
//  install stands in "can Price Alerts push reach this device?", expressed so a later Price Alerts
//  integration can switch over it. Pure Foundation. See
//  EightyFiveBlendsTests/PushRegistrationTests.swift.
//

import Foundation

/// The notification-permission answer the registration flow needs — deliberately smaller than
/// `UNAuthorizationStatus` so the state machine has no UserNotifications dependency. The mapping
/// from the system type lives next to the UserNotifications adapter (UIKitPushRegistrationSystem).
nonisolated enum PushAuthorizationStatus: Equatable, Sendable {
    /// The user has never been asked. This is the ONLY status that may lead to a permission prompt.
    case notDetermined
    case denied
    /// Authorized in any form that allows delivery (authorized, provisional, ephemeral).
    case authorized
}

nonisolated enum PushRegistrationFailure: Equatable, Sendable {
    /// `requestAuthorization` itself threw (not "the user said no" — that is `.denied`).
    case authorizationRequestFailed
    /// APNs registration failed. Expected, and non-fatal, wherever remote notifications cannot work:
    /// a simulator without push support, a build without the Push Notifications capability
    /// (no `aps-environment` entitlement), or no network. Only the NSError domain and code are
    /// kept — nothing identifying.
    case registrationFailed(domain: String, code: Int)
    /// The OS delivered a token callback with empty or implausible data.
    case invalidToken
}

nonisolated enum PushRegistrationState: Equatable, Sendable {
    /// Nothing has been asked of the system in this process. The state at every launch.
    case notRequested
    /// The user has denied notifications. Nothing is registered, and nothing will prompt again.
    case denied
    /// Permission is granted and `registerForRemoteNotifications()` has been called; the OS has not
    /// answered yet.
    case authorizedAwaitingToken
    /// APNs returned a token (redacted in every description — see PushDeviceToken).
    case registered(PushDeviceToken)
    case failed(PushRegistrationFailure)
}
