//
//  PendingPriceContributionCodableTests.swift
//  EightyFiveBlendsTests
//
//  Tests for PendingPriceContribution's own hand-written Codable conformance (see that file's
//  "Explicit Codable conformance" extension) — specifically the backward-compatibility behavior
//  of e85Evidence: a pre-fix blob's JSON (no "e85Evidence" key at all) must decode successfully
//  with that field nil via an explicit `decodeIfPresent` call, and a newly-encoded contribution
//  carrying either evidence case must round-trip back to that exact case. These exercise
//  JSONEncoder/JSONDecoder directly against the struct's own Codable conformance, independent of
//  PendingPriceContributionStore — see PendingPriceContributionStoreTests.swift for the
//  store-level "no evidence -> discarded" gate this Codable behavior enables.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct PendingPriceContributionCodableTests {
    private func makeContribution(e85Evidence: PendingPriceContributionE85Evidence?) -> PendingPriceContribution {
        PendingPriceContribution(
            stationKey: "circlek|123 main st|phoenix|az|85001",
            stationName: "Circle K",
            streetAddress: "123 Main St",
            city: "Phoenix",
            state: "AZ",
            zip: "85001",
            latitude: 33.45,
            longitude: -112.07,
            directionsOpenedAt: Date(timeIntervalSince1970: 1_800_000_000),
            mapsProvider: "Apple Maps",
            e85Evidence: e85Evidence
        )
    }

    // MARK: - 1. Legacy JSON (no e85Evidence key at all) decodes to nil

    @Test("Legacy JSON with no e85Evidence key at all decodes successfully with e85Evidence nil")
    func decode_legacyJSONMissingEvidenceKey_decodesToNilEvidence() throws {
        let legacyJSON = """
        {
            "stationKey": "circlek|123 main st|phoenix|az|85001",
            "stationName": "Circle K",
            "streetAddress": "123 Main St",
            "city": "Phoenix",
            "state": "AZ",
            "zip": "85001",
            "latitude": 33.45,
            "longitude": -112.07,
            "directionsOpenedAt": 0.0,
            "mapsProvider": "Apple Maps"
        }
        """
        let decoded = try JSONDecoder().decode(PendingPriceContribution.self, from: Data(legacyJSON.utf8))

        #expect(decoded.e85Evidence == nil)
        #expect(decoded.stationName == "Circle K")
    }

    @Test("A minimal legacy JSON (only the required fields that existed before this fix) still decodes with e85Evidence nil")
    func decode_minimalLegacyJSON_decodesToNilEvidence() throws {
        let legacyJSON = """
        {
            "stationKey": "circlek|123 main st|phoenix|az|85001",
            "stationName": "Circle K",
            "directionsOpenedAt": 0.0
        }
        """
        let decoded = try JSONDecoder().decode(PendingPriceContribution.self, from: Data(legacyJSON.utf8))

        #expect(decoded.e85Evidence == nil)
        #expect(decoded.streetAddress == nil)
        #expect(decoded.mapsProvider == nil)
    }

    @Test("An explicit JSON null for e85Evidence decodes the same as a missing key — nil")
    func decode_explicitNullEvidence_decodesToNilEvidence() throws {
        let json = """
        {
            "stationKey": "circlek|123 main st|phoenix|az|85001",
            "stationName": "Circle K",
            "directionsOpenedAt": 0.0,
            "e85Evidence": null
        }
        """
        let decoded = try JSONDecoder().decode(PendingPriceContribution.self, from: Data(json.utf8))

        #expect(decoded.e85Evidence == nil)
    }

    // MARK: - 2 & 3. New evidence values round-trip through encode/decode unchanged

    @Test("A newly-encoded .liveNRELSearch contribution round-trips back as .liveNRELSearch")
    func encodeDecodeRoundTrip_liveNRELSearch_preservesEvidence() throws {
        let original = makeContribution(e85Evidence: .liveNRELSearch)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingPriceContribution.self, from: data)

        #expect(decoded.e85Evidence == .liveNRELSearch)
        #expect(decoded == original)
    }

    @Test("A newly-encoded .nearbyE85Widget contribution round-trips back as .nearbyE85Widget")
    func encodeDecodeRoundTrip_nearbyE85Widget_preservesEvidence() throws {
        let original = makeContribution(e85Evidence: .nearbyE85Widget)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingPriceContribution.self, from: data)

        #expect(decoded.e85Evidence == .nearbyE85Widget)
        #expect(decoded == original)
    }

    @Test("A newly-encoded contribution with nil evidence round-trips back as nil, not some other default")
    func encodeDecodeRoundTrip_nilEvidence_preservesNil() throws {
        let original = makeContribution(e85Evidence: nil)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingPriceContribution.self, from: data)

        #expect(decoded.e85Evidence == nil)
        #expect(decoded == original)
    }

    @Test("Encoding a raw JSON string confirms the wire value is the raw case name, not some other encoding")
    func encode_liveNRELSearch_producesTheExpectedRawStringInJSON() throws {
        let original = makeContribution(e85Evidence: .liveNRELSearch)

        let data = try JSONEncoder().encode(original)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["e85Evidence"] as? String == "liveNRELSearch")
    }

    // MARK: - Every other field still survives the hand-written Codable round trip unchanged

    @Test("Every scalar field survives the hand-written Codable round trip unchanged, not just e85Evidence")
    func encodeDecodeRoundTrip_everyFieldSurvives() throws {
        let original = makeContribution(e85Evidence: .liveNRELSearch)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingPriceContribution.self, from: data)

        #expect(decoded.stationKey == original.stationKey)
        #expect(decoded.stationName == original.stationName)
        #expect(decoded.streetAddress == original.streetAddress)
        #expect(decoded.city == original.city)
        #expect(decoded.state == original.state)
        #expect(decoded.zip == original.zip)
        #expect(decoded.latitude == original.latitude)
        #expect(decoded.longitude == original.longitude)
        #expect(decoded.directionsOpenedAt == original.directionsOpenedAt)
        #expect(decoded.mapsProvider == original.mapsProvider)
    }

    @Test("A corrupt/unrecognized e85Evidence string fails to decode the whole payload, never silently substitutes nil")
    func decode_unrecognizedEvidenceString_throwsRatherThanSilentlyDefaulting() {
        let json = """
        {
            "stationKey": "circlek|123 main st|phoenix|az|85001",
            "stationName": "Circle K",
            "directionsOpenedAt": 0.0,
            "e85Evidence": "someFutureCaseThisBuildDoesNotKnowAbout"
        }
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PendingPriceContribution.self, from: Data(json.utf8))
        }
    }
}
