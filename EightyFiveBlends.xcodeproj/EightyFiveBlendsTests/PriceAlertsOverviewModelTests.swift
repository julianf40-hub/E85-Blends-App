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

    @Test("Alerts are listed with the station, what each watches for, which price it watches, and that price's latest report")
    func list() async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop, paymentType: .credit)
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(2), rule: .atOrBelow(amount(3_499)), paymentType: .cash)
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())
        #expect(model.phase == .loading)

        await model.load()

        #expect(model.phase == .list)
        #expect(model.rows.count == 2)
        let byStation = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        let drop = try #require(byStation[PriceAlertsStack.stationID(1)])
        let target = try #require(byStation[PriceAlertsStack.stationID(2)])
        #expect(drop.alertTitle == "Price Drop")
        #expect(drop.watchText == "Credit price · 5¢ drop")
        #expect(drop.needsPaymentChoice == false)
        #expect(target.alertTitle == "At or below $3.499")
        #expect(target.watchText == "Cash price")
        #expect(target.target.name == "Corner Pump")
        #expect(target.target.locationLine == "1 Main St • Omaha, NE")
        #expect(target.latestPriceText == "Latest Cash price $3.149")
        #expect(target.accessibilityLabel == "Corner Pump, Alert: At or below $3.499, Cash price, Latest Cash price $3.149")
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
        sheet.select(payment: .credit)
        await sheet.save()
        #expect(overview.phase == .list)
        #expect(overview.rows.map(\.alertTitle) == ["At or below $3.25"])
        #expect(overview.rows.map(\.watchText) == ["Credit price"])

        sheet.requestTurnOff()
        await sheet.confirmTurnOff()
        #expect(overview.phase == .empty)
    }

    @Test("Opened from the overview, the sheet shows the alert at once, without a spinner")
    func sheetOpenedFromTheOverview() async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .atOrBelow(amount(3_250)), paymentType: .cash)
        let service = stack.relaunchedService()
        let overview = PriceAlertsOverviewModel(service: service)
        await overview.load()
        let row = try #require(overview.rows.first)

        let sheet = PriceAlertsStationModel(target: row.target, service: service)

        #expect(sheet.phase == .ready)
        #expect(sheet.currentSummary == .atOrBelow(amount(3_250)))
        #expect(sheet.form == PriceAlertForm(kind: .atOrBelow, priceText: "3.25", payment: .cash, sensitivity: .fiveCents))
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

// MARK: - Which price each row shows (Phase 3C)

struct PriceAlertsOverviewPaymentTests {
    private let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))

    private func listing(
        payment: String?,
        latestPrice: String? = "3.149",
        comparable: (price: String?, reportedAt: String?, paymentType: String?)? = nil,
        minimumChange: String = "0.050",
        mode: String = "price_drop",
        threshold: String? = nil
    ) throws -> PriceAlertListing {
        let alert = BackendFixtures.alertObject(
            stationID: PriceAlertsStack.stationID(1),
            mode: mode,
            threshold: threshold,
            minimumChange: minimumChange,
            paymentType: payment
        )
        return try BackendFixtures.decodeListing(BackendFixtures.listRow(alert: alert, latestPrice: latestPrice, latestComparable: comparable))
    }

    @Test("An alert made before payment types existed is listed as such — no Cash or Credit is claimed for it — and keeps its latest community price")
    func legacyAlert() async throws {
        _ = try await stack.service.createAlert(communityStationID: PriceAlertsStack.stationID(1), rule: .priceDrop)
        let model = PriceAlertsOverviewModel(service: stack.relaunchedService())
        await model.load()

        let row = try #require(model.rows.first)
        #expect(row.needsPaymentChoice)
        #expect(row.watchText == "Payment type not set · 5¢ drop")
        #expect(row.latestPriceText == "Latest community price $3.149")
        // Phase 3C.1: what is needed is said by the banner under the row (its own element, with the Edit button), so the
        // row's spoken label is unchanged and does not repeat the banner's sentence.
        #expect(row.accessibilityLabel == "Corner Pump, Alert: Price Drop, Payment type not set. Notifies on a drop of 5¢ or more, Latest community price $3.149")
        #expect(row.paymentChoiceBanner?.title == "Payment type needed")
        #expect(row.watchText.contains("Cash") == false)
        #expect(row.watchText.contains("Credit") == false)
    }

    @Test("A Credit alert shows the newest Credit-comparable price — never the unfiltered latest, which may be Cash")
    func creditAlert_showsItsOwnPrice() throws {
        // The unfiltered latest report is a $2.99 cash price; the credit alert's own price is $3.19.
        let credit = try listing(
            payment: "credit",
            latestPrice: "2.990",
            comparable: (price: "3.190", reportedAt: "2026-10-05T08:00:00.000Z", paymentType: "credit")
        )
        #expect(PriceAlertsOverviewModel.Row(listing: credit).latestPriceText == "Latest Credit price $3.19")
    }

    @Test("A report made as 'same for both' is labelled as such on a Cash or Credit alert")
    func sameForBothReport() throws {
        for payment in ["cash", "credit"] {
            let row = try listing(
                payment: payment,
                comparable: (price: "3.090", reportedAt: "2026-10-06T08:00:00.000Z", paymentType: "same_for_both")
            )
            #expect(PriceAlertsOverviewModel.Row(listing: row).latestPriceText == "Latest price $3.09, reported as the same for cash and credit", "\\(payment)")
        }
    }

    @Test("A Cash or Credit alert whose price has never been reported says so, instead of showing the other type's price")
    func noComparablePrice_isSaidPlainly() throws {
        let cash = try listing(payment: "cash", latestPrice: "3.190", comparable: (price: nil, reportedAt: nil, paymentType: nil))
        #expect(PriceAlertsOverviewModel.Row(listing: cash).latestPriceText == "No Cash price reported yet")

        // The same when the backend sent no comparable fields at all: nothing is borrowed from latest_price.
        let credit = try listing(payment: "credit", latestPrice: "2.990", comparable: nil)
        #expect(PriceAlertsOverviewModel.Row(listing: credit).latestPriceText == "No Credit price reported yet")
    }

    @Test("A legacy alert shows the comparable price with 'payment type not specified', or the old latest price, or nothing")
    func legacyFallbacks() throws {
        let withComparable = try listing(
            payment: nil,
            comparable: (price: "3.050", reportedAt: "2026-10-06T08:00:00.000Z", paymentType: "unknown")
        )
        #expect(PriceAlertsOverviewModel.Row(listing: withComparable).latestPriceText == "Latest community price $3.05, payment type not specified")

        let oldBackend = try listing(payment: nil, latestPrice: "3.149", comparable: nil)
        #expect(PriceAlertsOverviewModel.Row(listing: oldBackend).latestPriceText == "Latest community price $3.149")

        let nothing = try listing(payment: nil, latestPrice: nil, comparable: nil)
        #expect(PriceAlertsOverviewModel.Row(listing: nothing).latestPriceText == nil)
    }

    @Test("Row text never contains anything technical")
    func rowText_isSafeToShow() throws {
        for payment in [nil, "cash", "credit", "unknown"] as [String?] {
            let row = PriceAlertsOverviewModel.Row(listing: try listing(
                payment: payment,
                comparable: payment == nil ? nil : (price: "3.090", reportedAt: "2026-10-06T08:00:00.000Z", paymentType: payment)
            ))
            assertSafeToShow(row.watchText)
            if let text = row.latestPriceText { assertSafeToShow(text) }
        }
    }
}
