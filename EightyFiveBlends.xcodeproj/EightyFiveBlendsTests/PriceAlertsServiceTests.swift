//
//  PriceAlertsServiceTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts client integration (Phase 3A) — PriceAlertsService, the orchestrator a Price Alerts
//  screen will use (PriceAlertsService.swift): the canonical-station-UUID requirement, the Pro rules
//  (including that a lapse preserves configuration and a renewal resumes it), alert CRUD semantics,
//  the order of backend calls, "nothing happens until asked", idempotent reconciliation, and the
//  request-order serialization of list-touching operations.
//
//  Everything runs over fakes; the transport simulates price-alerts-api as documented. No network,
//  no Keychain, no production credential.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private func amount(_ thousandths: Int) -> PriceAlertAmount {
    PriceAlertAmount(thousandths: thousandths)
}

private let stationOne = PriceAlertsStack.stationID(1)
private let stationTwo = PriceAlertsStack.stationID(2)

/// A saved alert whose mode this build does not understand, as a newer backend could return it.
private func alertWithUnknownMode() throws -> PriceAlert {
    let object = BackendFixtures.alertObject(stationID: stationOne, mode: "percent_drop")
    return try JSONDecoder().decode(PriceAlert.self, from: BackendFixtures.data(object))
}

// MARK: - Stations

struct PriceAlertsStationRequirementTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
    private var service: PriceAlertsService { stack.service }

    @Test("The canonical community station UUID is sent exactly, lower-cased, and is the alert's identity")
    func canonicalUUID_isUsed() async throws {
        let id = UUID(uuidString: "11223344-5566-4A77-8899-AABBCCDDEE0A")!

        let saved = try await service.createAlert(communityStationID: id, rule: .priceDrop)

        #expect(stack.transport.lastRequest("set_alert")?.json["station_id"] as? String == "11223344-5566-4a77-8899-aabbccddee0a")
        #expect(saved.stationID == id)
        #expect(service.alerts.map(\.alert.stationID) == [id])
    }

    @Test("A station with no canonical UUID is refused as not eligible — before any request, and without creating an installation")
    func missingUUID_isRejected() async {
        await #expect(throws: PriceAlertsServiceError.stationNotEligibleForPriceAlerts) {
            try await service.createAlert(communityStationID: nil, rule: .priceDrop)
        }
        await #expect(throws: PriceAlertsServiceError.stationNotEligibleForPriceAlerts) {
            try await service.deleteAlert(communityStationID: nil)
        }
        #expect(stack.totalSideEffects == 0)
    }

    @Test("Eligibility is decided first: a nil UUID is 'not eligible' even when the rest of the request is also invalid")
    func missingUUID_winsOverOtherValidation() async {
        await #expect(throws: PriceAlertsServiceError.stationNotEligibleForPriceAlerts) {
            try await service.createAlert(communityStationID: nil, rule: .atOrBelow(amount(1)), preferences: PriceAlertPreferences(minimumChange: amount(0), cooldownMinutes: 1))
        }
        #expect(stack.totalSideEffects == 0)
    }

    @Test("No fallback identity is ever fabricated: only the supplied UUID reaches the wire, with no name, coordinates, key or hash")
    func noFallbackIdentity() async throws {
        _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        _ = try await service.createAlert(communityStationID: stationTwo, rule: .atOrBelow(amount(3_000)))

        for request in stack.transport.requests where request.action == "set_alert" {
            let keys = Set(request.json.keys)
            #expect(keys.isSubset(of: ["action", "client_installation_id", "installation_secret", "station_id", "alert_mode", "threshold_price", "minimum_change", "cooldown_minutes", "alert_contract_version"]))
            for forbidden in ["name", "station_name", "address", "city", "state", "zip", "latitude", "longitude", "normalized_key", "canonical_key", "gasbuddy_id", "id"] {
                #expect(request.json[forbidden] == nil, "\(forbidden) must not be sent")
            }
        }
        let sent = stack.transport.requests.filter { $0.action == "set_alert" }.compactMap { $0.json["station_id"] as? String }
        #expect(sent == [stationOne.uuidString.lowercased(), stationTwo.uuidString.lowercased()])
    }

    @Test("A server that does not know the station is reported as such, distinct from 'no UUID'")
    func unknownStation_isStationNotFound() async {
        stack.transport.knownStationIDs = []

        await #expect(throws: PriceAlertsServiceError.stationNotFound) {
            try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        }
        #expect(service.alerts.isEmpty)
    }

    @Test("Values the backend would reject never leave the device")
    func invalidValues_areRefusedLocally() async {
        await #expect(throws: PriceAlertsServiceError.invalidAlert(.thresholdOutOfRange)) {
            try await service.createAlert(communityStationID: stationOne, rule: .atOrBelow(amount(9_000)))
        }
        await #expect(throws: PriceAlertsServiceError.invalidAlert(.cooldownOutOfRange)) {
            try await service.createAlert(communityStationID: stationOne, rule: .priceDrop, preferences: PriceAlertPreferences(minimumChange: amount(50), cooldownMinutes: 5))
        }
        #expect(stack.totalSideEffects == 0)
    }
}

// MARK: - Pro

struct PriceAlertsProBehaviorTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
    private var service: PriceAlertsService { stack.service }
    private var transport: FakePriceAlertsTransport { stack.transport }

    @Test("An active Pro user can configure alerts")
    func activePro_isAllowed() async throws {
        stack.entitlement.entitlement = .active
        #expect(service.entitlement == .active)

        let saved = try await service.createAlert(communityStationID: stationOne, rule: .atOrBelow(amount(3_250)))

        #expect(saved.rule == .atOrBelow(amount(3_250)))
        #expect(service.alerts.count == 1)
    }

    @Test("A Free user cannot create or change an alert — refused on the device, with no request and no installation")
    func freeUser_isBlocked() async throws {
        let existing = try alertWithUnknownMode()
        stack.entitlement.entitlement = .inactive
        #expect(service.entitlement == .inactive)

        await #expect(throws: PriceAlertsServiceError.proRequired) {
            try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        }
        await #expect(throws: PriceAlertsServiceError.proRequired) {
            try await service.updateAlert(existing, rule: .priceDrop)
        }
        #expect(stack.totalSideEffects == 0)
    }

    @Test("While RevenueCat has not answered, 'Free' is not assumed: the user gets a retryable 'unresolved', not an upsell")
    func unresolvedEntitlement_isNotFree() async {
        stack.entitlement.entitlement = .unresolved

        await #expect(throws: PriceAlertsServiceError.entitlementUnresolved) {
            try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        }
        #expect(PriceAlertsServiceError.entitlementUnresolved.isRetryable)
        #expect(stack.totalSideEffects == 0)
    }

    @Test("Free users can still look at and remove alerts — and with no installation that creates nothing")
    func freeUser_canListAndDelete_withoutCreatingAnything() async throws {
        stack.entitlement.entitlement = .inactive

        await service.refreshAlerts()
        try await service.deleteAlert(communityStationID: stationOne)

        #expect(service.listState == .loaded)
        #expect(service.alerts.isEmpty)
        #expect(stack.totalSideEffects == 0)
    }

    @Test("When Pro lapses, every alert and the installation are preserved — nothing is deleted, disabled or unregistered")
    func proLapse_preservesConfiguration() async throws {
        _ = try await service.createAlert(communityStationID: stationOne, rule: .atOrBelow(amount(3_250)))
        _ = try await service.createAlert(communityStationID: stationTwo, rule: .priceDrop)
        #expect(await service.reconcileDeviceRegistration() == .registered)
        let credential = try #require(stack.credentials.stored)
        let before = service.alerts

        stack.entitlement.entitlement = .inactive
        await service.refreshAlerts()
        #expect(await service.reconcileDeviceRegistration() == .alreadyRegistered)

        // Still visible, unchanged, on the device and on the server.
        #expect(service.alerts == before)
        #expect(service.alerts.count == 2)
        #expect(transport.alerts[credential.wireInstallationID]?.count == 2)
        #expect(transport.devices.filter(\.enabled).count == 1)
        // No call that removes or disables anything was made because of the lapse.
        #expect(transport.actions.contains("delete_alert") == false)
        #expect(transport.actions.contains("unregister_device") == false)
        #expect(stack.records.clearCount == 0)
        // Changing an alert is what is blocked; the existing one is untouched.
        let existing = try #require(service.alerts.first?.alert)
        await #expect(throws: PriceAlertsServiceError.proRequired) {
            try await service.updateAlert(existing, rule: .priceDrop)
        }
        #expect(service.alerts == before)
    }

    @Test("A lapsed subscriber can still remove an alert, deliberately")
    func lapsedSubscriber_canDelete() async throws {
        _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        stack.entitlement.entitlement = .inactive

        try await service.deleteAlert(communityStationID: stationOne)

        #expect(service.alerts.isEmpty)
        #expect(transport.count(of: "delete_alert") == 1)
    }

    @Test("When Pro returns, the preserved alert is simply editable again — same installation, nothing re-created")
    func renewedPro_resumesWithPreservedConfiguration() async throws {
        let original = try await service.createAlert(communityStationID: stationOne, rule: .atOrBelow(amount(3_250)))
        let credential = try #require(stack.credentials.stored)

        stack.entitlement.entitlement = .inactive
        await service.refreshAlerts()
        #expect(service.alerts.count == 1)

        stack.entitlement.entitlement = .active
        let updated = try await service.updateAlert(original, preferences: PriceAlertPreferences(minimumChange: amount(100), cooldownMinutes: 720))

        #expect(updated.rule == .atOrBelow(amount(3_250)))
        #expect(updated.preferences == PriceAlertPreferences(minimumChange: amount(100), cooldownMinutes: 720))
        // One alert, one installation, one bootstrap, one saved credential: nothing was recreated.
        #expect(service.alerts.count == 1)
        #expect(stack.credentials.stored == credential)
        #expect(stack.credentials.saveCount == 1)
        #expect(transport.count(of: "bootstrap") == 1)
        #expect(Set(transport.requests.compactMap(\.installationID)).count == 1)
    }

    // MARK: The server's own verdict

    @Test("If the server does not yet see the user as Pro, its link is refreshed once and the save retried once")
    func serverProLink_isRefreshedOnce() async throws {
        transport.enqueue("set_alert", .error(status: 403, code: "pro_required"))

        let saved = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)

        #expect(saved.stationID == stationOne)
        #expect(transport.actions == ["bootstrap", "set_alert", "bootstrap", "set_alert", "list_alerts"])
    }

    @Test("A second refusal is the server's final word: proRequiredByServer, with no third attempt")
    func serverProRefusal_isFinal() async {
        transport.serverGrantsPro = false

        await #expect(throws: PriceAlertsServiceError.proRequiredByServer) {
            try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        }
        #expect(transport.count(of: "set_alert") == 2)
        #expect(transport.count(of: "bootstrap") == 2)
        #expect(transport.count(of: "list_alerts") == 0)
        #expect(service.alerts.isEmpty)
    }

    @Test("A server link missing because RevenueCat was not ready at the first bootstrap is repaired by the retry")
    func linkMissingAtFirstBootstrap_isRepaired() async throws {
        stack.identity.identity = nil
        let identity = stack.identity
        let flipped = Box(false)
        transport.beforeResponding = { request in
            // RevenueCat becomes ready while the first save is in flight.
            if request.action == "set_alert" {
                await MainActor.run {
                    if flipped.value == false {
                        flipped.value = true
                        identity.identity = PriceAlertsRevenueCatIdentity(appUserID: "user-1", environment: .sandbox)
                    }
                }
            }
        }

        let saved = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)

        #expect(saved.stationID == stationOne)
        #expect(transport.count(of: "set_alert") == 2)
        let secondBootstrap = transport.requests.filter { $0.action == "bootstrap" }.last
        #expect(secondBootstrap?.json["revenuecat_app_user_id"] as? String == "user-1")
    }
}

// MARK: - CRUD

struct PriceAlertsCRUDTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
    private var service: PriceAlertsService { stack.service }
    private var transport: FakePriceAlertsTransport { stack.transport }

    @Test("After a save the list is re-read from the server, not patched locally")
    func create_refreshesFromServer() async throws {
        _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)

        #expect(transport.actions == ["bootstrap", "set_alert", "list_alerts"])
        #expect(service.listState == .loaded)
        #expect(service.alerts.count == 1)
        #expect(service.alerts.first?.station.name == "Corner Pump")
    }

    @Test("One alert per station: creating again replaces it")
    func create_replacesTheStationsAlert() async throws {
        _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        _ = try await service.createAlert(communityStationID: stationOne, rule: .atOrBelow(amount(2_999)))

        #expect(service.alerts.count == 1)
        #expect(service.alerts.first?.alert.rule == .atOrBelow(amount(2_999)))
    }

    @Test("An update sends the alert's full state, carrying forward whatever was not changed")
    func update_carriesUnchangedFieldsForward() async throws {
        let original = try await service.createAlert(
            communityStationID: stationOne,
            rule: .atOrBelow(amount(3_250)),
            preferences: PriceAlertPreferences(minimumChange: amount(100), cooldownMinutes: 720)
        )

        // Change only the threshold.
        _ = try await service.updateAlert(original, rule: .atOrBelow(amount(3_000)))
        let afterRule = try #require(transport.lastRequest("set_alert"))
        #expect(afterRule.json["threshold_price"] as? Double == 3.0)
        #expect(afterRule.json["minimum_change"] as? Double == 0.1)
        #expect(afterRule.json["cooldown_minutes"] as? Int == 720)
        #expect(afterRule.json["alert_mode"] as? String == "at_or_below")

        // Change only the preferences.
        _ = try await service.updateAlert(original, preferences: PriceAlertPreferences(minimumChange: amount(200), cooldownMinutes: 60))
        let afterPreferences = try #require(transport.lastRequest("set_alert"))
        #expect(afterPreferences.json["threshold_price"] as? Double == 3.25)
        #expect(afterPreferences.json["minimum_change"] as? Double == 0.2)
        #expect(afterPreferences.json["cooldown_minutes"] as? Int == 60)

        // Switch to a mode without a threshold: none is sent.
        _ = try await service.updateAlert(original, rule: .priceDrop)
        let afterSwitch = try #require(transport.lastRequest("set_alert"))
        #expect(afterSwitch.json["threshold_price"] == nil)
        #expect(afterSwitch.json["alert_mode"] as? String == "price_drop")
        #expect(service.alerts.count == 1)
    }

    @Test("An alert whose mode this build cannot read is not silently rewritten into another")
    func update_unknownMode_isRefused() async throws {
        let existing = try alertWithUnknownMode()

        await #expect(throws: PriceAlertsServiceError.invalidAlert(.unsupportedMode)) {
            try await service.updateAlert(existing, preferences: .defaults)
        }
        #expect(stack.totalSideEffects == 0)

        // Explicitly choosing a rule is fine.
        _ = try await service.updateAlert(existing, rule: .priceDrop)
        #expect(transport.count(of: "set_alert") == 1)
    }

    @Test("Deleting removes the alert, re-reads the list, and is idempotent")
    func delete_isIdempotent() async throws {
        _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)

        try await service.deleteAlert(communityStationID: stationOne)
        try await service.deleteAlert(communityStationID: stationOne)

        #expect(service.alerts.isEmpty)
        #expect(transport.count(of: "delete_alert") == 2)
    }

    @Test("Listing for an install that never used Price Alerts is answered locally")
    func list_withoutInstallation_isLocal() async {
        await service.refreshAlerts()

        #expect(service.listState == .loaded)
        #expect(service.alerts.isEmpty)
        #expect(stack.totalSideEffects == 0)
    }

    @Test("A failed refresh keeps the last good list and reports the failure")
    func list_failure_keepsPreviousAlerts() async throws {
        _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        let before = service.alerts
        transport.enqueue("list_alerts", .error(status: 503, code: "server_not_configured"))

        await service.refreshAlerts()

        #expect(service.alerts == before)
        #expect(service.listState == .failed(.api(.api(code: .serverNotConfigured, statusCode: 503))))
        // Recovers on the next attempt.
        await service.refreshAlerts()
        #expect(service.listState == .loaded)
    }

    @Test("A network failure is reported as retryable, and nothing is half-applied")
    func network_failure() async {
        stack.transport.enqueue("bootstrap", .failure(PriceAlertsAPIError.network(.offline)))

        do {
            _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
            Issue.record("expected a failure")
        } catch let error as PriceAlertsServiceError {
            #expect(error == .api(.network(.offline)))
            #expect(error.isRetryable)
        } catch {
            Issue.record("unexpected error type")
        }
        #expect(service.alerts.isEmpty)
        #expect(transport.count(of: "set_alert") == 0)
    }

    @Test("If the server has forgotten the installation, the next read recovers it and carries on")
    func serverForgets_recovers() async throws {
        _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        let credential = try #require(stack.credentials.stored)
        transport.installations.removeAll()

        await service.refreshAlerts()

        #expect(service.listState == .loaded)
        #expect(stack.credentials.stored == credential)
        #expect(transport.installations[credential.wireInstallationID] != nil)
    }

    @Test("The server's own status is available once an installation exists, and not before")
    func serverStatus() async throws {
        #expect(try await service.refreshServerStatus() == nil)
        #expect(stack.totalSideEffects == 0)

        _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        _ = await service.reconcileDeviceRegistration()

        let status = try #require(try await service.refreshServerStatus())
        #expect(status.proIsActive)
        #expect(status.activeDevices == 1)
        #expect(status.enabledAlerts == 1)
    }
}

// MARK: - Orchestration

struct PriceAlertsOrchestrationTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
    private var service: PriceAlertsService { stack.service }
    private var transport: FakePriceAlertsTransport { stack.transport }

    @Test("Installation first, then the device: bootstrap precedes register_device, both with the same persisted credential")
    func installationThenTokenRegistration_ordering() async throws {
        let outcome = await service.reconcileDeviceRegistration()

        #expect(outcome == .registered)
        #expect(transport.actions == ["bootstrap", "register_device"])
        let bootstrap = try #require(transport.lastRequest("bootstrap"))
        let register = try #require(transport.lastRequest("register_device"))
        #expect(bootstrap.installationID == register.installationID)
        #expect(bootstrap.secret == register.secret)
        // The credential that was sent is the one that was persisted — before it was sent.
        #expect(stack.credentials.saveCount == 1)
        #expect(stack.credentials.stored?.wireInstallationID == bootstrap.installationID)
    }

    @Test("Alerts and the device share one installation: a single bootstrap serves both")
    func alertsAndDevice_shareOneInstallation() async throws {
        _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        _ = await service.reconcileDeviceRegistration()

        #expect(transport.actions == ["bootstrap", "set_alert", "list_alerts", "register_device"])
        #expect(Set(transport.requests.compactMap(\.installationID)).count == 1)
        #expect(stack.credentials.saveCount == 1)
    }

    @Test("Constructing the service and reading its state do nothing — no Keychain, no network, no prompt, no registration")
    func noLaunchTimeSideEffects() {
        let fresh = PriceAlertsStack(push: .registered(FakePushState.token(9)))

        _ = fresh.service.alerts
        _ = fresh.service.listState
        _ = fresh.service.entitlement
        _ = fresh.service.lastDeviceRegistrationOutcome

        #expect(fresh.totalSideEffects == 0)
        // Not even a Keychain READ happens until something needs the installation.
        #expect(fresh.credentials.loadCount == 0)
        #expect(fresh.credentials.stored == nil)
    }

    @Test("The app-level hook does nothing at all until the user has opted in")
    func appLevelHook_doesNothingBeforeOptIn() async {
        for _ in 0..<3 {
            #expect(await service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .skipped(.notOptedIn))
        }
        #expect(stack.totalSideEffects == 0)
        #expect(stack.credentials.loadCount == 0)
    }

    @Test("Reconciling again and again is idempotent: one bootstrap, one registration, one active device")
    func repeatedReconciliation_isIdempotent() async {
        var outcomes: [PriceAlertsDeviceRegistrationOutcome] = []
        for _ in 0..<10 {
            outcomes.append(await service.reconcileDeviceRegistration())
            await service.refreshAlerts()
        }

        #expect(outcomes.first == .registered)
        #expect(outcomes.dropFirst().allSatisfy { $0 == .alreadyRegistered })
        #expect(transport.count(of: "bootstrap") == 1)
        #expect(transport.count(of: "register_device") == 1)
        #expect(transport.devices.filter(\.enabled).count == 1)
        #expect(stack.credentials.saveCount == 1)
    }

    // MARK: Serialization

    @Test("Operations that touch the alert list run one at a time, in the order requested")
    func operations_areSerializedInRequestOrder() async throws {
        let gate = AsyncGate()
        transport.beforeResponding = { request in
            if request.action == "set_alert" { await gate.parkFirstCaller() }
        }

        let create = Task { try await service.createAlert(communityStationID: stationOne, rule: .priceDrop) }
        #expect(await gate.waitUntilParked())
        // Requested while the save is in flight: a refresh, and a second save.
        let refresh = Task { await service.refreshAlerts() }
        let secondCreate = Task { try await service.createAlert(communityStationID: stationTwo, rule: .priceDrop) }
        for _ in 0..<100 { await Task.yield() }

        // Neither has started: only the first save has reached the server.
        #expect(transport.count(of: "set_alert") == 1)
        #expect(transport.count(of: "list_alerts") == 0)

        gate.release()
        _ = try await create.value
        await refresh.value
        _ = try await secondCreate.value

        let sequence = transport.actions.filter { $0 == "set_alert" || $0 == "list_alerts" }
        // save #1, its re-read, the queued refresh, save #2, its re-read.
        #expect(sequence == ["set_alert", "list_alerts", "list_alerts", "set_alert", "list_alerts"])
        #expect(service.alerts.count == 2)
    }
}

// MARK: - Payment type and drop size (Phase 3C)

struct PriceAlertsServicePaymentTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
    private var service: PriceAlertsService { stack.service }
    private var transport: FakePriceAlertsTransport { stack.transport }

    @Test("A chosen payment type is saved, listed and read back — a Cash alert and a Credit alert side by side")
    func paymentType_roundTrips() async throws {
        let cash = try await service.createAlert(
            communityStationID: stationOne, rule: .priceDrop,
            preferences: PriceAlertPreferences.newAlertDefaults, paymentType: .cash
        )
        let credit = try await service.createAlert(
            communityStationID: stationTwo, rule: .atOrBelow(amount(2_890)),
            preferences: PriceAlertPreferences.newAlertDefaults, paymentType: .credit
        )
        #expect(cash.paymentType == .cash)
        #expect(credit.paymentType == .credit)

        // A relaunched app reads them back from the server.
        let relaunched = stack.relaunchedService()
        await relaunched.refreshAlerts()
        let byStation = Dictionary(uniqueKeysWithValues: relaunched.alerts.map { ($0.alert.stationID, $0.alert) })
        #expect(byStation[stationOne]?.paymentType == .cash)
        #expect(byStation[stationOne]?.minimumChange == amount(100))
        #expect(byStation[stationTwo]?.paymentType == .credit)
        #expect(byStation[stationTwo]?.rule == .atOrBelow(amount(2_890)))
    }

    @Test("Editing only the target price keeps the payment type, the drop size and the cooldown")
    func editTarget_preservesPaymentAndDropSize() async throws {
        let original = try await service.createAlert(
            communityStationID: stationOne, rule: .atOrBelow(amount(2_890)),
            preferences: PriceAlertPreferences(minimumChange: amount(150), cooldownMinutes: 720), paymentType: .credit
        )

        let updated = try await service.updateAlert(original, rule: .atOrBelow(amount(2_790)))

        let request = try #require(transport.lastRequest("set_alert"))
        #expect(request.json["payment_type"] as? String == "credit")
        #expect(request.json["minimum_change"] as? Double == 0.15)
        #expect(request.json["cooldown_minutes"] as? Int == 720)
        #expect(request.json["threshold_price"] as? Double == 2.79)
        #expect(updated.paymentType == .credit)
        #expect(updated.minimumChange == amount(150))
        #expect(updated.id == original.id, "an update replaces the one alert, it does not create another")
        #expect(service.alerts.count == 1)
    }

    @Test("Editing only the drop size keeps the payment type and the rule")
    func editDropSize_preservesPaymentAndRule() async throws {
        let original = try await service.createAlert(
            communityStationID: stationOne, rule: .priceDrop,
            preferences: PriceAlertPreferences.newAlertDefaults, paymentType: .cash
        )

        let updated = try await service.updateAlert(
            original, preferences: PriceAlertPreferences(minimumChange: amount(200), cooldownMinutes: 360)
        )

        let request = try #require(transport.lastRequest("set_alert"))
        #expect(request.json["payment_type"] as? String == "cash")
        #expect(request.json["alert_mode"] as? String == "price_drop")
        #expect(request.json["minimum_change"] as? Double == 0.2)
        #expect(updated.paymentType == .cash)
        #expect(updated.rule == .priceDrop)
    }

    @Test("Changing only the payment type keeps the rule, the price, the drop size and the cooldown")
    func editPayment_preservesTheRest() async throws {
        let original = try await service.createAlert(
            communityStationID: stationOne, rule: .atOrBelow(amount(2_890)),
            preferences: PriceAlertPreferences(minimumChange: amount(75), cooldownMinutes: 1_440), paymentType: .cash
        )

        let updated = try await service.updateAlert(original, paymentType: .credit)

        let request = try #require(transport.lastRequest("set_alert"))
        #expect(request.json["payment_type"] as? String == "credit")
        #expect(request.json["threshold_price"] as? Double == 2.89)
        #expect(request.json["minimum_change"] as? Double == 0.075)
        #expect(request.json["cooldown_minutes"] as? Int == 1_440)
        #expect(updated.paymentType == .credit)
        #expect(updated.rule == .atOrBelow(amount(2_890)))
    }

    @Test("A caller that names no payment type changes nothing about it: a legacy alert stays unknown, a typed one stays typed")
    func noPaymentNamed_changesNothing() async throws {
        // Older callers (and tests) create without one: the server records `unknown`; nothing is invented.
        let legacy = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop)
        #expect(transport.lastRequest("set_alert")?.json["payment_type"] == nil)
        #expect(legacy.paymentType == .unknown)

        _ = try await service.updateAlert(legacy, rule: .atOrBelow(amount(3_000)))
        #expect(transport.lastRequest("set_alert")?.json["payment_type"] == nil, "an `unknown` alert is never sent as one")
        #expect(service.alerts.first?.alert.paymentType == .unknown)

        // …and once someone chooses, later edits that name nothing keep the choice.
        let chosen = try await service.updateAlert(legacy, paymentType: .credit)
        #expect(chosen.paymentType == .credit)
        _ = try await service.updateAlert(chosen, rule: .priceDrop)
        #expect(transport.lastRequest("set_alert")?.json["payment_type"] as? String == "credit")
        #expect(service.alerts.first?.alert.paymentType == .credit)
    }

    @Test("`unknown` passed explicitly is treated as 'not chosen' and is never put on the wire")
    func explicitUnknown_isNotSent() async throws {
        let saved = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop, paymentType: .unknown)

        #expect(transport.lastRequest("set_alert")?.json["payment_type"] == nil)
        #expect(saved.paymentType == .unknown)
    }

    @Test("The server refusing a payment type is explained plainly and nothing is changed")
    func invalidPaymentType_isExplained() async throws {
        transport.enqueue("set_alert", .error(status: 400, code: "invalid_payment_type"))

        do {
            _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop, paymentType: .cash)
            Issue.record("expected the save to fail")
        } catch {
            let message = PriceAlertsUserMessage(error: PriceAlertsServiceError.from(error))
            #expect(message.headline == "Choose Cash or Credit")
            #expect(message.isRetryable == false)
            assertSafeToShow(message.headline)
            assertSafeToShow(message.body)
        }
        #expect(service.alerts.isEmpty)
    }

    @Test("A Pro lapse keeps the payment type and the drop size untouched; renewal resumes it")
    func lapse_preservesPaymentAndDropSize() async throws {
        _ = try await service.createAlert(
            communityStationID: stationOne, rule: .priceDrop,
            preferences: PriceAlertPreferences(minimumChange: amount(200), cooldownMinutes: 360), paymentType: .credit
        )
        let sent = transport.count(of: "set_alert")

        stack.entitlement.entitlement = .inactive
        await service.refreshAlerts()

        #expect(service.alerts.first?.alert.paymentType == .credit)
        #expect(service.alerts.first?.alert.minimumChange == amount(200))
        #expect(transport.count(of: "set_alert") == sent)
        #expect(transport.count(of: "delete_alert") == 0)

        stack.entitlement.entitlement = .active
        await service.refreshAlerts()
        #expect(service.alerts.first?.alert.paymentType == .credit)
        #expect(transport.alerts.values.flatMap { $0.values }.count == 1)
    }

    @Test("Turning an alert off is unchanged by payment type: it deletes the one alert for the station")
    func delete_isUnchanged() async throws {
        _ = try await service.createAlert(communityStationID: stationOne, rule: .priceDrop, paymentType: .cash)
        _ = try await service.createAlert(communityStationID: stationTwo, rule: .priceDrop, paymentType: .credit)

        try await service.deleteAlert(communityStationID: stationOne)

        #expect(service.alerts.map(\.alert.stationID) == [stationTwo])
        #expect(service.alerts.first?.alert.paymentType == .credit)
    }
}
