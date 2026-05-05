//
//  CommunityPriceModels.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation

struct CommunityStation: Decodable, Identifiable, Sendable {
    let id: UUID?
    let normalizedStationKey: String
    let name: String
    let streetAddress: String?
    let city: String?
    let state: String?
    let zip: String?
    let latitude: Double?
    let longitude: Double?
    let createdAt: Date?
    let updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case normalizedStationKey = "normalized_station_key"
        case normalizedKey = "normalized_key"
        case name
        case address
        case streetAddress = "street_address"
        case city
        case state
        case zip
        case latitude
        case longitude
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        normalizedStationKey =
            try container.decodeIfPresent(String.self, forKey: .normalizedKey) ??
            container.decodeIfPresent(String.self, forKey: .normalizedStationKey) ??
            ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        streetAddress =
            try container.decodeIfPresent(String.self, forKey: .address) ??
            container.decodeIfPresent(String.self, forKey: .streetAddress)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        zip = try container.decodeIfPresent(String.self, forKey: .zip)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct CommunityPriceReport: Decodable, Identifiable, Sendable {
    let id: UUID?
    let stationID: UUID?
    let normalizedStationKey: String
    let price: Double
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
        normalizedStationKey: String,
        price: Double,
        reportedAt: Date,
        reporterID: String,
        notes: String?,
        createdAt: Date?
    ) {
        self.id = id
        self.stationID = stationID
        self.normalizedStationKey = normalizedStationKey
        self.price = price
        self.reportedAt = reportedAt
        self.reporterID = reporterID
        self.notes = notes
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case stationID = "station_id"
        case normalizedKey = "normalized_key"
        case price
        case reportedAt = "reported_at"
        case reporterID = "reporter_id"
        case anonymousReporterID = "anonymous_reporter_id"
        case note
        case notes
        case createdAt = "created_at"
        case appVersion = "app_version"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        stationID = try container.decodeIfPresent(UUID.self, forKey: .stationID)
        normalizedStationKey =
            try container.decodeIfPresent(String.self, forKey: .normalizedKey) ??
            ""
        price = try container.decode(Double.self, forKey: .price)
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

struct CommunityPriceSummary: Decodable, Sendable {
    let normalizedStationKey: String
    let latestReport: CommunityPriceReport?
    let reportCount: Int

    var latestPrice: Double? {
        latestReport?.price
    }

    var latestReportedAt: Date? {
        latestReport?.reportedAt
    }

    var latestReportedMileageLabel: String {
        "Community reported"
    }
}
