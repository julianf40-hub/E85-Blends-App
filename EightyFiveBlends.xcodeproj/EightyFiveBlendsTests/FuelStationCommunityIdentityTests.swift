//
//  FuelStationCommunityIdentityTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts iOS foundation — the SwiftData half of the backend community-station UUID:
//  `FuelStation.communityStationID` and the adopt/discard methods in
//  FuelStation+CommunityIdentity.swift. The pure rules and the DTO layer are covered (and run
//  without SwiftData) in CommunityStationIdentityTests.swift.
//
//  Stations are constructed with FuelStation's normal initializer, outside of any ModelContext —
//  the same standard, supported way FuelPriceLookupTests exercises @Model stored-property logic
//  without a live container.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct FuelStationCommunityIdentityTests {
    private let first = UUID(uuidString: "738574C5-E64F-40D8-AD6D-21025B412505")!
    private let second = UUID(uuidString: "BE3216DD-23BB-41C1-AB00-1E6920A4BCF3")!

    /// A well-addressed station, so its canonical key is address-based (coordinates are ignored
    /// by `CommunityStationKey.canonicalKey` when the address alone is sufficient).
    private func savedStation(communityStationID: UUID? = nil) -> FuelStation {
        FuelStation(
            name: "Shell",
            address: "1 Main St",
            city: "Columbus",
            state: "OH",
            zipCode: "43215",
            latitude: 39.96,
            longitude: -83.0,
            communityStationID: communityStationID
        )
    }

    private func communityStation(id: UUID?) throws -> CommunityStation {
        let idLine = id.map { "\"id\": \"\($0.uuidString)\"," } ?? ""
        let data = Data(
            """
            { \(idLine) "normalized_key": "shell|1 main st|columbus|oh|43215", "name": "Shell" }
            """.utf8
        )
        return try JSONDecoder().decode(CommunityStation.self, from: data)
    }

    private func priceSummary(stationID: UUID?) -> CommunityPriceSummary {
        let report = CommunityPriceReport(
            id: nil,
            stationID: stationID,
            normalizedStationKey: "shell|1 main st|columbus|oh|43215",
            price: 3.19,
            reportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            reporterID: "anonymous-device-id",
            notes: nil,
            createdAt: nil
        )
        return CommunityPriceSummary(
            normalizedStationKey: "shell|1 main st|columbus|oh|43215",
            latestReport: report,
            reportCount: 1
        )
    }

    // MARK: - Default and initializer

    @Test("A station not backed by a community row has no community UUID")
    func newStation_hasNoCommunityUUID() {
        #expect(savedStation().communityStationID == nil)
    }

    @Test("The initializer stores a UUID it is given")
    func initializer_storesCommunityUUID() {
        #expect(savedStation(communityStationID: first).communityStationID == first)
    }

    // MARK: - Community station / summary -> FuelStation

    @Test("A community station's UUID propagates into the saved FuelStation")
    func communityStation_propagatesIntoFuelStation() throws {
        let saved = savedStation()

        let changed = saved.adoptCommunityStationID(from: try communityStation(id: first))

        #expect(changed)
        #expect(saved.communityStationID == first)
    }

    @Test("A community price summary's UUID propagates into the saved FuelStation")
    func priceSummary_propagatesIntoFuelStation() {
        let saved = savedStation()

        let changed = saved.adoptCommunityStationID(from: priceSummary(stationID: first))

        #expect(changed)
        #expect(saved.communityStationID == first)
    }

    @Test("A station the backend gave no UUID for stays nil — nothing is fabricated")
    func missingBackendUUID_staysNil() throws {
        let saved = savedStation()

        #expect(saved.adoptCommunityStationID(from: try communityStation(id: nil)) == false)
        #expect(saved.adoptCommunityStationID(from: priceSummary(stationID: nil)) == false)
        #expect(saved.adoptCommunityStationID(nil) == false)
        #expect(saved.communityStationID == nil)
    }

    @Test("Adopting the UUID a station already carries changes nothing and reports no change")
    func adoptingSameUUID_isNoOp() {
        let saved = savedStation(communityStationID: first)

        #expect(saved.adoptCommunityStationID(first) == false)
        #expect(saved.communityStationID == first)
    }

    @Test("A different UUID from the backend replaces a stale stored one")
    func differentUUID_replacesStaleValue() {
        let saved = savedStation(communityStationID: first)

        #expect(saved.adoptCommunityStationID(second))
        #expect(saved.communityStationID == second)
    }

    @Test("A response without a UUID never erases the stored one")
    func missingUUID_neverErasesStoredValue() {
        let saved = savedStation(communityStationID: first)

        #expect(saved.adoptCommunityStationID(from: priceSummary(stationID: nil)) == false)
        #expect(saved.communityStationID == first)
    }

    // MARK: - Identity edits

    @Test("Editing a station into a different place discards the old place's UUID")
    func identityEdit_discardsStaleUUID() {
        let saved = savedStation(communityStationID: first)
        let keyBeforeEdit = saved.communityIdentityKey

        saved.address = "9 Elm St"
        saved.city = "Dayton"
        saved.zipCode = "45402"

        #expect(saved.discardCommunityStationIDIfIdentityChanged(since: keyBeforeEdit))
        #expect(saved.communityStationID == nil)
    }

    @Test("Edits that do not change the canonical key keep the UUID")
    func nonIdentityEdit_keepsUUID() {
        let saved = savedStation(communityStationID: first)
        let keyBeforeEdit = saved.communityIdentityKey

        saved.notes = "Pump 4 is the E85 pump"
        saved.lastKnownE85Price = 3.09
        saved.isFavorite = true
        // A sufficient address makes the canonical key ignore coordinates entirely.
        saved.latitude = 39.97
        saved.longitude = -83.01

        #expect(saved.discardCommunityStationIDIfIdentityChanged(since: keyBeforeEdit) == false)
        #expect(saved.communityStationID == first)
    }

    @Test("Discarding on a station that never had a UUID is a no-op")
    func discardWithoutUUID_isNoOp() {
        let saved = savedStation()
        let keyBeforeEdit = saved.communityIdentityKey

        saved.name = "BP"

        #expect(saved.discardCommunityStationIDIfIdentityChanged(since: keyBeforeEdit) == false)
        #expect(saved.communityStationID == nil)
    }

    // MARK: - Equality semantics are untouched

    @Test("FuelStation equality stays SwiftData's instance identity — the UUID is not part of it")
    func equality_isInstanceIdentityNotFieldEquality() {
        let a = savedStation(communityStationID: first)
        let twinWithSameFieldsAndUUID = savedStation(communityStationID: first)

        #expect(a == a)
        // Two separately saved copies of the same station are still two stations: carrying the
        // same community UUID must not merge them or change how favorites/lists treat them.
        #expect(a != twinWithSameFieldsAndUUID)

        a.adoptCommunityStationID(second)
        #expect(a == a)
        #expect(a != twinWithSameFieldsAndUUID)
    }
}
