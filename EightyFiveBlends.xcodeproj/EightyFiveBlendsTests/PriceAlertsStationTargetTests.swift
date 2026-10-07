//
//  PriceAlertsStationTargetTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B) — who a Price Alert screen is about and whether its entry point is
//  offered (PriceAlertsStationTarget.swift): the community UUID is the only identity, a station
//  without one gets no entry point, a Free user sees a Pro cue, and an UNRESOLVED entitlement is
//  never presented as Free.
//
//  Pure value logic: no network, no Keychain, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private let idA = PriceAlertsStack.stationID(0xA1)
private let idB = PriceAlertsStack.stationID(0xB2)

// MARK: - Which UUID a card holds

struct PriceAlertsStationIdentityTests {
    @Test("A saved station's own UUID is used when no summary has one")
    func persistedID_isUsed() {
        #expect(PriceAlertsStationIdentity.communityStationID(persisted: idA, priceSummaryID: nil, ethanolSummaryID: nil) == idA)
    }

    @Test("A nearby station with no saved record takes the UUID the community summary carries")
    func summaryID_isUsedForAnUnsavedStation() {
        #expect(PriceAlertsStationIdentity.communityStationID(persisted: nil, priceSummaryID: idA, ethanolSummaryID: nil) == idA)
        #expect(PriceAlertsStationIdentity.communityStationID(persisted: nil, priceSummaryID: nil, ethanolSummaryID: idB) == idB)
    }

    @Test("The price summary's UUID is preferred to the ethanol summary's")
    func priceSummary_winsOverEthanol() {
        #expect(PriceAlertsStationIdentity.communityStationID(persisted: nil, priceSummaryID: idA, ethanolSummaryID: idB) == idA)
    }

    @Test("A fresh backend answer replaces a stale saved UUID — the rule used when the UUID is stored")
    func summaryID_replacesAStaleSavedID() {
        #expect(PriceAlertsStationIdentity.communityStationID(persisted: idA, priceSummaryID: idB, ethanolSummaryID: nil) == idB)
    }

    @Test("No answer never erases a saved UUID; and with nothing at all there is no UUID")
    func nothing_neverErasesAndNeverInvents() {
        #expect(PriceAlertsStationIdentity.communityStationID(persisted: idA, priceSummaryID: nil, ethanolSummaryID: nil) == idA)
        #expect(PriceAlertsStationIdentity.communityStationID(persisted: nil, priceSummaryID: nil, ethanolSummaryID: nil) == nil)
    }
}

// MARK: - The target

struct PriceAlertsStationTargetTests {
    @Test("A station with no community UUID has no target — so there is nothing to open")
    func noUUID_noTarget() {
        #expect(PriceAlertStationTarget(communityStationID: nil, name: "Corner Pump", address: "1 Main St", city: "Omaha", state: "NE") == nil)
    }

    @Test("A station with a UUID gets a target keyed by that UUID alone")
    func uuid_makesATarget() throws {
        let target = try #require(PriceAlertStationTarget(communityStationID: idA, name: "Corner Pump", address: "1 Main St", city: "Omaha", state: "NE"))

        #expect(target.communityStationID == idA)
        #expect(target.id == idA)
        #expect(target.name == "Corner Pump")
        #expect(target.locationLine == "1 Main St • Omaha, NE")
    }

    @Test("Identity is the UUID, never the name or address: same name and place with different UUIDs are different targets")
    func identity_isTheUUIDOnly() throws {
        let first = try #require(PriceAlertStationTarget(communityStationID: idA, name: "Corner Pump", address: "1 Main St", city: "Omaha", state: "NE"))
        let second = try #require(PriceAlertStationTarget(communityStationID: idB, name: "Corner Pump", address: "1 Main St", city: "Omaha", state: "NE"))

        #expect(first != second)
        #expect(first.id != second.id)
    }

    @Test("A blank name gets the same placeholder the station cards use; blank address parts are dropped")
    func blankFields_areTidied() throws {
        let target = try #require(PriceAlertStationTarget(communityStationID: idA, name: "   ", address: "", city: " Omaha ", state: ""))

        #expect(target.name == "Unnamed Station")
        #expect(target.locationLine == "Omaha")
        #expect(PriceAlertStationTarget.locationLine(address: "", city: "", state: "") == "")
    }

    @Test("A target for an alert the server listed is keyed by the alert's station UUID")
    func target_fromListing() throws {
        let object = BackendFixtures.alertObject(stationID: idB)
        let row = BackendFixtures.listRow(alert: object, stationName: "Lakeside E85", address: nil, city: "Lincoln", state: "NE")
        let listing = try BackendFixtures.decodeListing(row)

        let target = PriceAlertStationTarget(listing: listing)

        #expect(target.communityStationID == idB)
        #expect(target.name == "Lakeside E85")
        #expect(target.locationLine == "Lincoln, NE")
    }
}

// MARK: - The entry point

struct PriceAlertsEntryPresentationTests {
    @Test("No community UUID: the entry point is hidden — for every entitlement")
    func noUUID_isHidden() {
        for entitlement in [PriceAlertsEntitlement.active, .inactive, .unresolved] {
            let presentation = PriceAlertsEntryPresentation.resolve(communityStationID: nil, entitlement: entitlement)
            #expect(presentation == .hidden)
            #expect(presentation.isVisible == false)
        }
    }

    @Test("A Pro user with an eligible station is offered the entry, with no lock cue")
    func pro_isAvailable() {
        let presentation = PriceAlertsEntryPresentation.resolve(communityStationID: idA, entitlement: .active)

        #expect(presentation == .available)
        #expect(presentation.isVisible)
        #expect(presentation.showsProCue == false)
    }

    @Test("A Free user with an eligible station is offered the entry WITH a Pro cue (it opens the Pro card)")
    func free_showsTheProCue() {
        let presentation = PriceAlertsEntryPresentation.resolve(communityStationID: idA, entitlement: .inactive)

        #expect(presentation == .availableProLocked)
        #expect(presentation.isVisible)
        #expect(presentation.showsProCue)
        #expect(presentation.accessibilityHint?.contains("Pro") == true)
    }

    @Test("An UNRESOLVED entitlement is not Free: the entry has no lock cue and says nothing about Pro")
    func unresolved_isNotLabeledFree() {
        let presentation = PriceAlertsEntryPresentation.resolve(communityStationID: idA, entitlement: .unresolved)

        #expect(presentation == .available)
        #expect(presentation.showsProCue == false)
        #expect(presentation != PriceAlertsEntryPresentation.resolve(communityStationID: idA, entitlement: .inactive))
        #expect(presentation.accessibilityHint?.contains("Pro") != true)
    }

    @Test("The entry is announced by station name, and plainly when the name is blank")
    func accessibilityLabel_namesTheStation() {
        let presentation = PriceAlertsEntryPresentation.available
        #expect(presentation.accessibilityLabel(stationName: "Corner Pump") == "Price Alert for Corner Pump")
        #expect(presentation.accessibilityLabel(stationName: "  ") == "Price Alert")
        #expect(PriceAlertsEntryPresentation.hidden.accessibilityHint == nil)
    }
}
