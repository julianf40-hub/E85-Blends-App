//
//  WidgetDirectionsCommunityKeyTests.swift
//  EightyFiveBlendsTests
//
//  The Nearby E85 widget's "directions" handoff (NearbyE85WidgetRouting / NearbyE85StationView)
//  rebuilds a MapsRoutingDestination from the snapshot's NearbyE85Station, whose `address` is the
//  single string StationsView.publishNearbyWidgetSnapshot() joins from street/city/state/zip. With
//  city/state/zip blank, CommunityStationKey.canonicalKey no longer sees a sufficient address and
//  takes its COORDINATE branch — a different key for the same station than the address-based one
//  Stations uses — so a report made after widget directions wrote to a second `community_stations`
//  row and looked up the station's existing community price under the wrong key.
//
//  The fix carries the station's own canonical key (NearbyE85Station.id — which IS the key
//  Stations computed) through instead of recomputing it from the flattened copy:
//  CommunityStationKey.effectiveKey. This file covers that pure rule; the recorder that uses it is
//  covered in WidgetDirectionsPendingContributionTests.swift.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct WidgetDirectionsCommunityKeyTests {
    private let name = "Shell"
    private let street = "1 Main St"
    private let city = "Columbus"
    private let state = "OH"
    private let zip = "43215"
    private let latitude = 39.9612
    private let longitude = -82.9988

    /// What StationsView stamps into `NearbyE85Station.id` (structured fields available).
    private var stationsViewKey: String {
        CommunityStationKey.canonicalKey(
            name: name, streetAddress: street, city: city, state: state, zip: zip,
            latitude: latitude, longitude: longitude
        )!
    }

    /// `NearbyE85Station.address` exactly as StationsView.publishNearbyWidgetSnapshot() builds it.
    private var widgetAddress: String {
        [street, city, state, zip].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: - Root cause

    @Test("Flattening a station's address moves it to the coordinate branch — a different key for the same station")
    func flattenedWidgetDestination_derivesADifferentKeyThanStations() throws {
        let flattenedKey = try #require(
            CommunityStationKey.canonicalKey(
                name: name, streetAddress: widgetAddress, city: "", state: "", zip: "",
                latitude: latitude, longitude: longitude
            )
        )

        #expect(flattenedKey != stationsViewKey)
        // The flattened form fell into the rounded-coordinate branch rather than the address one.
        #expect(flattenedKey.contains("39961,-82999"))
        #expect(stationsViewKey.contains("39961") == false)
    }

    // MARK: - The fix

    @Test("A key the caller already knows wins over recomputing from the flattened fields")
    func knownKey_winsOverFlattenedFields() {
        let key = CommunityStationKey.effectiveKey(
            knownKey: stationsViewKey,
            name: name, streetAddress: widgetAddress, city: "", state: "", zip: "",
            latitude: latitude, longitude: longitude
        )

        #expect(key == stationsViewKey)
    }

    @Test("The widget flow records and later reports under one and the same key")
    func widgetFlow_usesTheSameKeyEndToEnd() {
        // Recording (MapsRoutingHelper) and the post-navigation report (StationsView) both resolve
        // through effectiveKey with the contribution's key, so they cannot disagree.
        let recordedKey = CommunityStationKey.effectiveKey(
            knownKey: stationsViewKey,
            name: name, streetAddress: widgetAddress, city: "", state: "", zip: "",
            latitude: latitude, longitude: longitude
        )
        let reportKey = CommunityStationKey.effectiveKey(
            knownKey: recordedKey,
            name: name, streetAddress: widgetAddress, city: "", state: "", zip: "",
            latitude: latitude, longitude: longitude
        )

        #expect(recordedKey == stationsViewKey)
        #expect(reportKey == stationsViewKey)
    }

    // MARK: - Everyone else is unchanged

    @Test("With no known key the result is exactly canonicalKey, for structured and flattened fields alike")
    func noKnownKey_isExactlyCanonicalKey() {
        #expect(
            CommunityStationKey.effectiveKey(
                knownKey: nil,
                name: name, streetAddress: street, city: city, state: state, zip: zip,
                latitude: latitude, longitude: longitude
            ) == stationsViewKey
        )
        #expect(
            CommunityStationKey.effectiveKey(
                knownKey: nil,
                name: name, streetAddress: widgetAddress, city: "", state: "", zip: "",
                latitude: latitude, longitude: longitude
            ) == CommunityStationKey.canonicalKey(
                name: name, streetAddress: widgetAddress, city: "", state: "", zip: "",
                latitude: latitude, longitude: longitude
            )
        )
    }

    @Test("A blank or whitespace-only known key is ignored")
    func blankKnownKey_fallsBackToCanonicalKey() {
        for blank in ["", " ", "\n\t "] {
            #expect(
                CommunityStationKey.effectiveKey(
                    knownKey: blank,
                    name: name, streetAddress: street, city: city, state: state, zip: zip,
                    latitude: latitude, longitude: longitude
                ) == stationsViewKey,
                "known key \(String(reflecting: blank)) must fall back"
            )
        }
    }

    @Test("A known key is an opaque identity: returned exactly as given, never re-normalized")
    func knownKey_isReturnedUnchanged() {
        let opaque = "Some|Opaque|Key|42"

        #expect(
            CommunityStationKey.effectiveKey(
                knownKey: opaque,
                name: name, streetAddress: street, city: city, state: state, zip: zip,
                latitude: latitude, longitude: longitude
            ) == opaque
        )
    }

    @Test("A known key is returned even when nothing could be derived from the fields")
    func knownKey_survivesEmptyFields() {
        #expect(
            CommunityStationKey.canonicalKey(
                name: "", streetAddress: "", city: "", state: "", zip: "", latitude: nil, longitude: nil
            ) == nil
        )
        #expect(
            CommunityStationKey.effectiveKey(
                knownKey: stationsViewKey,
                name: "", streetAddress: "", city: "", state: "", zip: "", latitude: nil, longitude: nil
            ) == stationsViewKey
        )
    }

    @Test("With neither a known key nor any fields there is no key")
    func noKnownKeyAndNoFields_isNil() {
        #expect(
            CommunityStationKey.effectiveKey(
                knownKey: nil,
                name: "", streetAddress: "", city: "", state: "", zip: "", latitude: nil, longitude: nil
            ) == nil
        )
    }
}
