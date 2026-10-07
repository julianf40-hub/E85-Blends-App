//
//  PriceAlertsAPIContractTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts client integration (Phase 3A) — the WIRE CONTRACT with supabase/functions/price-alerts-api
//  (docs/PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md §1): the exact JSON every call sends, how every
//  backend response shape decodes, how errors are classified, and the request the transport builds.
//  Everything runs against FakePriceAlertsTransport / local fixtures; no network is touched.
//
//  Request bodies contain the installation secret, so no assertion here ever prints a value: bodies
//  are compared key by key and a mismatch names the KEY only.
//

import Foundation
import Testing
@testable import EightyFiveBlends

// MARK: - Helpers

private func jsonValueEqual(_ actual: Any, _ expected: Any) -> Bool {
    switch expected {
    case let text as String: return (actual as? String) == text
    case let flag as Bool: return (actual as? Bool) == flag
    case let whole as Int: return (actual as? Int) == whole
    case let number as Double: return (actual as? Double) == number
    default: return false
    }
}

/// Key-by-key comparison that never reveals a value (bodies carry the installation secret).
private func bodyMismatches(_ recorded: FakePriceAlertsTransport.Recorded?, _ expected: [String: Any]) -> [String] {
    guard let recorded else { return ["no request was recorded"] }
    var problems: [String] = []
    for key in Set(recorded.json.keys).union(expected.keys).sorted() {
        guard let actualValue = recorded.json[key] else { problems.append("missing key \(key)"); continue }
        guard let expectedValue = expected[key] else { problems.append("unexpected key \(key)"); continue }
        if jsonValueEqual(actualValue, expectedValue) == false { problems.append("value differs for key \(key)") }
    }
    return problems
}

private let credential = PriceAlertsInstallationCredential(
    installationID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
    installationSecret: String(repeating: "k", count: 48)
)
private let wireID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

private let station = PriceAlertsStack.stationID(7)
private let wireStation = "11223344-5566-4a77-8899-aabbccddee07"

private func envelope(_ action: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    var body: [String: Any] = [
        "action": action,
        "client_installation_id": wireID,
        "installation_secret": credential.installationSecret,
    ]
    for (key, value) in extra { body[key] = value }
    return body
}

private func parseISO(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)!
}

private func amount(_ thousandths: Int) -> PriceAlertAmount {
    PriceAlertAmount(thousandths: thousandths)
}

// MARK: - Requests

struct PriceAlertsRequestContractTests {
    private let transport = FakePriceAlertsTransport()
    private var client: PriceAlertsAPIClient { PriceAlertsAPIClient(transport: transport) }

    // MARK: bootstrap

    @Test("bootstrap sends exactly: action, credential, platform, app_version and the RevenueCat pair")
    func bootstrap_exactBody() async throws {
        transport.enqueue("bootstrap", .ok(BackendFixtures.bootstrap(installationID: wireID)))
        let identity = PriceAlertsRevenueCatIdentity(appUserID: "$RCAnonymousID:abc123", environment: .sandbox)

        let result = try await client.bootstrap(credential: credential, revenueCat: identity, appVersion: "2.4.1 (100)")

        #expect(result == PriceAlertsBootstrapResult(proIsActive: true, revenueCatLinked: true))
        #expect(transport.actions == ["bootstrap"])
        #expect(bodyMismatches(transport.lastRequest("bootstrap"), envelope("bootstrap", [
            "platform": "ios",
            "app_version": "2.4.1 (100)",
            "revenuecat_app_user_id": "$RCAnonymousID:abc123",
            "revenuecat_environment": "SANDBOX",
        ])).isEmpty)
    }

    @Test("Without a RevenueCat identity the pair is omitted together — never one half")
    func bootstrap_withoutIdentity_omitsBothHalves() async throws {
        transport.enqueue("bootstrap", .ok(BackendFixtures.bootstrap(installationID: wireID, pro: false, linked: false)))

        let result = try await client.bootstrap(credential: credential, revenueCat: nil, appVersion: nil)

        #expect(result == PriceAlertsBootstrapResult(proIsActive: false, revenueCatLinked: false))
        let recorded = try #require(transport.lastRequest("bootstrap"))
        #expect(recorded.json["revenuecat_app_user_id"] == nil)
        #expect(recorded.json["revenuecat_environment"] == nil)
        #expect(recorded.json["app_version"] == nil)
        #expect(recorded.json["platform"] as? String == "ios")
    }

    @Test("Production RevenueCat environment goes on the wire as PRODUCTION")
    func bootstrap_productionEnvironment() async throws {
        transport.enqueue("bootstrap", .ok(BackendFixtures.bootstrap(installationID: wireID)))
        let identity = PriceAlertsRevenueCatIdentity(appUserID: "user-1", environment: .production)

        _ = try await client.bootstrap(credential: credential, revenueCat: identity, appVersion: nil)

        #expect(transport.lastRequest("bootstrap")?.json["revenuecat_environment"] as? String == "PRODUCTION")
    }

    @Test("Optional bootstrap fields the backend would reject are dropped, so they cannot fail the bootstrap")
    func bootstrap_dropsFieldsTheBackendWouldReject() async throws {
        transport.enqueue("bootstrap", .ok(BackendFixtures.bootstrap(installationID: wireID)))
        let tooLong = PriceAlertsRevenueCatIdentity(appUserID: String(repeating: "u", count: 513), environment: .sandbox)

        _ = try await client.bootstrap(credential: credential, revenueCat: tooLong, appVersion: String(repeating: "9", count: 65))

        let recorded = try #require(transport.lastRequest("bootstrap"))
        #expect(recorded.json["revenuecat_app_user_id"] == nil)
        #expect(recorded.json["revenuecat_environment"] == nil)
        #expect(recorded.json["app_version"] == nil)
        #expect(PriceAlertsWireRequest.sanitizedAppVersion("  2.4.1 ") == "2.4.1")
        #expect(PriceAlertsWireRequest.sanitizedAppVersion("   ") == nil)
        #expect(PriceAlertsWireRequest.sanitizedAppVersion(String(repeating: "9", count: 64)) != nil)
        #expect(PriceAlertsRevenueCatIdentity(appUserID: "", environment: .sandbox).isAcceptableToBackend == false)
        #expect(PriceAlertsRevenueCatIdentity(appUserID: " padded", environment: .sandbox).isAcceptableToBackend == false)
    }

    // MARK: devices

    @Test("register_device sends the token as lowercase hex with bundle id and APNs environment, and nothing Android")
    func registerDevice_exactBody() async throws {
        transport.enqueue("register_device", .ok(BackendFixtures.registered()))
        let token = try #require(PushDeviceToken(deviceToken: Data([0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0x0A, 0x0B])))
        let metadata = try #require(PushDeviceRegistrationMetadata(bundleIdentifier: "com.e85blends.app.ios.internal", apnsEnvironment: .production))

        _ = try await client.registerDevice(credential: credential, token: token, metadata: metadata)

        #expect(bodyMismatches(transport.lastRequest("register_device"), envelope("register_device", [
            "platform": "ios",
            "bundle_id": "com.e85blends.app.ios.internal",
            "apns_environment": "production",
            "device_token": "abcdef01234567890a0b",
        ])).isEmpty)
    }

    @Test("register_device returns the server's device id")
    func registerDevice_returnsDeviceID() async throws {
        let deviceID = UUID()
        transport.enqueue("register_device", .ok(BackendFixtures.registered(deviceID: deviceID)))
        let token = FakePushState.token(1)
        let metadata = try #require(PushDeviceRegistrationMetadata(bundleIdentifier: "com.example.app", apnsEnvironment: .sandbox))

        let returned = try await client.registerDevice(credential: credential, token: token, metadata: metadata)

        #expect(returned == deviceID)
    }

    @Test("unregister_device sends only the token")
    func unregisterDevice_exactBody() async throws {
        transport.enqueue("unregister_device", .ok(BackendFixtures.unregistered(changed: false)))
        let token = FakePushState.token(2)

        let changed = try await client.unregisterDevice(credential: credential, token: token)

        #expect(changed == false)
        #expect(bodyMismatches(transport.lastRequest("unregister_device"), envelope("unregister_device", [
            "device_token": token.hexString,
        ])).isEmpty)
    }

    // MARK: alerts

    @Test("Create (price_drop) sends the full state, lower-case station id, no threshold and no `enabled`")
    func setAlert_priceDrop_exactBody() async throws {
        transport.enqueue("set_alert", .ok(BackendFixtures.saved(BackendFixtures.alertObject(stationID: station))))
        let draft = try PriceAlertDraft(communityStationID: station, rule: .priceDrop)

        _ = try await client.saveAlert(credential: credential, draft: draft)

        #expect(bodyMismatches(transport.lastRequest("set_alert"), envelope("set_alert", [
            "station_id": wireStation,
            "alert_mode": "price_drop",
            "minimum_change": 0.05,
            "cooldown_minutes": 360,
        ])).isEmpty)
        let text = try #require(transport.lastRequest("set_alert")).bodyText
        // Numbers are JSON numbers, formatted without binary noise.
        #expect(text.contains("\"minimum_change\":0.05"))
        #expect(text.contains("\"cooldown_minutes\":360"))
        #expect(text.contains("\"enabled\"") == false)
        #expect(text.contains("threshold_price") == false)
    }

    @Test("Create (at_or_below) sends the threshold as a JSON number, exactly")
    func setAlert_atOrBelow_exactBody() async throws {
        transport.enqueue("set_alert", .ok(BackendFixtures.saved(BackendFixtures.alertObject(stationID: station, mode: "at_or_below", threshold: "3.499"))))
        let draft = try PriceAlertDraft(communityStationID: station, rule: .atOrBelow(amount(3_499)))

        _ = try await client.saveAlert(credential: credential, draft: draft)

        #expect(bodyMismatches(transport.lastRequest("set_alert"), envelope("set_alert", [
            "station_id": wireStation,
            "alert_mode": "at_or_below",
            "threshold_price": 3.499,
            "minimum_change": 0.05,
            "cooldown_minutes": 360,
        ])).isEmpty)
        let text = try #require(transport.lastRequest("set_alert")).bodyText
        #expect(text.contains("\"threshold_price\":3.499"))
        #expect(text.contains("\"threshold_price\":\"") == false)
    }

    @Test("Update sends the FULL replacement state — set_alert resets anything omitted to a default")
    func setAlert_update_sendsFullState() async throws {
        transport.enqueue("set_alert", .ok(BackendFixtures.saved(BackendFixtures.alertObject(stationID: station, mode: "at_or_below", threshold: "3.000", minimumChange: "0.100", cooldownMinutes: 720))))
        let draft = try PriceAlertDraft(
            communityStationID: station,
            rule: .atOrBelow(amount(3_000)),
            preferences: PriceAlertPreferences(minimumChange: amount(100), cooldownMinutes: 720)
        )

        _ = try await client.saveAlert(credential: credential, draft: draft)

        #expect(bodyMismatches(transport.lastRequest("set_alert"), envelope("set_alert", [
            "station_id": wireStation,
            "alert_mode": "at_or_below",
            "threshold_price": 3.0,
            "minimum_change": 0.1,
            "cooldown_minutes": 720,
        ])).isEmpty)
    }

    @Test("No rule ever puts `enabled` on the wire — the backend has no such input")
    func setAlert_neverSendsEnabled() async throws {
        let rules: [PriceAlertRule] = [.anyChange, .priceDrop, .atOrBelow(amount(3_250))]
        for rule in rules {
            transport.enqueue("set_alert", .ok(BackendFixtures.saved(BackendFixtures.alertObject(stationID: station))))
            let draft = try PriceAlertDraft(communityStationID: station, rule: rule)
            _ = try await client.saveAlert(credential: credential, draft: draft)
        }
        #expect(transport.requests.count == 3)
        for request in transport.requests {
            #expect(request.json["enabled"] == nil, "rule request carried `enabled`")
            #expect(request.json["alert_mode"] is String)
        }
        #expect(transport.requests.map { $0.json["alert_mode"] as? String } == ["any_change", "price_drop", "at_or_below"])
    }

    @Test("Saving always reports the alert as enabled, as the backend writes enabled = true on every save")
    func setAlert_responseIsEnabled() async throws {
        transport.enqueue("set_alert", .ok(BackendFixtures.saved(BackendFixtures.alertObject(stationID: station, enabled: true))))
        let draft = try PriceAlertDraft(communityStationID: station, rule: .priceDrop)

        let saved = try await client.saveAlert(credential: credential, draft: draft)

        #expect(saved.isEnabled)
        #expect(saved.stationID == station)
        #expect(saved.rule == .priceDrop)
        #expect(saved.preferences == .defaults)
    }

    @Test("delete_alert sends only the station id and reports whether a row changed")
    func deleteAlert_exactBody() async throws {
        transport.enqueue("delete_alert", .ok(BackendFixtures.deleted(changed: true)), .ok(BackendFixtures.deleted(changed: false)))

        let first = try await client.deleteAlert(credential: credential, stationID: station)
        let second = try await client.deleteAlert(credential: credential, stationID: station)

        #expect(first == true)
        #expect(second == false)
        #expect(bodyMismatches(transport.lastRequest("delete_alert"), envelope("delete_alert", [
            "station_id": wireStation,
        ])).isEmpty)
    }

    @Test("list_alerts and status send nothing beyond the credential")
    func listAndStatus_exactBodies() async throws {
        transport.enqueue("list_alerts", .ok(BackendFixtures.list([])))
        transport.enqueue("status", .ok(BackendFixtures.status(pro: false, linked: true, devices: 2, alerts: 3)))

        let alerts = try await client.listAlerts(credential: credential)
        let status = try await client.status(credential: credential)

        #expect(alerts.isEmpty)
        #expect(status == PriceAlertsServerStatus(proIsActive: false, revenueCatLinked: true, activeDevices: 2, enabledAlerts: 3))
        #expect(bodyMismatches(transport.lastRequest("list_alerts"), envelope("list_alerts")).isEmpty)
        #expect(bodyMismatches(transport.lastRequest("status"), envelope("status")).isEmpty)
    }

    @Test("Request bodies are byte-for-byte deterministic (sorted keys)")
    func bodies_areDeterministic() throws {
        let draft = try PriceAlertDraft(communityStationID: station, rule: .atOrBelow(amount(3_250)))
        let request = PriceAlertsWireRequest.setAlert(credential: credential, draft: draft)
        let first = try PriceAlertsAPIClient.encoder().encode(request)
        let second = try PriceAlertsAPIClient.encoder().encode(request)
        #expect(first == second)
        let text = String(decoding: first, as: UTF8.self)
        let keys = ["action", "alert_mode", "client_installation_id", "cooldown_minutes", "installation_secret", "minimum_change", "station_id", "threshold_price"]
        let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions.count == keys.count)
        #expect(positions == positions.sorted())
    }
}

// MARK: - Responses

struct PriceAlertsResponseContractTests {
    private let transport = FakePriceAlertsTransport()
    private var client: PriceAlertsAPIClient { PriceAlertsAPIClient(transport: transport) }

    @Test("list_alerts decodes the backend's rows: numeric strings, millisecond timestamps, nulls and the joined station")
    func list_decodesBackendRows() async throws {
        let first = BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(1), mode: "at_or_below", threshold: "3.250", minimumChange: "0.050", cooldownMinutes: 360)
        let second = BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(2), mode: "price_drop", minimumChange: "0.100", cooldownMinutes: 720)
        transport.enqueue("list_alerts", .ok(BackendFixtures.list([
            BackendFixtures.listRow(
                alert: first,
                stationName: "Alpha Fuel",
                lastNotifiedPrice: "3.199",
                lastNotifiedAt: "2026-10-05T12:34:56.789Z",
                latestPrice: "3.149",
                latestReportedAt: "2026-10-06T08:00:00.000Z"
            ),
            BackendFixtures.listRow(
                alert: second,
                stationName: "Beta Pump",
                address: nil, city: nil, state: nil,
                latestPrice: nil, latestReportedAt: nil
            ),
        ])))

        let listings = try await client.listAlerts(credential: credential)

        #expect(listings.count == 2)
        let alpha = listings[0]
        #expect(alpha.alert.stationID == PriceAlertsStack.stationID(1))
        #expect(alpha.alert.rule == .atOrBelow(amount(3_250)))
        #expect(alpha.alert.preferences == PriceAlertPreferences(minimumChange: amount(50), cooldownMinutes: 360))
        #expect(alpha.alert.isEnabled)
        #expect(alpha.station == PriceAlertStation(name: "Alpha Fuel", address: "1 Main St", city: "Omaha", state: "NE"))
        #expect(alpha.lastNotifiedPrice == amount(3_199))
        #expect(alpha.latestPrice == amount(3_149))
        let notified = try #require(alpha.lastNotifiedAt)
        #expect(abs(notified.timeIntervalSince(parseISO("2026-10-05T12:34:56.789Z"))) < 0.001)
        #expect(alpha.latestReportedAt != nil)

        let beta = listings[1]
        #expect(beta.alert.rule == .priceDrop)
        #expect(beta.alert.preferences == PriceAlertPreferences(minimumChange: amount(100), cooldownMinutes: 720))
        #expect(beta.station == PriceAlertStation(name: "Beta Pump", address: nil, city: nil, state: nil))
        #expect(beta.latestPrice == nil)
        #expect(beta.latestReportedAt == nil)
        #expect(beta.lastNotifiedPrice == nil)
        #expect(beta.lastNotifiedAt == nil)
    }

    @Test("Prices may arrive as JSON numbers and timestamps without fractional seconds — both are accepted")
    func list_isTolerantOfEitherEncoding() async throws {
        var alert = BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(3), mode: "at_or_below")
        alert["threshold_price"] = 3.25
        alert["minimum_change"] = 0.05
        var row = BackendFixtures.listRow(alert: alert, latestReportedAt: "2026-10-06T08:00:00Z")
        row["latest_price"] = 3.149
        transport.enqueue("list_alerts", .ok(BackendFixtures.list([row])))

        let listings = try await client.listAlerts(credential: credential)

        #expect(listings.first?.alert.rule == .atOrBelow(amount(3_250)))
        #expect(listings.first?.alert.minimumChange == amount(50))
        #expect(listings.first?.latestPrice == amount(3_149))
        #expect(listings.first?.latestReportedAt == parseISO("2026-10-06T08:00:00.000Z"))
    }

    @Test("An alert mode this build has never heard of decodes, instead of making the whole list undecodable")
    func list_keepsUnknownModes() async throws {
        let future = BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(4), mode: "percent_drop")
        let known = BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(5), mode: "any_change")
        transport.enqueue("list_alerts", .ok(BackendFixtures.list([BackendFixtures.listRow(alert: future), BackendFixtures.listRow(alert: known)])))

        let listings = try await client.listAlerts(credential: credential)

        #expect(listings.count == 2)
        #expect(listings[0].alert.mode == .unknown("percent_drop"))
        #expect(listings[0].alert.rule == nil)
        #expect(listings[1].alert.rule == .anyChange)
        #expect(listings[1].alert.rule?.isOfferedInMVP == false)
    }

    @Test("A row missing its station id is a decoding error, never a crash and never a half-built alert")
    func list_malformedRowFailsCleanly() async {
        var broken = BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(6))
        broken.removeValue(forKey: "station_id")
        transport.enqueue("list_alerts", .ok(BackendFixtures.list([BackendFixtures.listRow(alert: broken)])))

        await #expect(throws: PriceAlertsAPIError.decoding) {
            try await client.listAlerts(credential: credential)
        }
    }

    @Test("A 200 that is not JSON (a gateway page) is a decoding error")
    func success_withGarbageBody_isDecodingError() async {
        transport.enqueue("status", .ok(Data("<html>Bad gateway</html>".utf8)))
        await #expect(throws: PriceAlertsAPIError.decoding) {
            try await client.status(credential: credential)
        }
    }

    @Test("A bootstrap reply about a different installation is refused")
    func bootstrap_replyForAnotherInstallation_isRefused() async {
        transport.enqueue("bootstrap", .ok(BackendFixtures.bootstrap(installationID: "00000000-0000-4000-8000-000000000000")))
        await #expect(throws: PriceAlertsAPIError.invalidResponse(statusCode: 200)) {
            try await client.bootstrap(credential: credential, revenueCat: nil, appVersion: nil)
        }
    }

    @Test("A reply with the wrong status word, or about another station, is refused")
    func replies_withUnexpectedShape_areRefused() async throws {
        transport.enqueue("bootstrap", .ok(BackendFixtures.data(["status": "pending", "client_installation_id": wireID, "platform": "ios", "pro_is_active": true, "revenuecat_linked": true])))
        await #expect(throws: PriceAlertsAPIError.invalidResponse(statusCode: 200)) {
            try await client.bootstrap(credential: credential, revenueCat: nil, appVersion: nil)
        }

        transport.enqueue("set_alert", .ok(BackendFixtures.saved(BackendFixtures.alertObject(stationID: PriceAlertsStack.stationID(9)))))
        let draft = try PriceAlertDraft(communityStationID: station, rule: .priceDrop)
        await #expect(throws: PriceAlertsAPIError.invalidResponse(statusCode: 200)) {
            try await client.saveAlert(credential: credential, draft: draft)
        }

        transport.enqueue("delete_alert", .ok(BackendFixtures.data(["status": "saved", "changed": true])))
        await #expect(throws: PriceAlertsAPIError.invalidResponse(statusCode: 200)) {
            try await client.deleteAlert(credential: credential, stationID: station)
        }
    }

    @Test("A transport failure that produced no response is passed through unchanged")
    func transportFailure_propagates() async {
        transport.enqueue("status", .failure(PriceAlertsAPIError.network(.offline)))
        await #expect(throws: PriceAlertsAPIError.network(.offline)) {
            try await client.status(credential: credential)
        }
    }
}

// MARK: - Errors

struct PriceAlertsErrorContractTests {
    private let transport = FakePriceAlertsTransport()
    private var client: PriceAlertsAPIClient { PriceAlertsAPIClient(transport: transport) }

    /// Every error the backend source can emit (docs §1.5), with the status it uses.
    private static let backendErrors: [(wire: String, status: Int, code: PriceAlertsAPIErrorCode)] = [
        ("unauthorized", 401, .unauthorized),
        ("invalid_installation_credentials", 401, .invalidInstallationCredentials),
        ("invalid_installation_credentials", 400, .invalidInstallationCredentials),
        ("pro_required", 403, .proRequired),
        ("station_not_found", 404, .stationNotFound),
        ("invalid_alert", 400, .invalidAlert),
        ("invalid_threshold_price", 400, .invalidThresholdPrice),
        ("threshold_only_valid_for_at_or_below", 400, .thresholdOnlyValidForAtOrBelow),
        ("invalid_alert_preferences", 400, .invalidAlertPreferences),
        ("invalid_station_id", 400, .invalidStationID),
        ("invalid_device_registration", 400, .invalidDeviceRegistration),
        ("invalid_device_token", 400, .invalidDeviceToken),
        ("invalid_platform", 400, .invalidPlatform),
        ("invalid_contributor_id", 400, .invalidContributorID),
        ("invalid_app_version", 400, .invalidAppVersion),
        ("revenuecat_identity_requires_environment", 400, .revenueCatIdentityRequiresEnvironment),
        ("invalid_revenuecat_identity", 400, .invalidRevenueCatIdentity),
        ("invalid_json", 400, .invalidJSON),
        ("invalid_json_object", 400, .invalidJSONObject),
        ("action_required", 400, .actionRequired),
        ("unknown_action", 400, .unknownAction),
        ("method_not_allowed", 405, .methodNotAllowed),
        ("server_not_configured", 503, .serverNotConfigured),
        ("internal_error", 500, .internalError),
    ]

    @Test("Every backend error body decodes to its typed code, with the status preserved")
    func backendErrors_decodeToTypedCodes() async {
        for entry in Self.backendErrors {
            transport.enqueue("status", .error(status: entry.status, code: entry.wire))
            do {
                _ = try await client.status(credential: credential)
                Issue.record("\(entry.wire) did not throw")
            } catch let error as PriceAlertsAPIError {
                #expect(error == .api(code: entry.code, statusCode: entry.status), "wire code \(entry.wire)")
            } catch {
                Issue.record("\(entry.wire) threw a non-API error")
            }
        }
    }

    @Test("A code from a newer backend is preserved as unknown, truncated, and never crashes")
    func unknownCode_isPreserved() async {
        transport.enqueue("status", .error(status: 400, code: "brand_new_error"))
        transport.enqueue("status", .error(status: 400, code: String(repeating: "x", count: 500)))

        for expectedLength in [15, 64] {
            do {
                _ = try await client.status(credential: credential)
                Issue.record("did not throw")
            } catch let error as PriceAlertsAPIError {
                guard case .api(.unknown(let text), 400) = error else {
                    Issue.record("not an unknown API code")
                    continue
                }
                #expect(text.count == expectedLength)
            } catch {
                Issue.record("unexpected error type")
            }
        }
    }

    @Test("A non-JSON error body (a gateway page, an empty body) becomes invalidResponse carrying only the status")
    func nonJSONErrorBody_isInvalidResponse() async {
        let bodies: [(Int, Data)] = [(502, Data("<html>Bad Gateway</html>".utf8)), (500, Data()), (404, BackendFixtures.data(["message": "Function not found"]))]
        for (status, body) in bodies {
            transport.enqueue("status", .response(status: status, body: body))
            await #expect(throws: PriceAlertsAPIError.invalidResponse(statusCode: status)) {
                try await client.status(credential: credential)
            }
        }
    }

    @Test("A redirect is not a success and not an API error: it surfaces as invalidResponse")
    func redirect_isInvalidResponse() async {
        transport.enqueue("status", .response(status: 307, body: Data()))
        await #expect(throws: PriceAlertsAPIError.invalidResponse(statusCode: 307)) {
            try await client.status(credential: credential)
        }
    }

    @Test("401 unauthorized (a rejected API key) is NOT an installation rejection — recreating the installation cannot cure it")
    func unauthorizedIsDistinctFromInstallationRejection() {
        let apiKeyRejected = PriceAlertsAPIError.api(code: .unauthorized, statusCode: 401)
        let installationRejected = PriceAlertsAPIError.api(code: .invalidInstallationCredentials, statusCode: 401)
        let malformedCredentials = PriceAlertsAPIError.api(code: .invalidInstallationCredentials, statusCode: 400)

        #expect(apiKeyRejected.rejectsInstallationCredentials == false)
        #expect(installationRejected.rejectsInstallationCredentials)
        // 400 means OUR credential is malformed — a client bug, not a server verdict to recover from.
        #expect(malformedCredentials.rejectsInstallationCredentials == false)
    }

    @Test("403 pro_required is recognized")
    func proRequiredIsRecognized() {
        #expect(PriceAlertsAPIError.api(code: .proRequired, statusCode: 403).isProRequired)
        #expect(PriceAlertsAPIError.api(code: .unauthorized, statusCode: 401).isProRequired == false)
    }

    @Test("Transient failures (network, 5xx, 429, 408) are retryable; client errors and decoding failures are not")
    func transientClassification() {
        let transient: [PriceAlertsAPIError] = [
            .network(.offline), .network(.timedOut), .network(.other), .network(.secureConnectionFailed),
            .api(code: .internalError, statusCode: 500), .api(code: .serverNotConfigured, statusCode: 503),
            .api(code: .unknown("slow_down"), statusCode: 429), .invalidResponse(statusCode: 502),
            .invalidResponse(statusCode: 408), .invalidResponse(statusCode: nil),
        ]
        let permanent: [PriceAlertsAPIError] = [
            .network(.cancelled), .notConfigured, .decoding,
            .api(code: .invalidAlert, statusCode: 400), .api(code: .unauthorized, statusCode: 401),
            .api(code: .proRequired, statusCode: 403), .api(code: .stationNotFound, statusCode: 404),
            .invalidResponse(statusCode: 307), .invalidResponse(statusCode: 404),
        ]
        for error in transient { #expect(error.isTransient, "\(error) should be transient") }
        for error in permanent { #expect(error.isTransient == false, "\(error) should not be transient") }
    }

    @Test("Service errors map the API's verdicts to the cases a UI switches over")
    func serviceErrorMapping() {
        #expect(PriceAlertsServiceError.from(PriceAlertsAPIError.notConfigured) == .notConfigured)
        #expect(PriceAlertsServiceError.from(PriceAlertsAPIError.api(code: .stationNotFound, statusCode: 404)) == .stationNotFound)
        #expect(PriceAlertsServiceError.from(PriceAlertsAPIError.api(code: .proRequired, statusCode: 403)) == .proRequiredByServer)
        #expect(PriceAlertsServiceError.from(PriceAlertsAPIError.network(.offline)) == .api(.network(.offline)))
        #expect(PriceAlertsServiceError.from(PriceAlertsServiceError.proRequired) == .proRequired)
        #expect(PriceAlertsServiceError.from(CancellationError()) == .api(.network(.cancelled)))
        #expect(PriceAlertsServiceError.from(URLError(.badURL)) == .api(.network(.other)))

        #expect(PriceAlertsServiceError.api(.network(.offline)).isRetryable)
        #expect(PriceAlertsServiceError.entitlementUnresolved.isRetryable)
        #expect(PriceAlertsServiceError.credentialStorageUnavailable.isRetryable)
        #expect(PriceAlertsServiceError.proRequired.isRetryable == false)
        #expect(PriceAlertsServiceError.stationNotEligibleForPriceAlerts.isRetryable == false)
    }

    @Test("URLError codes reduce to coarse categories; the system error text is never kept")
    func networkFailureCategories() {
        #expect(PriceAlertsNetworkFailure(URLError(.notConnectedToInternet)) == .offline)
        #expect(PriceAlertsNetworkFailure(URLError(.networkConnectionLost)) == .offline)
        #expect(PriceAlertsNetworkFailure(URLError(.timedOut)) == .timedOut)
        #expect(PriceAlertsNetworkFailure(URLError(.cancelled)) == .cancelled)
        #expect(PriceAlertsNetworkFailure(URLError(.secureConnectionFailed)) == .secureConnectionFailed)
        #expect(PriceAlertsNetworkFailure(URLError(.serverCertificateUntrusted)) == .secureConnectionFailed)
        #expect(PriceAlertsNetworkFailure(URLError(.cannotFindHost)) == .other)
        #expect(PriceAlertsNetworkFailure(CancellationError()) == .cancelled)
        #expect(PriceAlertsNetworkFailure(NSError(domain: "x", code: 1)) == .other)
    }
}

// MARK: - Money, rules and drafts

struct PriceAlertsModelTests {
    @Test("Amounts parse the text Postgres renders, rounding a fourth digit half up")
    func amount_parsing() {
        let accepted: [(String, Int)] = [
            ("3.250", 3_250), ("3.5", 3_500), ("4", 4_000), ("0.050", 50), ("0", 0), ("8.000", 8_000),
            ("3.2495", 3_250), ("3.2494", 3_249), ("3.24949", 3_249), ("3.24999", 3_250), ("3.", 3_000), (".5", 500),
            ("1000.000", 1_000_000),
        ]
        for (text, thousandths) in accepted {
            #expect(PriceAlertAmount(wireString: text)?.thousandths == thousandths, "\(text)")
        }
        let rejected = ["", "-1", "+1", "1e3", "abc", "1.2.3", " 1", "1 ", "١٢٣", ".", "1,5", "9999999999"]
        for text in rejected {
            #expect(PriceAlertAmount(wireString: text) == nil, "\(text.debugDescription) should be rejected")
        }
    }

    @Test("Amounts from dollars round to the nearest thousandth and refuse nonsense")
    func amount_fromDollars() {
        #expect(PriceAlertAmount(dollars: 3.499)?.thousandths == 3_499)
        #expect(PriceAlertAmount(dollars: 3.4995)?.thousandths == 3_500)
        #expect(PriceAlertAmount(dollars: 0.05)?.thousandths == 50)
        #expect(PriceAlertAmount(dollars: 0)?.thousandths == 0)
        #expect(PriceAlertAmount(dollars: -0.001) == nil)
        #expect(PriceAlertAmount(dollars: .nan) == nil)
        #expect(PriceAlertAmount(dollars: .infinity) == nil)
        #expect(PriceAlertAmount(dollars: 1e12) == nil)
    }

    @Test("Every price the backend can hold survives encode → JSON number → decode, with no binary drift")
    func amount_roundTripsEveryBackendThousandth() throws {
        for thousandths in 1_000...8_000 {
            let value = amount(thousandths)
            let json = try JSONEncoder().encode([value])
            let text = String(decoding: json, as: UTF8.self)
            // The JSON number must be the plain decimal, e.g. 3.499 — not 3.4990000000000001. A whole
            // number of dollars is written without a fraction ("3", a valid JSON number).
            let expected = Double(thousandths) / 1000
            let plain = thousandths % 1_000 == 0 ? "\(thousandths / 1_000)" : "\(expected)"
            #expect(text == "[\(plain)]", "\(thousandths)")
            let decoded = try JSONDecoder().decode([PriceAlertAmount].self, from: json)
            #expect(decoded == [value], "\(thousandths)")
            #expect(PriceAlertAmount(wireString: String(format: "%.3f", expected)) == value, "\(thousandths)")
        }
    }

    @Test("An amount decodes from a numeric string or a number, and rejects anything else")
    func amount_decoding() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(PriceAlertAmount.self, from: Data("\"3.250\"".utf8)) == amount(3_250))
        #expect(try decoder.decode(PriceAlertAmount.self, from: Data("3.25".utf8)) == amount(3_250))
        #expect(try decoder.decode(PriceAlertAmount.self, from: Data("4".utf8)) == amount(4_000))
        for bad in ["\"abc\"", "-1", "\"-1\"", "null", "true", "[]", "{}"] {
            #expect(throws: (any Error).self, "\(bad)") {
                try decoder.decode(PriceAlertAmount.self, from: Data(bad.utf8))
            }
        }
    }

    @Test("Rules map to the backend's mode identifiers, and the MVP offers Price Drop and At or Below")
    func rules_modesAndMVP() {
        #expect(PriceAlertRule.anyChange.mode.wireValue == "any_change")
        #expect(PriceAlertRule.priceDrop.mode.wireValue == "price_drop")
        #expect(PriceAlertRule.atOrBelow(amount(3_000)).mode.wireValue == "at_or_below")
        #expect(PriceAlertRule.atOrBelow(amount(3_000)).thresholdPrice == amount(3_000))
        #expect(PriceAlertRule.priceDrop.thresholdPrice == nil)

        #expect(PriceAlertRule.priceDrop.isOfferedInMVP)
        #expect(PriceAlertRule.atOrBelow(amount(3_000)).isOfferedInMVP)
        #expect(PriceAlertRule.anyChange.isOfferedInMVP == false)

        #expect(PriceAlertMode(wireValue: "any_change") == .anyChange)
        #expect(PriceAlertMode(wireValue: "mystery") == .unknown("mystery"))
        #expect(PriceAlertMode.unknown("mystery").wireValue == "mystery")
    }

    @Test("A rule can only be rebuilt from a consistent mode + threshold pair")
    func rules_rebuildFromResponse() {
        #expect(PriceAlertRule(mode: .priceDrop, thresholdPrice: nil) == .priceDrop)
        #expect(PriceAlertRule(mode: .anyChange, thresholdPrice: nil) == .anyChange)
        #expect(PriceAlertRule(mode: .atOrBelow, thresholdPrice: amount(3_000)) == .atOrBelow(amount(3_000)))
        #expect(PriceAlertRule(mode: .atOrBelow, thresholdPrice: nil) == nil)
        #expect(PriceAlertRule(mode: .priceDrop, thresholdPrice: amount(3_000)) == nil)
        #expect(PriceAlertRule(mode: .unknown("x"), thresholdPrice: nil) == nil)
    }

    @Test("Defaults and ranges are the backend's: 0.05 / 360 minutes; threshold 1–8; change 0.01–2; cooldown 60–10080")
    func backendRanges() {
        #expect(PriceAlertPreferences.defaults.minimumChange == amount(50))
        #expect(PriceAlertPreferences.defaults.cooldownMinutes == 360)
        #expect(PriceAlertRule.thresholdRange == amount(1_000)...amount(8_000))
        #expect(PriceAlertPreferences.minimumChangeRange == amount(10)...amount(2_000))
        #expect(PriceAlertPreferences.cooldownMinutesRange == 60...10_080)
    }

    @Test("A draft refuses what the backend would reject — at the exact boundaries")
    func draft_validation() throws {
        func make(_ rule: PriceAlertRule, change: Int = 50, cooldown: Int = 360) throws -> PriceAlertDraft {
            try PriceAlertDraft(communityStationID: station, rule: rule, preferences: PriceAlertPreferences(minimumChange: amount(change), cooldownMinutes: cooldown))
        }
        func failure(_ build: () throws -> PriceAlertDraft) -> PriceAlertValidationFailure? {
            do { _ = try build(); return nil } catch PriceAlertsServiceError.invalidAlert(let failure) { return failure } catch { return nil }
        }

        _ = try make(.atOrBelow(amount(1_000)))
        _ = try make(.atOrBelow(amount(8_000)))
        #expect(failure { try make(.atOrBelow(amount(999))) } == .thresholdOutOfRange)
        #expect(failure { try make(.atOrBelow(amount(8_001))) } == .thresholdOutOfRange)

        _ = try make(.priceDrop, change: 10)
        _ = try make(.priceDrop, change: 2_000)
        #expect(failure { try make(.priceDrop, change: 9) } == .minimumChangeOutOfRange)
        #expect(failure { try make(.priceDrop, change: 2_001) } == .minimumChangeOutOfRange)

        _ = try make(.priceDrop, cooldown: 60)
        _ = try make(.priceDrop, cooldown: 10_080)
        #expect(failure { try make(.priceDrop, cooldown: 59) } == .cooldownOutOfRange)
        #expect(failure { try make(.priceDrop, cooldown: 10_081) } == .cooldownOutOfRange)
    }
}

// MARK: - Transport request

struct PriceAlertsTransportTests {
    private func config(_ url: String, anon: String = "anon-key", publishable: String? = "sb_publishable_key") -> SupabaseConfig {
        SupabaseConfig(url: URL(string: url)!, anonKey: anon, publishableKey: publishable)
    }

    @Test("The endpoint is the project's functions/v1/price-alerts-api, whether SUPABASE_URL is the project root or its PostgREST path")
    func endpoint_urlBuilding() {
        let expected = "https://abc.supabase.co/functions/v1/price-alerts-api"
        for configured in ["https://abc.supabase.co", "https://abc.supabase.co/", "https://abc.supabase.co/rest/v1", "https://abc.supabase.co/rest/v1/"] {
            #expect(PriceAlertsEndpoint.url(from: URL(string: configured)!).absoluteString == expected, "\(configured)")
        }
    }

    @Test("The client-safe key is the publishable key, falling back to the legacy anon key")
    func endpoint_keyChoice() {
        #expect(PriceAlertsEndpoint.clientAPIKey(from: config("https://abc.supabase.co")) == "sb_publishable_key")
        #expect(PriceAlertsEndpoint.clientAPIKey(from: config("https://abc.supabase.co", publishable: nil)) == "anon-key")
    }

    @Test("The request is a JSON POST to the configured host carrying the client-safe key — and no Authorization header")
    func makeRequest_shape() throws {
        let endpoint = PriceAlertsEndpoint.url(from: URL(string: "https://abc.supabase.co/rest/v1/")!)
        let secretBody = Data("{\"installation_secret\":\"top-secret-value\"}".utf8)

        let request = URLSessionPriceAlertsTransport.makeRequest(endpoint: endpoint, apiKey: "sb_publishable_key", body: secretBody)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.host == "abc.supabase.co")
        #expect(request.url?.scheme == "https")
        #expect(request.url?.path == "/functions/v1/price-alerts-api")
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == secretBody)
        #expect(request.timeoutInterval == 15)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.httpShouldHandleCookies == false)
        // The secret travels in the body only (the backend's design) — never in a header or the URL.
        let headerValues = (request.allHTTPHeaderFields ?? [:]).values.joined()
        #expect(headerValues.contains("top-secret-value") == false)
        #expect(request.url?.absoluteString.contains("top-secret-value") == false)
    }

    @Test("Without a usable HTTPS configuration the transport sends nothing and reports notConfigured")
    func unconfigured_throwsNotConfigured() async {
        let unusable: [SupabaseConfig?] = [
            nil,
            config("http://abc.supabase.co"),
            config("https://abc.supabase.co", anon: "", publishable: nil),
            config("https://abc.supabase.co", anon: "  ", publishable: "  "),
        ]
        for candidate in unusable {
            let transport = URLSessionPriceAlertsTransport(config: candidate)
            #expect(transport.isConfigured == false)
            await #expect(throws: PriceAlertsAPIError.notConfigured) {
                try await transport.post(Data("{}".utf8))
            }
        }
        #expect(URLSessionPriceAlertsTransport(config: config("https://abc.supabase.co")).isConfigured)
    }
}
