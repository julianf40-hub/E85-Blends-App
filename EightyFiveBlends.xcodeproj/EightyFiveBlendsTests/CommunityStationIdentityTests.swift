//
//  CommunityStationIdentityTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts iOS foundation — the pure rules for the backend's stable community-station UUID
//  (CommunityStationIdentity) and the DTO layer that carries it from a Supabase response to the
//  views (CommunityStation / CommunityPriceSummary / CommunityEthanolSummary). Everything here is
//  pure Foundation, so it needs no SwiftData container. The SwiftData half —
//  FuelStation.communityStationID and its adopt/discard methods — is in
//  FuelStationCommunityIdentityTests.swift.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct CommunityStationIdentityTests {
    private let first = UUID(uuidString: "738574C5-E64F-40D8-AD6D-21025B412505")!
    private let second = UUID(uuidString: "BE3216DD-23BB-41C1-AB00-1E6920A4BCF3")!

    // MARK: - resolved(existing:incoming:)

    @Test("A UUID learned from the backend is adopted when the station had none")
    func resolved_adoptsIncomingWhenNoneStored() {
        #expect(CommunityStationIdentity.resolved(existing: nil, incoming: first) == first)
    }

    @Test("With no UUID from the backend and none stored, nothing is fabricated")
    func resolved_neverFabricates() {
        #expect(CommunityStationIdentity.resolved(existing: nil, incoming: nil) == nil)
    }

    @Test("A response without a UUID never erases a stored one")
    func resolved_nilIncomingKeepsExisting() {
        #expect(CommunityStationIdentity.resolved(existing: first, incoming: nil) == first)
    }

    @Test("A different UUID from the backend replaces a stale stored one")
    func resolved_incomingReplacesStale() {
        #expect(CommunityStationIdentity.resolved(existing: first, incoming: second) == second)
    }

    @Test("Re-delivering the stored UUID is a no-op")
    func resolved_sameValueIsUnchanged() {
        // The caller's change-detection contract (`resolved != existing`): nothing to write.
        #expect(CommunityStationIdentity.resolved(existing: first, incoming: first) == first)
    }

    // MARK: - retainsID(previousKey:currentKey:)

    @Test("An unchanged canonical key keeps the stored UUID")
    func retainsID_equalKeys() {
        #expect(CommunityStationIdentity.retainsID(previousKey: "shell|1 main st|columbus|oh|43215", currentKey: "shell|1 main st|columbus|oh|43215"))
    }

    @Test("A changed canonical key discards the stored UUID")
    func retainsID_changedKey() {
        #expect(CommunityStationIdentity.retainsID(previousKey: "shell|1 main st|columbus|oh|43215", currentKey: "shell|9 elm st|dayton|oh|45402") == false)
    }

    @Test("A station that gains or loses a derivable key does not keep a UUID")
    func retainsID_keyAppearsOrDisappears() {
        #expect(CommunityStationIdentity.retainsID(previousKey: nil, currentKey: "shell|1 main st|columbus|oh|43215") == false)
        #expect(CommunityStationIdentity.retainsID(previousKey: "shell|1 main st|columbus|oh|43215", currentKey: nil) == false)
    }

    @Test("A station with no derivable key before or after is unchanged")
    func retainsID_bothNil() {
        #expect(CommunityStationIdentity.retainsID(previousKey: nil, currentKey: nil))
    }

    // MARK: - DTO layer: the UUID survives decoding and reaches the summaries views hold

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func priceReportJSON(stationID: String?) -> Data {
        let stationLine = stationID.map { "\"station_id\": \"\($0)\"," } ?? ""
        return Data(
            """
            {
              \(stationLine)
              "price": 3.19,
              "reported_at": "2026-10-05T12:00:00Z",
              "anonymous_reporter_id": "anonymous-device-id"
            }
            """.utf8
        )
    }

    @Test("A decoded price report's station_id is the community UUID its summary exposes")
    func summary_exposesStationIDDecodedFromJSON() throws {
        let report = try decoder().decode(CommunityPriceReport.self, from: priceReportJSON(stationID: first.uuidString))
        let summary = CommunityPriceSummary(normalizedStationKey: "key", latestReport: report, reportCount: 1)

        #expect(report.stationID == first)
        #expect(summary.communityStationID == first)
    }

    @Test("A price report with no station_id yields no UUID, never a fabricated one")
    func summary_missingStationIDIsNil() throws {
        let report = try decoder().decode(CommunityPriceReport.self, from: priceReportJSON(stationID: nil))
        let summary = CommunityPriceSummary(normalizedStationKey: "key", latestReport: report, reportCount: 1)

        #expect(report.stationID == nil)
        #expect(summary.communityStationID == nil)
    }

    @Test("A summary with no latest report has no community UUID")
    func summary_noReportMeansUnknown() {
        let summary = CommunityPriceSummary(normalizedStationKey: "key", latestReport: nil, reportCount: 0)
        #expect(summary.communityStationID == nil)
    }

    @Test("An ethanol summary exposes the UUID of its latest report too")
    func ethanolSummary_exposesStationID() throws {
        let data = Data(
            """
            {
              "station_id": "\(second.uuidString)",
              "ethanol_percentage": 78.5,
              "reported_at": "2026-10-05T12:00:00Z"
            }
            """.utf8
        )
        let report = try decoder().decode(CommunityEthanolReport.self, from: data)
        let summary = CommunityEthanolSummary(normalizedStationKey: "key", latestReport: report, reportCount: 1)
        let empty = CommunityEthanolSummary(normalizedStationKey: "key", latestReport: nil, reportCount: 0)

        #expect(summary.communityStationID == second)
        #expect(empty.communityStationID == nil)
    }

    @Test("A community station row decodes its UUID and keeps it distinct from its normalized key")
    func communityStation_decodesRowID() throws {
        let data = Data(
            """
            {
              "id": "\(first.uuidString)",
              "normalized_key": "shell|1 main st|columbus|oh|43215",
              "name": "Shell",
              "address": "1 Main St"
            }
            """.utf8
        )
        let station = try decoder().decode(CommunityStation.self, from: data)

        #expect(station.id == first)
        #expect(station.normalizedStationKey == "shell|1 main st|columbus|oh|43215")
        #expect(station.id?.uuidString.lowercased() != station.normalizedStationKey)
    }

    @Test("A community station row without an id stays nil rather than inventing one")
    func communityStation_missingIDStaysNil() throws {
        let data = Data(#"{"normalized_key": "k", "name": "Shell"}"#.utf8)
        let station = try decoder().decode(CommunityStation.self, from: data)
        #expect(station.id == nil)
    }
}
