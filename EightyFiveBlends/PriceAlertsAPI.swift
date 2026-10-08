//
//  PriceAlertsAPI.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). The typed client for
//  supabase/functions/price-alerts-api — the ONLY path from the app to that function. It owns the
//  wire format (request bodies, response shapes, error bodies) and nothing else: no persistence, no
//  retry policy, no knowledge of Pro, stations or push state. Those live in the layers above
//  (PriceAlertsInstallationManager, PriceAlertsDeviceRegistrar, PriceAlertsService), each of which
//  talks to this protocol, so each can be tested against a fake.
//
//  THE CONTRACT. Every key name below is the backend's, taken from
//  supabase/functions/price-alerts-api/index.ts and recorded in
//  docs/PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md §1. The contract tests in
//  EightyFiveBlendsTests/PriceAlertsAPIContractTests.swift pin the exact JSON each call sends.
//
//  SECRETS. The installation secret rides in the JSON body (the backend's design, not ours) and is
//  never placed in a header, a URL or an error. `PriceAlertsWireRequest` holds the credential, the
//  device token and the RevenueCat identity as their redacting types, so even reflecting a request
//  (`dump`, `String(describing:)`) prints no secret. This file has no logging of any kind.
//
//  ONE ATTEMPT PER CALL. No retry loop lives here. Every action is idempotent on the server, so a
//  caller may safely repeat one; whether and when to is the caller's policy.
//

import Foundation

// MARK: - Transport seam

nonisolated struct PriceAlertsTransportResponse: Sendable {
    let statusCode: Int
    let data: Data
}

protocol PriceAlertsAPITransport: Sendable {
    /// POSTs a JSON body to price-alerts-api and returns the HTTP outcome, whatever its status.
    /// Throws `PriceAlertsAPIError` only for failures that produced no HTTP response at all
    /// (no configuration, no network, not HTTP).
    func post(_ body: Data) async throws -> PriceAlertsTransportResponse
}

// MARK: - RevenueCat identity (sent at bootstrap)

/// The two strings `bootstrap` accepts for `revenuecat_environment`.
nonisolated enum PriceAlertsRevenueCatEnvironment: String, Hashable, Sendable {
    case sandbox = "SANDBOX"
    case production = "PRODUCTION"
}

/// Who RevenueCat says this install is. Sent only at `bootstrap`, so that the SERVER can look up
/// whether that customer is Pro; the client never asserts Pro itself. Redacted in every description.
nonisolated struct PriceAlertsRevenueCatIdentity: Equatable, Sendable {
    /// price-alerts-api rejects an app user id outside 1...512 characters.
    static let appUserIDLengthRange = 1...512

    let appUserID: String
    let environment: PriceAlertsRevenueCatEnvironment

    /// Whether the backend would accept this identity. An unacceptable one is left out of the request
    /// rather than sent: a `400` here would fail the whole bootstrap.
    var isAcceptableToBackend: Bool {
        let trimmed = appUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == appUserID && Self.appUserIDLengthRange.contains(appUserID.count)
    }
}

extension PriceAlertsRevenueCatIdentity: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "PriceAlertsRevenueCatIdentity(<redacted>, \(environment.rawValue))"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: ["environment": environment.rawValue])
    }
}

// MARK: - Client protocol

protocol PriceAlertsAPIClienting: Sendable {
    func bootstrap(
        credential: PriceAlertsInstallationCredential,
        revenueCat: PriceAlertsRevenueCatIdentity?,
        appVersion: String?
    ) async throws -> PriceAlertsBootstrapResult

    /// Returns the server's device id.
    func registerDevice(
        credential: PriceAlertsInstallationCredential,
        token: PushDeviceToken,
        metadata: PushDeviceRegistrationMetadata
    ) async throws -> UUID?

    /// Returns whether a device row changed.
    func unregisterDevice(
        credential: PriceAlertsInstallationCredential,
        token: PushDeviceToken
    ) async throws -> Bool

    /// Create-or-replace the single alert this installation has for the draft's station.
    func saveAlert(
        credential: PriceAlertsInstallationCredential,
        draft: PriceAlertDraft
    ) async throws -> PriceAlert

    /// Returns whether an alert was removed (`false` if there was none).
    func deleteAlert(
        credential: PriceAlertsInstallationCredential,
        stationID: UUID
    ) async throws -> Bool

    func listAlerts(credential: PriceAlertsInstallationCredential) async throws -> [PriceAlertListing]

    func status(credential: PriceAlertsInstallationCredential) async throws -> PriceAlertsServerStatus
}

// MARK: - Wire request

/// One request body. Every key the backend reads is spelled in `CodingKeys` and nowhere else; the
/// static constructors set exactly the fields their action uses, so an action cannot accidentally
/// send another's. Optional fields that are `nil` are omitted from the JSON (the backend treats an
/// absent field and `null` alike).
nonisolated struct PriceAlertsWireRequest: Encodable, Sendable {
    enum Action: String, Sendable {
        case bootstrap
        case registerDevice = "register_device"
        case unregisterDevice = "unregister_device"
        case setAlert = "set_alert"
        case deleteAlert = "delete_alert"
        case listAlerts = "list_alerts"
        case status
    }

    /// price-alerts-api rejects an `app_version` outside 1...64 characters.
    static let appVersionLengthRange = 1...64
    /// Always `ios`: this is the iOS client. (The backend would default to the installation's
    /// platform, but the installation's platform is set from what bootstrap sends.)
    static let platform = "ios"

    let action: Action
    let credential: PriceAlertsInstallationCredential

    private(set) var platform: String?
    private(set) var appVersion: String?
    private(set) var revenueCat: PriceAlertsRevenueCatIdentity?
    private(set) var bundleID: String?
    private(set) var apnsEnvironment: APNsEnvironment?
    private(set) var deviceToken: PushDeviceToken?
    private(set) var stationID: UUID?
    private(set) var alertMode: PriceAlertMode?
    private(set) var thresholdPrice: PriceAlertAmount?
    private(set) var minimumChange: PriceAlertAmount?
    private(set) var cooldownMinutes: Int?
    private(set) var paymentType: PriceAlertPayment?

    private init(action: Action, credential: PriceAlertsInstallationCredential) {
        self.action = action
        self.credential = credential
    }

    // MARK: Constructors

    static func bootstrap(
        credential: PriceAlertsInstallationCredential,
        revenueCat: PriceAlertsRevenueCatIdentity?,
        appVersion: String?
    ) -> PriceAlertsWireRequest {
        var request = PriceAlertsWireRequest(action: .bootstrap, credential: credential)
        request.platform = Self.platform
        request.appVersion = sanitizedAppVersion(appVersion)
        // The pair is sent together or not at all (the backend rejects one without the other).
        if let revenueCat, revenueCat.isAcceptableToBackend {
            request.revenueCat = revenueCat
        }
        return request
    }

    static func registerDevice(
        credential: PriceAlertsInstallationCredential,
        token: PushDeviceToken,
        metadata: PushDeviceRegistrationMetadata
    ) -> PriceAlertsWireRequest {
        var request = PriceAlertsWireRequest(action: .registerDevice, credential: credential)
        request.platform = Self.platform
        request.bundleID = metadata.bundleIdentifier
        request.apnsEnvironment = metadata.apnsEnvironment
        request.deviceToken = token
        return request
    }

    static func unregisterDevice(
        credential: PriceAlertsInstallationCredential,
        token: PushDeviceToken
    ) -> PriceAlertsWireRequest {
        var request = PriceAlertsWireRequest(action: .unregisterDevice, credential: credential)
        request.deviceToken = token
        return request
    }

    /// Sends the draft's FULL state: mode, threshold (only for `at_or_below`), minimum change,
    /// cooldown and — when the caller chose one — the payment type. `set_alert` replaces all but the
    /// payment type, so none may be left to the backend's defaults unless the caller chose them. A
    /// draft with no (or an `unknown`) payment type OMITS the field: the server then keeps an existing
    /// alert's payment type, and stores `unknown` for a new one, as it did before payment types.
    /// `enabled` is never sent — the backend has no such field.
    static func setAlert(
        credential: PriceAlertsInstallationCredential,
        draft: PriceAlertDraft
    ) -> PriceAlertsWireRequest {
        var request = PriceAlertsWireRequest(action: .setAlert, credential: credential)
        request.stationID = draft.stationID
        request.alertMode = draft.rule.mode
        request.thresholdPrice = draft.rule.thresholdPrice
        request.minimumChange = draft.preferences.minimumChange
        request.cooldownMinutes = draft.preferences.cooldownMinutes
        if let paymentType = draft.paymentType, paymentType.isSpecified {
            request.paymentType = paymentType
        }
        return request
    }

    static func deleteAlert(
        credential: PriceAlertsInstallationCredential,
        stationID: UUID
    ) -> PriceAlertsWireRequest {
        var request = PriceAlertsWireRequest(action: .deleteAlert, credential: credential)
        request.stationID = stationID
        return request
    }

    static func listAlerts(credential: PriceAlertsInstallationCredential) -> PriceAlertsWireRequest {
        PriceAlertsWireRequest(action: .listAlerts, credential: credential)
    }

    static func status(credential: PriceAlertsInstallationCredential) -> PriceAlertsWireRequest {
        PriceAlertsWireRequest(action: .status, credential: credential)
    }

    /// Trimmed, and dropped (rather than sent) if empty or too long — a `400 invalid_app_version`
    /// would fail the whole bootstrap over a cosmetic field.
    static func sanitizedAppVersion(_ version: String?) -> String? {
        guard let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              appVersionLengthRange.contains(trimmed.count)
        else { return nil }
        return trimmed
    }

    // MARK: Encoding

    private enum CodingKeys: String, CodingKey {
        case action
        case clientInstallationID = "client_installation_id"
        case installationSecret = "installation_secret"
        case platform
        case appVersion = "app_version"
        case revenueCatAppUserID = "revenuecat_app_user_id"
        case revenueCatEnvironment = "revenuecat_environment"
        case bundleID = "bundle_id"
        case apnsEnvironment = "apns_environment"
        case deviceToken = "device_token"
        case stationID = "station_id"
        case alertMode = "alert_mode"
        case thresholdPrice = "threshold_price"
        case minimumChange = "minimum_change"
        case cooldownMinutes = "cooldown_minutes"
        case paymentType = "payment_type"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action.rawValue, forKey: .action)
        try container.encode(credential.wireInstallationID, forKey: .clientInstallationID)
        try container.encode(credential.installationSecret, forKey: .installationSecret)
        try container.encodeIfPresent(platform, forKey: .platform)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        if let revenueCat {
            try container.encode(revenueCat.appUserID, forKey: .revenueCatAppUserID)
            try container.encode(revenueCat.environment.rawValue, forKey: .revenueCatEnvironment)
        }
        try container.encodeIfPresent(bundleID, forKey: .bundleID)
        try container.encodeIfPresent(apnsEnvironment?.rawValue, forKey: .apnsEnvironment)
        try container.encodeIfPresent(deviceToken?.hexString, forKey: .deviceToken)
        try container.encodeIfPresent(stationID?.uuidString.lowercased(), forKey: .stationID)
        try container.encodeIfPresent(alertMode, forKey: .alertMode)
        try container.encodeIfPresent(thresholdPrice, forKey: .thresholdPrice)
        try container.encodeIfPresent(minimumChange, forKey: .minimumChange)
        try container.encodeIfPresent(cooldownMinutes, forKey: .cooldownMinutes)
        try container.encodeIfPresent(paymentType?.wireValue, forKey: .paymentType)
    }
}

// MARK: - Wire responses

private nonisolated struct ErrorBody: Decodable {
    let error: String
}

private nonisolated struct BootstrapResponse: Decodable {
    let status: String
    let clientInstallationID: UUID
    let proIsActive: Bool
    let revenueCatLinked: Bool

    private enum CodingKeys: String, CodingKey {
        case status
        case clientInstallationID = "client_installation_id"
        case proIsActive = "pro_is_active"
        case revenueCatLinked = "revenuecat_linked"
    }
}

private nonisolated struct RegisterDeviceResponse: Decodable {
    let status: String
    let deviceID: UUID?

    private enum CodingKeys: String, CodingKey {
        case status
        case deviceID = "device_id"
    }
}

private nonisolated struct ChangedResponse: Decodable {
    let status: String
    let changed: Bool
}

private nonisolated struct SaveAlertResponse: Decodable {
    let status: String
    let alert: PriceAlert
}

private nonisolated struct ListAlertsResponse: Decodable {
    let alerts: [PriceAlertListing]
}

private nonisolated struct StatusResponse: Decodable {
    let proIsActive: Bool
    let revenueCatLinked: Bool
    let activeDevices: Int
    let enabledAlerts: Int

    private enum CodingKeys: String, CodingKey {
        case proIsActive = "pro_is_active"
        case revenueCatLinked = "revenuecat_linked"
        case activeDevices = "active_devices"
        case enabledAlerts = "enabled_alerts"
    }
}

// MARK: - Client

struct PriceAlertsAPIClient: PriceAlertsAPIClienting {
    private let transport: any PriceAlertsAPITransport

    init(transport: any PriceAlertsAPITransport) {
        self.transport = transport
    }

    func bootstrap(
        credential: PriceAlertsInstallationCredential,
        revenueCat: PriceAlertsRevenueCatIdentity?,
        appVersion: String?
    ) async throws -> PriceAlertsBootstrapResult {
        let response: BootstrapResponse = try await perform(
            .bootstrap(credential: credential, revenueCat: revenueCat, appVersion: appVersion)
        )
        // A reply about some other installation (a misrouted proxy, a wrong project) is not ours to use.
        guard response.status == "ready", response.clientInstallationID == credential.installationID else {
            throw PriceAlertsAPIError.invalidResponse(statusCode: 200)
        }
        return PriceAlertsBootstrapResult(
            proIsActive: response.proIsActive,
            revenueCatLinked: response.revenueCatLinked
        )
    }

    func registerDevice(
        credential: PriceAlertsInstallationCredential,
        token: PushDeviceToken,
        metadata: PushDeviceRegistrationMetadata
    ) async throws -> UUID? {
        let response: RegisterDeviceResponse = try await perform(
            .registerDevice(credential: credential, token: token, metadata: metadata)
        )
        guard response.status == "registered" else {
            throw PriceAlertsAPIError.invalidResponse(statusCode: 200)
        }
        return response.deviceID
    }

    func unregisterDevice(
        credential: PriceAlertsInstallationCredential,
        token: PushDeviceToken
    ) async throws -> Bool {
        let response: ChangedResponse = try await perform(.unregisterDevice(credential: credential, token: token))
        guard response.status == "unregistered" else {
            throw PriceAlertsAPIError.invalidResponse(statusCode: 200)
        }
        return response.changed
    }

    func saveAlert(
        credential: PriceAlertsInstallationCredential,
        draft: PriceAlertDraft
    ) async throws -> PriceAlert {
        let response: SaveAlertResponse = try await perform(.setAlert(credential: credential, draft: draft))
        // The reply must describe the station we asked about.
        guard response.status == "saved", response.alert.stationID == draft.stationID else {
            throw PriceAlertsAPIError.invalidResponse(statusCode: 200)
        }
        return response.alert
    }

    func deleteAlert(
        credential: PriceAlertsInstallationCredential,
        stationID: UUID
    ) async throws -> Bool {
        let response: ChangedResponse = try await perform(.deleteAlert(credential: credential, stationID: stationID))
        guard response.status == "deleted" else {
            throw PriceAlertsAPIError.invalidResponse(statusCode: 200)
        }
        return response.changed
    }

    func listAlerts(credential: PriceAlertsInstallationCredential) async throws -> [PriceAlertListing] {
        let response: ListAlertsResponse = try await perform(.listAlerts(credential: credential))
        return response.alerts
    }

    func status(credential: PriceAlertsInstallationCredential) async throws -> PriceAlertsServerStatus {
        let response: StatusResponse = try await perform(.status(credential: credential))
        return PriceAlertsServerStatus(
            proIsActive: response.proIsActive,
            revenueCatLinked: response.revenueCatLinked,
            activeDevices: response.activeDevices,
            enabledAlerts: response.enabledAlerts
        )
    }

    // MARK: Plumbing

    private func perform<Response: Decodable>(_ request: PriceAlertsWireRequest) async throws -> Response {
        let body: Data
        do {
            body = try Self.encoder().encode(request)
        } catch {
            throw PriceAlertsAPIError.decoding
        }

        let response = try await transport.post(body)

        guard (200...299).contains(response.statusCode) else {
            throw Self.apiError(from: response)
        }
        do {
            return try Self.decoder().decode(Response.self, from: response.data)
        } catch {
            throw PriceAlertsAPIError.decoding
        }
    }

    /// `{ "error": "<code>" }` becomes `.api`; anything else (a gateway's HTML, an empty body)
    /// becomes `.invalidResponse` carrying only the status.
    static func apiError(from response: PriceAlertsTransportResponse) -> PriceAlertsAPIError {
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: response.data) {
            return .api(code: PriceAlertsAPIErrorCode(wireValue: body.error), statusCode: response.statusCode)
        }
        return .invalidResponse(statusCode: response.statusCode)
    }

    /// Sorted keys: byte-for-byte deterministic bodies (the contract tests rely on it).
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Timestamps arrive as ISO-8601 with milliseconds (JavaScript `Date.toJSON`); whole seconds are
    /// accepted too.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SupabaseTimestamp.decodingStrategy
        return decoder
    }
}
