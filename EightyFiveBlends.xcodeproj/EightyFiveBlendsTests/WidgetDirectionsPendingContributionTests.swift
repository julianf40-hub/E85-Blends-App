//
//  WidgetDirectionsPendingContributionTests.swift
//  EightyFiveBlendsTests
//
//  MapsRoutingHelper.recordPendingE85PriceContributionIfEligible(for:evidence:knownStationKey:store:)
//  with the widget's flattened destination. The Nearby E85 widget rebuilds a MapsRoutingDestination
//  from the snapshot's single joined address string (city/state/zip blank), and recomputing a
//  community key from that lands on CommunityStationKey.canonicalKey's coordinate branch — a
//  different key than Stations uses for the same station. The widget call sites therefore pass the
//  widget station's own `id` (which IS Stations' canonical key) as `knownStationKey`. The pure rule
//  is covered in WidgetDirectionsCommunityKeyTests.swift; this file covers the recorder that applies
//  it, and that every caller that omits the key behaves exactly as before.
//
//  Uses the recorder's injectable `store:` seam (see NearbyE85WidgetInteractionTests), so nothing
//  here touches UserDefaults.standard or the real PendingPriceContributionStore.shared.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct WidgetDirectionsPendingContributionTests {
    private let name = "Shell"
    private let street = "1 Main St"
    private let city = "Columbus"
    private let state = "OH"
    private let zip = "43215"
    private let latitude = 39.9612
    private let longitude = -82.9988

    private func makeIsolatedStore() -> PendingPriceContributionStore {
        let suiteName = "widget-directions-key-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PendingPriceContributionStore(defaults: defaults)
    }

    /// What StationsView stamps into `NearbyE85Station.id` (structured fields available).
    private var stationsViewKey: String {
        CommunityStationKey.canonicalKey(
            name: name, streetAddress: street, city: city, state: state, zip: zip,
            latitude: latitude, longitude: longitude
        )!
    }

    private var widgetAddress: String {
        [street, city, state, zip].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Exactly what NearbyE85WidgetRouting.resolve(.directions) and NearbyE85StationView build.
    private var flattenedWidgetDestination: MapsRoutingDestination {
        MapsRoutingDestination(
            name: name, streetAddress: widgetAddress, city: "", state: "", zip: "",
            latitude: latitude, longitude: longitude)
    }

    /// What StationsView's own Directions button builds (structured fields).
    private var structuredDestination: MapsRoutingDestination {
        MapsRoutingDestination(
            name: name, streetAddress: street, city: city, state: state, zip: zip,
            latitude: latitude, longitude: longitude)
    }

    @Test func widgetRecordingWithTheStationsOwnKeyRecordsThatKey() {
        let store = makeIsolatedStore()

        let recorded = MapsRoutingHelper.recordPendingE85PriceContributionIfEligible(
            for: flattenedWidgetDestination, evidence: .nearbyE85Widget,
            knownStationKey: stationsViewKey, store: store)

        #expect(recorded == true)
        #expect(store.current?.stationKey == stationsViewKey)
        #expect(store.current?.e85Evidence == .nearbyE85Widget)
    }

    @Test func passingTheKnownKeyChangesOnlyTheKeyNotTheRecordedFields() {
        let store = makeIsolatedStore()

        MapsRoutingHelper.recordPendingE85PriceContributionIfEligible(
            for: flattenedWidgetDestination, evidence: .nearbyE85Widget,
            knownStationKey: stationsViewKey, store: store)

        // The fields are still the destination's own, exactly as before; only the identity differs.
        #expect(store.current?.stationName == name)
        #expect(store.current?.streetAddress == widgetAddress)
        #expect(store.current?.city == nil)
        #expect(store.current?.latitude == latitude)
        #expect(store.current?.longitude == longitude)
    }

    @Test func omittingTheKnownKeyKeepsTheKeyDerivedFromTheDestination() {
        // Unchanged behavior for any caller that does not know the key: the flattened destination
        // still derives its coordinate-branch key, which is exactly why the widget callers pass one.
        let store = makeIsolatedStore()

        MapsRoutingHelper.recordPendingE85PriceContributionIfEligible(
            for: flattenedWidgetDestination, evidence: .nearbyE85Widget, store: store)

        let derived = CommunityStationKey.canonicalKey(
            name: name, streetAddress: widgetAddress, city: "", state: "", zip: "",
            latitude: latitude, longitude: longitude)
        #expect(store.current?.stationKey == derived)
        #expect(store.current?.stationKey != stationsViewKey)
    }

    @Test func aStructuredDestinationStillRecordsStationsKey() {
        // StationsView's own Directions path has structured fields and passes no known key; its
        // recorded key must be the one Stations already uses, unchanged.
        let store = makeIsolatedStore()

        MapsRoutingHelper.recordPendingE85PriceContributionIfEligible(
            for: structuredDestination, evidence: .liveNRELSearch, store: store)

        #expect(store.current?.stationKey == stationsViewKey)
    }

    @Test func aKnownKeyNeverBypassesTheReportingEligibilityRule() {
        // The key only replaces how the identity is derived; whether this station may be reported
        // at all is still CommunityPriceEligibility.canReport's call.
        let unreportable = MapsRoutingDestination(
            name: "Unknown Station", streetAddress: "", city: "", state: "", zip: "",
            latitude: nil, longitude: nil)
        let store = makeIsolatedStore()

        let recorded = MapsRoutingHelper.recordPendingE85PriceContributionIfEligible(
            for: unreportable, evidence: .nearbyE85Widget,
            knownStationKey: stationsViewKey, store: store)

        #expect(recorded == false)
        #expect(store.current == nil)
    }

    @Test func aBlankKnownKeyIsIgnored() {
        let store = makeIsolatedStore()

        MapsRoutingHelper.recordPendingE85PriceContributionIfEligible(
            for: structuredDestination, evidence: .liveNRELSearch,
            knownStationKey: "   ", store: store)

        #expect(store.current?.stationKey == stationsViewKey)
    }
}
