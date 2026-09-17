//
//  CommunityEthanolModelsTests.swift
//  EightyFiveBlendsTests
//


import Foundation
import Testing
@testable import EightyFiveBlends

struct CommunityEthanolModelsTests {
    @Test("An ethanol report decodes the PostgREST response shape")
    func report_decodesPostgRESTShape() throws {
        let reportID = UUID(uuidString: "BE3216DD-23BB-41C1-AB00-1E6920A4BCF3")!
        let stationID = UUID(uuidString: "738574C5-E64F-40D8-AD6D-21025B412505")!
        let data = Data(
            """
            {
              "id": "\(reportID.uuidString)",
              "station_id": "\(stationID.uuidString)",
              "ethanol_percentage": 78.5,
              "reported_at": "2026-09-16T07:00:00Z",
              "anonymous_reporter_id": "anonymous-device-id",
              "note": "Pump sticker",
              "created_at": "2026-09-16T07:00:01Z"
            }
            """.utf8
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(CommunityEthanolReport.self, from: data)

        #expect(report.id == reportID)
        #expect(report.stationID == stationID)
        #expect(report.ethanolPercentage == 78.5)
        #expect(report.reporterID == "anonymous-device-id")
        #expect(report.notes == "Pump sticker")
        #expect(report.reportedAt == ISO8601DateFormatter().date(from: "2026-09-16T07:00:00Z"))
        #expect(report.createdAt == ISO8601DateFormatter().date(from: "2026-09-16T07:00:01Z"))
        #expect(report.reportSourceLabel == "Community reported")
    }

    @Test("Legacy reporter and notes aliases remain decodable")
    func report_decodesCompatibilityAliases() throws {
        let data = Data(
            """
            {
              "ethanol_percentage": 70,
              "reported_at": "2026-09-16T07:00:00Z",
              "reporter_id": "legacy-reporter-id",
              "notes": "Legacy note"
            }
            """.utf8
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(CommunityEthanolReport.self, from: data)

        #expect(report.reporterID == "legacy-reporter-id")
        #expect(report.notes == "Legacy note")
    }

    @Test("An ethanol summary exposes the latest value and timestamp")
    func summary_exposesLatestReportValues() {
        let reportedAt = Date(timeIntervalSince1970: 1_789_560_000)
        let report = CommunityEthanolReport(
            id: nil,
            stationID: nil,
            ethanolPercentage: 83.1,
            reportedAt: reportedAt,
            reporterID: "anonymous-device-id",
            notes: nil,
            createdAt: nil
        )
        let summary = CommunityEthanolSummary(
            normalizedStationKey: "station-key",
            latestReport: report,
            reportCount: 1
        )

        #expect(summary.latestPercentage == 83.1)
        #expect(summary.latestReportedAt == reportedAt)
        #expect(summary.latestReportedMileageLabel == "Community reported")
    }
}
