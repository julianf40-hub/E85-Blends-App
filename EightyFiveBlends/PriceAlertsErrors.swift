//
//  PriceAlertsErrors.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). The error vocabulary of the Price
//  Alerts client, in two layers:
//
//    - `PriceAlertsAPIError` is what the wire layer (PriceAlertsAPIClient / the transport) throws:
//      the backend's `{ "error": "<code>" }` bodies, plus network, response-shape and
//      configuration failures.
//    - `PriceAlertsServiceError` is what PriceAlertsService throws and what a UI switches over: the
//      same failures after the service has applied its own rules (the Pro gate, the station-ID
//      requirement, installation recovery).
//
//  NOTHING HERE CARRIES A SECRET OR A REQUEST. Errors hold backend error codes, HTTP status codes and
//  coarse categories only — never an installation secret, a device token, a response body, a URL or
//  the text of a system error (which can embed a hostname or path). That is what makes it safe for
//  any caller to log or display one.
//

import Foundation

// MARK: - Network

/// Why a request produced no HTTP response, reduced to a category. The underlying `URLError` text is
/// deliberately dropped: it can contain the request URL.
nonisolated enum PriceAlertsNetworkFailure: Equatable, Sendable {
    case offline
    case timedOut
    case cancelled
    case secureConnectionFailed
    case other

    init(_ error: Error) {
        guard let urlError = error as? URLError else {
            self = error is CancellationError ? .cancelled : .other
            return
        }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .networkConnectionLost:
            self = .offline
        case .timedOut:
            self = .timedOut
        case .cancelled:
            self = .cancelled
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            self = .secureConnectionFailed
        default:
            self = .other
        }
    }
}

// MARK: - Backend error codes

/// The `error` string of a failed price-alerts-api response, mapped one-to-one so nothing is
/// conflated at this layer. `.unknown` keeps a code added by a newer backend representable.
nonisolated enum PriceAlertsAPIErrorCode: Equatable, Sendable {
    /// 401 — the project API key was rejected. A configuration problem; it says nothing about the
    /// installation and is never cured by touching it.
    case unauthorized
    /// 401 — the installation id is unknown to the server, or the secret does not match. 400 — the id
    /// or secret is malformed.
    case invalidInstallationCredentials
    /// 403 — `set_alert` by an installation the server does not consider Pro.
    case proRequired
    /// 404 — `set_alert` for a station that is not in `community_stations`.
    case stationNotFound

    case invalidAlert
    case invalidThresholdPrice
    case thresholdOnlyValidForAtOrBelow
    case invalidAlertPreferences
    case invalidStationID
    case invalidDeviceRegistration
    case invalidDeviceToken
    case invalidPlatform
    case invalidContributorID
    case invalidAppVersion
    case revenueCatIdentityRequiresEnvironment
    case invalidRevenueCatIdentity

    case invalidJSON
    case invalidJSONObject
    case actionRequired
    case unknownAction
    case methodNotAllowed
    case serverNotConfigured
    case internalError

    case unknown(String)

    init(wireValue: String) {
        switch wireValue {
        case "unauthorized": self = .unauthorized
        case "invalid_installation_credentials": self = .invalidInstallationCredentials
        case "pro_required": self = .proRequired
        case "station_not_found": self = .stationNotFound
        case "invalid_alert": self = .invalidAlert
        case "invalid_threshold_price": self = .invalidThresholdPrice
        case "threshold_only_valid_for_at_or_below": self = .thresholdOnlyValidForAtOrBelow
        case "invalid_alert_preferences": self = .invalidAlertPreferences
        case "invalid_station_id": self = .invalidStationID
        case "invalid_device_registration": self = .invalidDeviceRegistration
        case "invalid_device_token": self = .invalidDeviceToken
        case "invalid_platform": self = .invalidPlatform
        case "invalid_contributor_id": self = .invalidContributorID
        case "invalid_app_version": self = .invalidAppVersion
        case "revenuecat_identity_requires_environment": self = .revenueCatIdentityRequiresEnvironment
        case "invalid_revenuecat_identity": self = .invalidRevenueCatIdentity
        case "invalid_json": self = .invalidJSON
        case "invalid_json_object": self = .invalidJSONObject
        case "action_required": self = .actionRequired
        case "unknown_action": self = .unknownAction
        case "method_not_allowed": self = .methodNotAllowed
        case "server_not_configured": self = .serverNotConfigured
        case "internal_error": self = .internalError
        default: self = .unknown(String(wireValue.prefix(64)))
        }
    }
}

// MARK: - Wire-layer error

nonisolated enum PriceAlertsAPIError: Error, Equatable, Sendable {
    /// No usable Supabase URL / client key in this build's configuration.
    case notConfigured
    /// No HTTP response at all.
    case network(PriceAlertsNetworkFailure)
    /// A response that is not a price-alerts-api error body and not the expected success shape
    /// (e.g. a gateway's HTML 502). `statusCode` is `nil` when the response was not HTTP at all.
    case invalidResponse(statusCode: Int?)
    /// A 2xx whose body is not the shape this build expects, or a request that could not be encoded.
    case decoding
    /// A price-alerts-api `{ "error": … }` response.
    case api(code: PriceAlertsAPIErrorCode, statusCode: Int)

    /// The installation is unknown to the server or its secret no longer matches (401).
    var rejectsInstallationCredentials: Bool {
        if case .api(.invalidInstallationCredentials, 401) = self { return true }
        return false
    }

    /// `set_alert` by an installation the server does not consider Pro (403).
    var isProRequired: Bool {
        if case .api(.proRequired, 403) = self { return true }
        return false
    }

    /// Worth trying again later without changing anything: the network, or the server being
    /// unavailable or overloaded. A cancelled request is not a failure to retry.
    var isTransient: Bool {
        switch self {
        case .network(let failure):
            return failure != .cancelled
        case .invalidResponse(let statusCode):
            return statusCode.map { $0 >= 500 || $0 == 429 || $0 == 408 } ?? true
        case .api(_, let statusCode):
            return statusCode >= 500 || statusCode == 429 || statusCode == 408
        case .notConfigured, .decoding:
            return false
        }
    }
}

// MARK: - Service-layer error

nonisolated enum PriceAlertsServiceError: Error, Equatable, Sendable {
    // MARK: Refused before any request

    /// The station has no canonical backend UUID (`FuelStation.communityStationID` is `nil`), which
    /// is the only identity Price Alerts accepts. Never worked around by name, coordinates, a
    /// canonical key, a hash or a generated UUID.
    case stationNotEligibleForPriceAlerts
    /// A value the backend would reject (threshold, minimum change or cooldown out of range).
    case invalidAlert(PriceAlertValidationFailure)
    /// The user does not have Pro. Price Alerts are a Pro feature; this gate is applied to creating
    /// or changing an alert (and to creating a new installation), never to listing or deleting.
    case proRequired
    /// RevenueCat has not produced an authoritative answer yet this launch, so "Free" would be a
    /// guess. Retry once the entitlement resolves (`SubscriptionManager.refreshProStatus()`).
    case entitlementUnresolved

    // MARK: Server verdicts

    /// The server does not consider this installation Pro even after its RevenueCat link was
    /// refreshed — a webhook that has not landed yet, or (Debug/Internal builds only) a Developer Pro
    /// Override that RevenueCat does not agree with. The backend is authoritative for this gate.
    case proRequiredByServer
    /// `station_not_found`: the saved station's UUID is not a community station on the server.
    case stationNotFound

    // MARK: Plumbing

    case notConfigured
    /// The Keychain could not be read or written right now. Never carries the raw `OSStatus`.
    case credentialStorageUnavailable
    case api(PriceAlertsAPIError)

    /// Maps anything thrown below the service into a service error.
    static func from(_ error: Error) -> PriceAlertsServiceError {
        if let serviceError = error as? PriceAlertsServiceError {
            return serviceError
        }
        guard let apiError = error as? PriceAlertsAPIError else {
            return .api(.network(PriceAlertsNetworkFailure(error)))
        }
        switch apiError {
        case .notConfigured:
            return .notConfigured
        case .api(.stationNotFound, _):
            return .stationNotFound
        case .api(.proRequired, _):
            return .proRequiredByServer
        default:
            return .api(apiError)
        }
    }

    /// Whether the same operation is worth offering again later without changing anything.
    var isRetryable: Bool {
        switch self {
        case .api(let error):
            return error.isTransient
        case .entitlementUnresolved, .credentialStorageUnavailable:
            return true
        default:
            return false
        }
    }
}
