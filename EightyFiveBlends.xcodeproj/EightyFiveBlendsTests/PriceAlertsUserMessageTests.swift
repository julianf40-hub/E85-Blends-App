//
//  PriceAlertsUserMessageTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B) — the words a person sees (PriceAlertsUserMessages.swift): every error
//  and every notification state has friendly copy; nothing technical can reach a person (no HTTP
//  status, backend error code, function name, id, secret or token); and "still checking your
//  subscription" is never confused with "not Pro".
//
//  Pure value logic: no network, no Keychain, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

/// Every service error a screen can meet, including the whole matrix of wire-level failures.
private func everyServiceError() -> [PriceAlertsServiceError] {
    var errors: [PriceAlertsServiceError] = [
        .stationNotEligibleForPriceAlerts,
        .invalidAlert(.thresholdOutOfRange),
        .invalidAlert(.minimumChangeOutOfRange),
        .invalidAlert(.cooldownOutOfRange),
        .invalidAlert(.unsupportedMode),
        .proRequired,
        .entitlementUnresolved,
        .proRequiredByServer,
        .stationNotFound,
        .notConfigured,
        .credentialStorageUnavailable,
        .api(.notConfigured),
        .api(.decoding),
        .api(.invalidResponse(statusCode: nil)),
        .api(.invalidResponse(statusCode: 502)),
        .api(.invalidResponse(statusCode: 418)),
    ]
    for failure in [PriceAlertsNetworkFailure.offline, .timedOut, .cancelled, .secureConnectionFailed, .other] {
        errors.append(.api(.network(failure)))
    }
    let codes: [PriceAlertsAPIErrorCode] = [
        .unauthorized, .invalidInstallationCredentials, .proRequired, .stationNotFound, .invalidAlert,
        .invalidThresholdPrice, .thresholdOnlyValidForAtOrBelow, .invalidAlertPreferences, .invalidStationID,
        .invalidDeviceRegistration, .invalidDeviceToken, .invalidPlatform, .invalidContributorID,
        .invalidAppVersion, .revenueCatIdentityRequiresEnvironment, .invalidRevenueCatIdentity, .invalidJSON,
        .invalidJSONObject, .actionRequired, .unknownAction, .methodNotAllowed, .serverNotConfigured,
        .internalError, .unknown("brand_new_code"),
    ]
    for code in codes {
        for status in [400, 401, 403, 404, 408, 429, 500, 503] {
            errors.append(.api(.api(code: code, statusCode: status)))
        }
    }
    return errors
}

struct PriceAlertsUserMessageTests {
    @Test("Every error a screen can meet has friendly text, and none of it is technical")
    func everyError_isFriendlyAndSafe() {
        let errors = everyServiceError()
        #expect(errors.count > 150)
        for error in errors {
            let message = PriceAlertsUserMessage(error: error)
            assertSafeToShow(message.headline)
            assertSafeToShow(message.body)
        }
    }

    @Test("Connectivity problems say what is wrong in a person's terms and can be retried")
    func connectivity_messages() {
        let offline = PriceAlertsUserMessage(error: .api(.network(.offline)))
        #expect(offline.headline == "You're offline")
        #expect(offline.isRetryable)

        let timedOut = PriceAlertsUserMessage(error: .api(.network(.timedOut)))
        #expect(timedOut.headline == "Request timed out")
        #expect(timedOut.isRetryable)

        #expect(PriceAlertsUserMessage(error: .api(.network(.secureConnectionFailed))).headline == "Secure connection failed")
        #expect(PriceAlertsUserMessage(error: .api(.network(.other))).headline == "Can't reach Price Alerts")
        // Never silent: an interrupted request still says so.
        #expect(PriceAlertsUserMessage(error: .api(.network(.cancelled))).headline == "Request interrupted")
    }

    @Test("A busy or failing backend reads the same however it fails, and never shows the status")
    func backendUnavailable_isOneMessage() {
        let busy = PriceAlertsUserMessage.busy
        for status in [429, 500, 502, 503] {
            #expect(PriceAlertsUserMessage(error: .api(.api(code: .internalError, statusCode: status))) == busy)
            #expect(PriceAlertsUserMessage(error: .api(.invalidResponse(statusCode: status))) == busy)
        }
        #expect(busy.isRetryable)
        // A response nobody could read is a different problem from a busy server.
        #expect(PriceAlertsUserMessage(error: .api(.decoding)).headline == "Unexpected response")
        #expect(PriceAlertsUserMessage(error: .api(.invalidResponse(statusCode: 418))).headline == "Unexpected response")
    }

    @Test("'Still checking your subscription' is never the same message as 'Pro required' — Free is not guessed")
    func unresolved_isNotPro() {
        let checking = PriceAlertsUserMessage(error: .entitlementUnresolved)
        let required = PriceAlertsUserMessage(error: .proRequired)

        #expect(checking != required)
        #expect(checking.headline == "Checking your subscription")
        #expect(checking.isRetryable)
        #expect(required.headline == "Pro feature")
        #expect(required.isRetryable == false)
        #expect(checking.body.lowercased().contains("upgrade") == false)
        #expect(checking.body.lowercased().contains("free") == false)
    }

    @Test("When the server does not (yet) see Pro, the message is gentle, retryable, and says nothing technical")
    func proRequiredByServer_isGraceful() {
        let message = PriceAlertsUserMessage(error: .proRequiredByServer)

        #expect(message.headline == "Couldn't confirm Pro yet")
        #expect(message.body.contains("just subscribed"))
        #expect(message.isRetryable)
        // The wire code that reaches the service as the same thing reads the same.
        #expect(PriceAlertsUserMessage(error: .api(.api(code: .proRequired, statusCode: 403))) == message)
    }

    @Test("A station that cannot have alerts is explained without naming any identifier")
    func stationMessages() {
        let ineligible = PriceAlertsUserMessage(error: .stationNotEligibleForPriceAlerts)
        #expect(ineligible.headline == "Not available for this station")
        #expect(ineligible.isRetryable == false)

        let missing = PriceAlertsUserMessage(error: .stationNotFound)
        #expect(missing.headline == "Station not available")
        #expect(PriceAlertsUserMessage(error: .api(.api(code: .stationNotFound, statusCode: 404))) == missing)
    }

    @Test("A price outside the allowed range quotes the shared bounds; other setting problems are generic")
    func validationMessages() {
        let price = PriceAlertsUserMessage(error: .invalidAlert(.thresholdOutOfRange))
        #expect(price.body == "Enter a price between $1.00 and $8.00.")
        #expect(PriceAlertsUserMessage(error: .invalidAlert(.unsupportedMode)).body.contains("replace"))
        #expect(PriceAlertsUserMessage(error: .invalidAlert(.cooldownOutOfRange)).headline == "Alert setting not valid")
    }

    @Test("Retry is offered exactly where trying again can help")
    func retryability() {
        let notRetryable: [PriceAlertsServiceError] = [
            .stationNotEligibleForPriceAlerts, .invalidAlert(.thresholdOutOfRange), .proRequired,
            .stationNotFound, .notConfigured, .api(.notConfigured),
        ]
        for error in notRetryable {
            #expect(PriceAlertsUserMessage(error: error).isRetryable == false, "\(error)")
        }
        let retryable: [PriceAlertsServiceError] = [
            .entitlementUnresolved, .proRequiredByServer, .credentialStorageUnavailable,
            .api(.network(.offline)), .api(.decoding), .api(.api(code: .internalError, statusCode: 500)),
        ]
        for error in retryable {
            #expect(PriceAlertsUserMessage(error: error).isRetryable, "\(error)")
        }
    }
}

// MARK: - Notification states

struct PriceAlertsNotificationPresentationTests {
    private func make(
        enabling: Bool = false,
        _ outcome: PriceAlertsDeviceRegistrationOutcome? = nil,
        registered: Bool = false
    ) -> PriceAlertsNotificationPresentation {
        PriceAlertsNotificationPresentation.make(isEnabling: enabling, lastOutcome: outcome, hasRegisteredDevice: registered)
    }

    @Test("Every notification state has friendly, non-technical copy and an icon")
    func everyState_isFriendlyAndSafe() {
        let simple: [PriceAlertsDeviceRegistrationOutcome?] = [
            nil, .registered, .alreadyRegistered,
            .skipped(.notificationsDenied), .skipped(.noDeviceToken), .skipped(.pushEnvironmentUnresolved),
            .skipped(.notOptedIn), .skipped(.proRequired), .skipped(.entitlementUnresolved),
            .skipped(.backingOff(until: Date(timeIntervalSince1970: 1_800_000_000))),
        ]
        let failures: [PriceAlertsDeviceRegistrationOutcome?] = everyServiceError().map {
            PriceAlertsDeviceRegistrationOutcome.failed($0)
        }

        for outcome in simple + failures {
            for registered in [false, true] {
                let presentation = make(outcome, registered: registered)
                assertSafeToShow(presentation.title)
                assertSafeToShow(presentation.detail)
                #expect(presentation.systemImage.isEmpty == false)
            }
        }
        assertSafeToShow(make(enabling: true).title)
    }

    @Test("Never opted in offers to turn notifications on; a returning device shows them on")
    func startingStates() {
        let off = make()
        #expect(off.kind == .notEnabled)
        #expect(off.action == .turnOn)
        #expect(off.isEnabled == false)

        let returning = make(registered: true)
        #expect(returning.kind == .enabled)
        #expect(returning.action == .none)
        #expect(returning.isEnabled)
    }

    @Test("Registered and already-registered both read as on, with nothing left to do")
    func registered_isOn() {
        for outcome in [PriceAlertsDeviceRegistrationOutcome.registered, .alreadyRegistered] {
            let presentation = make(outcome)
            #expect(presentation.kind == .enabled)
            #expect(presentation.title == "Notifications are on")
            #expect(presentation.action == .none)
            #expect(presentation.systemImage == "checkmark.circle.fill")
        }
    }

    @Test("Denied points to Settings and says the alerts are saved either way")
    func denied() {
        let presentation = make(.skipped(.notificationsDenied))
        #expect(presentation.kind == .denied)
        #expect(presentation.action == .openSettings)
        #expect(presentation.detail.contains("Settings"))
        #expect(presentation.detail.contains("saved"))
        // A user who denied is not told to turn them on from here: that would only re-ask the OS.
        #expect(presentation.action != .turnOn)
    }

    @Test("No device token (still waiting, simulator, or a build that cannot get one) is 'not ready yet', retryable, and reassuring")
    func noDeviceToken() {
        let presentation = make(.skipped(.noDeviceToken))
        #expect(presentation.kind == .notReady)
        #expect(presentation.action == .tryAgain)
        #expect(presentation.detail.contains("saved"))
    }

    @Test("An unresolved push environment says this build cannot deliver yet, with no retry that cannot help")
    func pushEnvironmentUnresolved() {
        let presentation = make(.skipped(.pushEnvironmentUnresolved))
        #expect(presentation.kind == .unavailable)
        #expect(presentation.action == .none)
        #expect(presentation.detail.contains("saved"))
    }

    @Test("Pro and subscription states are different: one is a lock, the other is 'still checking'")
    func proStates() {
        let needsPro = make(.skipped(.proRequired))
        let checking = make(.skipped(.entitlementUnresolved))

        #expect(needsPro.kind == .needsPro)
        #expect(needsPro.action == .none)
        #expect(checking.kind == .checkingSubscription)
        #expect(checking.action == .tryAgain)
        #expect(needsPro != checking)
    }

    @Test("A backed-off attempt says it will retry, and still lets the person retry now")
    func backingOff() {
        let presentation = make(.skipped(.backingOff(until: Date(timeIntervalSince1970: 1_800_000_000))))
        #expect(presentation.kind == .retryScheduled)
        #expect(presentation.action == .tryAgain)
        #expect(presentation.title == "We'll try again shortly")
    }

    @Test("A failure shows the error's friendly message, with 'Try Again' only when that can help")
    func failure() {
        let offline = make(.failed(.api(.network(.offline))))
        #expect(offline.kind == .failed)
        #expect(offline.title == "You're offline")
        #expect(offline.action == .tryAgain)

        let notRetryable = make(.failed(.notConfigured))
        #expect(notRetryable.kind == .failed)
        #expect(notRetryable.action == .none)
    }

    @Test("In progress wins over everything, and cannot be tapped again")
    func enabling_wins() {
        let presentation = make(enabling: true, .skipped(.notificationsDenied), registered: true)
        #expect(presentation.kind == .enabling)
        #expect(presentation.action == .none)
    }

    @Test("Only the 'never opted in' state offers to start notifications — every other state is a result, a retry or a link to Settings")
    func onlyOneStateStartsOptIn() {
        let outcomes: [PriceAlertsDeviceRegistrationOutcome?] = [
            nil, .registered, .alreadyRegistered, .skipped(.notificationsDenied), .skipped(.noDeviceToken),
            .skipped(.pushEnvironmentUnresolved), .skipped(.proRequired), .skipped(.entitlementUnresolved),
            .skipped(.backingOff(until: .distantFuture)), .failed(.api(.network(.offline))),
        ]
        for outcome in outcomes {
            let presentation = make(outcome, registered: false)
            if presentation.action == .turnOn {
                #expect(presentation.kind == .notEnabled)
            }
        }
        #expect(make().action == .turnOn)
    }
}
