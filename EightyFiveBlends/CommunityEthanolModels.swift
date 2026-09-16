//
//  CommunityEthanolModels.swift
//  EightyFiveBlends
//
//  Community-reported ethanol percentages remain separate from community price reports while
//  reusing the same station identity and anonymous-reporting conventions.
//

import Foundation

struct CommunityEthanolReport: Decodable, Identifiable, Sendable {
    let id: UUID?
    let stationID: UUID?
    let ethanolPercentage: Double
    let reportedAt: Date
    let reporterID: String
    let notes: String?
    let createdAt: Date?

    var reportSourceLabel: String {
        "Community reported"
    }

    init(
        id: UUID?,
        stationID: UUID?,
        ethanolPercentage: Double,
        reportedAt: Date,
        reporterID: String,
        notes: String?,
        createdAt: Date?
    ) {
        self.id = id
        self.stationID = stationID
        self.ethanolPercentage = ethanolPercentage
        self.reportedAt = reportedAt
        self.reporterID = reporterID
        self.notes = notes
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case stationID = "station_id"
        case ethanolPercentage = "ethanol_percentage"
        case reportedAt = "reported_at"
        case reporterID = "reporter_id"
        case anonymousReporterID = "anonymous_reporter_id"
        case note
        case notes
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        stationID = try container.decodeIfPresent(UUID.self, forKey: .stationID)
        ethanolPercentage = try container.decode(Double.self, forKey: .ethanolPercentage)
        reportedAt = try container.decode(Date.self, forKey: .reportedAt)
        reporterID =
            try container.decodeIfPresent(String.self, forKey: .anonymousReporterID) ??
            container.decodeIfPresent(String.self, forKey: .reporterID) ??
            ""
        notes =
            try container.decodeIfPresent(String.self, forKey: .note) ??
            container.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

struct CommunityEthanolSummary: Decodable, Sendable {
    let normalizedStationKey: String
    let latestReport: CommunityEthanolReport?
    let reportCount: Int

    var latestPercentage: Double? {
        latestReport?.ethanolPercentage
    }

    var latestReportedAt: Date? {
        latestReport?.reportedAt
    }

    var latestReportedMileageLabel: String {
        "Community reported"
    }
}
