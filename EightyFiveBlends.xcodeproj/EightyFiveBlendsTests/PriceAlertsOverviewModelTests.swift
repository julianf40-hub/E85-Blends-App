//
//  PriceAlertsOverviewModelTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B) — the central Price Alerts screen's model
//  (PriceAlertsOverviewModel.swift): it lists the alerts the SERVER holds, reflects changes made in
//  the sheet with no signalling between the two, and is gated like the sheet is.
//
//  Runs through the REAL PriceAlertsService over the Phase 3A fakes. No network, no Keychain, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private func amount(_ thousandths: Int) -> PriceAlertAmount {
    PriceAlertAmount(thousandths: thousandths)
}

struct PriceAlertsOverviewModelTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))

    @Test("A person with no alerts sees an empty state — loaded, with nothing sent for an install that never used the feature")
    func empty() async {
        let model = PriceAlertsOverviewModel(service: stack.service)
        #expect(model.phase == .loading)

        await model.load()

        #expect(model.phase == .empty)
        #expect(model.rows.isEmpty)
        #expect(stack.transport.requests.isEmpty)
    }

    @Test("Alerts are listed with the station, what each watches for, and the latest community price")
    func list() async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop)
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(2), rule: .atOrBelow(amount(3_499)))
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())
        #expect(model.phase == .loading)

        await model.load()

        #expect(model.phase == .list)
        #expect(model.rows.count == 2)
        let byStation = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        let drop = try #require(byStation[PriceAlertsStack.stationID(1)])
        let target = try #require(byStation[PriceAlertsStack.stationID(2)])
        #expect(drop.alertTitle == "Price Drop")
        #expect(target.alertTitle == "At or below $3.499")
        #expect(target.target.name == "Corner Pump")
        #expect(target.target.locationLine == "1 Main St • Omaha, NE")
        #expect(target.latestPriceText == "Latest community price $3.149")
        #expect(target.accessibilityLabel == "Corner Pump, Alert: At or below $3.499, Latest community price $3.149")
        // A row opens the same sheet, keyed by the station's UUID.
        #expect(target.target.communityStationID == PriceAlertsStack.stationID(2))
    }

    @Test("An alert of a kind this build cannot read is still listed, safely")
    func unknownKind() async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop)
        let installationID = try #require(stack.transport.installations.keys.first)
        let id = PriceAlertsStack.stationID(1)
        stack.transport.alerts[installationID, default: [:]][id.uuidString.lowercased()] =
            BackendFixtures.alertObject(stationID: id, mode: "percent_drop")
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())

        await model.load()

        #expect(model.phase == .list)
        #expect(model.rows.first?.alertTitle == "Custom alert")
    }

    @Test("A failed load is explained and can be retried")
    func loadFailure() async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop)
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())
        stack.transport.enqueue("list_alerts", .failure(URLError(.notConnectedToInternet)))

        await model.load()

        guard case .loadFailed(let message) = model.phase else {
            Issue.record("expected a load failure, got \(model.phase)")
            return
        }
        #expect(message.headline == "You're offline")

        await model.load()
        #expect(model.phase == .list)
    }

    @Test("A refresh that fails after a good load keeps the list on screen and says so; the next one clears it")
    func refreshFailure_keepsTheList() async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop)
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())
        await model.load()
        #expect(model.refreshWarning == nil)

        stack.transport.enqueue("list_alerts", .error(status: 503, code: "internal_error"))
        await model.load()

        #expect(model.phase == .list)
        #expect(model.rows.count == 1)
        #expect(model.refreshWarning == .busy)

        await model.load()
        #expect(model.refreshWarning == nil)
        #expect(model.phase == .list)
    }

    @Test("A change made in the sheet shows here with no signalling between the two")
    func sheetChanges_areReflected() async throws {
        let service = stack.service
        let overview = PriceAlertsOverviewModel(service: service)
        await overview.load()
        #expect(overview.phase == .empty)

        let sheet = PriceAlertsStationModel(target: PriceAlertsStack.target(1), service: service)
        await sheet.load()
        sheet.select(.atOrBelow)
        sheet.form.priceText = "3.25"
        await sheet.save()
        #expect(overview.phase == .list)
        #expect(overview.rows.map(\.alertTitle) == ["At or below $3.25"])

        sheet.requestTurnOff()
        await sheet.confirmTurnOff()
        #expect(overview.phase == .empty)
    }

    @Test("Opened from the overview, the sheet shows the alert at once, without a spinner")
    func sheetOpenedFromTheOverview() async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .atOrBelow(amount(3_250)))
        let service = stack.relaunchedService()
        let overview = PriceAlertsOverviewModel(service: service)
        await overview.load()
        let row = try #require(overview.rows.first)

        let sheet = PriceAlertsStationModel(target: row.target, service: service)

        #expect(sheet.phase == .ready)
        #expect(sheet.currentSummary == .atOrBelow(amount(3_250)))
        #expect(sheet.form == PriceAlertForm(kind: .atOrBelow, priceText: "3.25"))
    }

    @Test("Free users get the Pro phase, an unresolved entitlement gets 'checking', and neither loads anything")
    func gating() async {
        let free = PriceAlertsStack(push: .registered(FakePushState.token(1)), entitlement: .inactive)
        let freeModel = PriceAlertsOverviewModel(service: free.service)
        await freeModel.load()
        #expect(freeModel.phase == .proRequired)
        #expect(free.totalSideEffects == 0)

        let unresolved = PriceAlertsStack(push: .registered(FakePushState.token(1)), entitlement: .unresolved)
        let unresolvedModel = PriceAlertsOverviewModel(service: unresolved.service)
        await unresolvedModel.load()
        #expect(unresolvedModel.phase == .resolvingEntitlement)
        #expect(unresolvedModel.phase != .proRequired)
        #expect(unresolved.totalSideEffects == 0)
    }

    @Test("A lapsed subscriber who still has an installation sees the Pro card, and no request is made")
    func lapsed_doesNotLoad() async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop)
        stack.entitlement.entitlement = .inactive
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())
        let sent = stack.transport.requests.count

        await model.load()

        #expect(model.phase == .proRequired)
        #expect(stack.transport.requests.count == sent)
    }

    @Test("The overview never turns notifications on by itself")
    func noAutomaticOptIn() async {
        let model = PriceAlertsOverviewModel(service: stack.service)

        await model.load()
        _ = model.notifications.presentation

        #expect(stack.push.optInCount == 0)
        #expect(stack.push.refreshCount == 0)
        #expect(stack.transport.count(of: "register_device") == 0)
    }
}
