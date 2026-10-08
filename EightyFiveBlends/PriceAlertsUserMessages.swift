//
//  PriceAlertsUserMessages.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B). The words a person sees when something goes wrong or
//  needs a decision, in one place. Pure Foundation.
//
//  Two mappings:
//    - `PriceAlertsServiceError`              -> `PriceAlertsUserMessage`
//    - `PriceAlertsDeviceRegistrationOutcome` -> `PriceAlertsNotificationPresentation`
//  Both switch over their source enums without a `default` (the service errors, the wire-layer errors,
//  the network categories, the registration outcomes and skip reasons), so adding a case fails to
//  compile until it has words. Only the long tail of backend error CODES shares one generic message.
//
//  WHAT NEVER APPEARS HERE. Phase 3A's errors already carry no secret, body or URL; this layer goes
//  further and carries no HTTP status, no backend error code, no function name, no installation id and
//  no token — even where the error has one. A message says what happened in a person's terms and what
//  they can do, nothing about how the request was made. (A test scans every message for those.)
//
//  FREE IS NEVER GUESSED. "Checking your subscription" and "Pro required" are different messages: the
//  first is for RevenueCat not having answered yet, the second for an answer of "not Pro".
//

import Foundation

// MARK: - Errors

nonisolated struct PriceAlertsUserMessage: Equatable, Sendable {
    /// A few words: "You're offline".
    let headline: String
    /// One or two sentences saying what to do next.
    let body: String
    /// Whether offering "Try Again" is reasonable.
    let isRetryable: Bool

    init(headline: String, body: String, isRetryable: Bool) {
        self.headline = headline
        self.body = body
        self.isRetryable = isRetryable
    }

    init(error: PriceAlertsServiceError) {
        switch error {
        case .stationNotEligibleForPriceAlerts:
            self = PriceAlertsUserMessage(
                headline: "Not available for this station",
                body: "Price Alerts aren't available for this station yet. Check back after a price or ethanol percentage has been reported for it.",
                isRetryable: false
            )
        case .invalidAlert(let failure):
            self = Self.message(for: failure)
        case .proRequired:
            self = PriceAlertsUserMessage(
                headline: "Pro feature",
                body: "Price Alerts are part of 85Blends Pro.",
                isRetryable: false
            )
        case .entitlementUnresolved:
            self = PriceAlertsUserMessage(
                headline: "Checking your subscription",
                body: "We're still confirming your subscription. Try again in a moment.",
                isRetryable: true
            )
        case .proRequiredByServer:
            self = PriceAlertsUserMessage(
                headline: "Couldn't confirm Pro yet",
                body: "We couldn't confirm your Pro subscription with Price Alerts yet. If you just subscribed, wait a minute and try again.",
                isRetryable: true
            )
        case .stationNotFound:
            self = PriceAlertsUserMessage(
                headline: "Station not available",
                body: "This station isn't available for Price Alerts right now.",
                isRetryable: false
            )
        case .notConfigured:
            self = Self.unavailable
        case .credentialStorageUnavailable:
            self = PriceAlertsUserMessage(
                headline: "Couldn't use secure storage",
                body: "Your device couldn't securely store your alert settings. Try again in a moment.",
                isRetryable: true
            )
        case .api(let apiError):
            self = Self.message(for: apiError)
        }
    }

    static let unavailable = PriceAlertsUserMessage(
        headline: "Price Alerts unavailable",
        body: "Price Alerts aren't available in this version of the app right now.",
        isRetryable: false
    )

    static let busy = PriceAlertsUserMessage(
        headline: "Price Alerts is busy",
        body: "The service is temporarily unavailable. Try again in a few minutes.",
        isRetryable: true
    )

    static let generic = PriceAlertsUserMessage(
        headline: "Something went wrong",
        body: "Price Alerts couldn't complete that request. Try again.",
        isRetryable: true
    )

    private static func message(for failure: PriceAlertValidationFailure) -> PriceAlertsUserMessage {
        switch failure {
        case .thresholdOutOfRange:
            return PriceAlertsUserMessage(
                headline: "Check your target price",
                body: "Enter a price between \(PriceAlertPriceInput.allowedRangeText).",
                isRetryable: false
            )
        case .minimumChangeOutOfRange, .cooldownOutOfRange:
            return PriceAlertsUserMessage(
                headline: "Alert setting not valid",
                body: "That alert setting isn't supported.",
                isRetryable: false
            )
        case .unsupportedMode:
            return PriceAlertsUserMessage(
                headline: "Alert type not supported",
                body: "This alert uses a setting this version of 85Blends can't edit. Choose a new alert type to replace it.",
                isRetryable: false
            )
        }
    }

    private static func message(for error: PriceAlertsAPIError) -> PriceAlertsUserMessage {
        switch error {
        case .notConfigured:
            return unavailable
        case .network(let failure):
            switch failure {
            case .offline:
                return PriceAlertsUserMessage(
                    headline: "You're offline",
                    body: "Check your connection and try again.",
                    isRetryable: true
                )
            case .timedOut:
                return PriceAlertsUserMessage(
                    headline: "Request timed out",
                    body: "Price Alerts took too long to respond. Try again.",
                    isRetryable: true
                )
            case .secureConnectionFailed:
                return PriceAlertsUserMessage(
                    headline: "Secure connection failed",
                    body: "We couldn't make a secure connection to Price Alerts. Try again later.",
                    isRetryable: true
                )
            case .cancelled:
                return PriceAlertsUserMessage(
                    headline: "Request interrupted",
                    body: "The request was interrupted. Try again.",
                    isRetryable: true
                )
            case .other:
                return PriceAlertsUserMessage(
                    headline: "Can't reach Price Alerts",
                    body: "Check your connection and try again.",
                    isRetryable: true
                )
            }
        case .invalidResponse, .decoding:
            if error.isTransient {
                return busy
            }
            return PriceAlertsUserMessage(
                headline: "Unexpected response",
                body: "Price Alerts sent a response we couldn't read. Try again later.",
                isRetryable: true
            )
        case .api(let code, _):
            if error.isTransient {
                return busy
            }
            switch code {
            case .invalidInstallationCredentials:
                return PriceAlertsUserMessage(
                    headline: "Couldn't verify this device",
                    body: "We couldn't verify this device with Price Alerts. Try again.",
                    isRetryable: true
                )
            case .unauthorized, .serverNotConfigured:
                return unavailable
            case .proRequired:
                return PriceAlertsUserMessage(error: .proRequiredByServer)
            case .stationNotFound:
                return PriceAlertsUserMessage(error: .stationNotFound)
            case .invalidPaymentType:
                return PriceAlertsUserMessage(
                    headline: "Choose Cash or Credit",
                    body: "Choose which price this alert should watch, then try again.",
                    isRetryable: false
                )
            default:
                return generic
            }
        }
    }
}

// MARK: - Notifications

/// What the notification card says and offers, for every state notification delivery can be in.
nonisolated struct PriceAlertsNotificationPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Never opted in on this device. The one state that offers to turn notifications on.
        case notEnabled
        case enabling
        case enabled
        /// The person said no (to the system prompt, or later in Settings).
        case denied
        /// The system gave no notification token: still waiting, or this build/device cannot get one.
        case notReady
        /// The push environment of this build could not be established, so nothing is registered.
        case unavailable
        case needsPro
        case checkingSubscription
        /// A recent attempt failed; the app retries by itself, and the person can retry now.
        case retryScheduled
        case failed
    }

    enum Action: Equatable, Sendable {
        case none
        /// Start the opt-in. The ONLY way notification registration is ever started from a Price Alerts
        /// screen: it is always a tap.
        case turnOn
        case tryAgain
        case openSettings
    }

    let kind: Kind
    let title: String
    let detail: String
    let systemImage: String
    let action: Action

    var isEnabled: Bool {
        kind == .enabled
    }

    /// - Parameters:
    ///   - isEnabling: an opt-in started from this screen is in flight.
    ///   - lastOutcome: the most recent registration attempt this process made (the user's, or the
    ///     app-level reconcile), `nil` if none.
    ///   - hasRegisteredDevice: this install registered a device in the past (a local record only).
    static func make(
        isEnabling: Bool,
        lastOutcome: PriceAlertsDeviceRegistrationOutcome?,
        hasRegisteredDevice: Bool
    ) -> PriceAlertsNotificationPresentation {
        if isEnabling {
            return enabling
        }
        guard let lastOutcome else {
            return hasRegisteredDevice ? enabled : notEnabled
        }
        switch lastOutcome {
        case .registered, .alreadyRegistered:
            return enabled
        case .skipped(let reason):
            switch reason {
            case .notificationsDenied: return denied
            case .noDeviceToken: return notReady
            case .pushEnvironmentUnresolved: return unavailable
            case .notOptedIn: return hasRegisteredDevice ? enabled : notEnabled
            case .proRequired: return needsPro
            case .entitlementUnresolved: return checkingSubscription
            case .backingOff: return retryScheduled
            }
        case .failed(let error):
            let message = PriceAlertsUserMessage(error: error)
            return PriceAlertsNotificationPresentation(
                kind: .failed,
                title: message.headline,
                detail: message.body,
                systemImage: "exclamationmark.triangle.fill",
                action: message.isRetryable ? .tryAgain : .none
            )
        }
    }

    static let notEnabled = PriceAlertsNotificationPresentation(
        kind: .notEnabled,
        title: "Turn on notifications",
        detail: "Get Price Alerts as notifications on this device. If you haven't been asked yet, you'll be asked for permission.",
        systemImage: "bell.badge",
        action: .turnOn
    )

    static let enabling = PriceAlertsNotificationPresentation(
        kind: .enabling,
        title: "Setting up notifications…",
        detail: "This can take a few seconds.",
        systemImage: "bell",
        action: .none
    )

    static let enabled = PriceAlertsNotificationPresentation(
        kind: .enabled,
        title: "Notifications are on",
        detail: "You'll get Price Alerts on this device.",
        systemImage: "checkmark.circle.fill",
        action: .none
    )

    static let denied = PriceAlertsNotificationPresentation(
        kind: .denied,
        title: "Notifications are turned off",
        detail: "Allow notifications for 85Blends in Settings to receive Price Alerts. Your alerts are saved either way.",
        systemImage: "bell.slash",
        action: .openSettings
    )

    static let notReady = PriceAlertsNotificationPresentation(
        kind: .notReady,
        title: "Notifications aren't ready yet",
        detail: "We couldn't finish setting up notifications on this device. Your alerts are saved. Try again in a moment.",
        systemImage: "exclamationmark.triangle.fill",
        action: .tryAgain
    )

    static let unavailable = PriceAlertsNotificationPresentation(
        kind: .unavailable,
        title: "Notifications aren't available yet",
        detail: "Your alerts are saved, but this version of the app can't deliver notifications yet.",
        systemImage: "exclamationmark.triangle.fill",
        action: .none
    )

    static let needsPro = PriceAlertsNotificationPresentation(
        kind: .needsPro,
        title: "Notifications need 85Blends Pro",
        detail: "Price Alerts are part of 85Blends Pro.",
        systemImage: "lock.fill",
        action: .none
    )

    static let checkingSubscription = PriceAlertsNotificationPresentation(
        kind: .checkingSubscription,
        title: "Checking your subscription",
        detail: "We're still confirming your subscription. Try again in a moment.",
        systemImage: "clock",
        action: .tryAgain
    )

    static let retryScheduled = PriceAlertsNotificationPresentation(
        kind: .retryScheduled,
        title: "We'll try again shortly",
        detail: "We couldn't reach Price Alerts a moment ago. Notifications will be set up automatically, or you can try now.",
        systemImage: "arrow.clockwise",
        action: .tryAgain
    )
}
