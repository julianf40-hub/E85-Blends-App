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

/// 2.4.1 (Phase 3C): `nonisolated` so the pure per-method breakdown (CommunityPriceBreakdown) can read it off the
/// main actor. A plain value type; nothing about how it is created or decoded changes.
nonisolated struct CommunityPriceReport: Decodable, Identifiable, Sendable {
    let id: UUID?
    let stationID: UUID?
    let normalizedStationKey: String
    let price: Double
    let reportedAt: Date
    let reporterID: String
    let notes: String?
    let createdAt: Date?
    /// Which price this report is (cash / credit / same for both). `.unknown` for every report made before payment
    /// types existed and for any older app's report: it is NEVER inferred. Decoded leniently - a missing, null or
    /// unrecognised value reads as `.unknown` and does not throw.
    let paymentType: CommunityPaymentType

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
        createdAt: Date?,
        paymentType: CommunityPaymentType = .unknown
    ) {
        self.id = id
        self.stationID = stationID
        self.normalizedStationKey = normalizedStationKey
        self.price = price
        self.reportedAt = reportedAt
        self.reporterID = reporterID
        self.notes = notes
        self.createdAt = createdAt
        self.paymentType = paymentType
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case stationID = "station_id"
        case normalizedKey = "normalized_key"
        case paymentType = "payment_type"
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
        paymentType = (try container.decodeIfPresent(CommunityPaymentType.self, forKey: .paymentType)) ?? .unknown
    }
}

nonisolated struct CommunityPriceSummary: Decodable, Sendable {
    let normalizedStationKey: String
    /// The newest report of ANY payment type - what this app has always called "the" community price, kept with
    /// its original meaning (and the source of `communityStationID`). Anything that prints a price per payment
    /// method uses `breakdown` instead.
    let latestReport: CommunityPriceReport?
    let reportCount: Int
    /// The station's newest reports (any kind), newest first, as fetched. Empty for a summary built from a single
    /// `latestReport`, in which case `breakdown` is built from that one report.
    let recentReports: [CommunityPriceReport]

    init(
        normalizedStationKey: String,
        latestReport: CommunityPriceReport?,
        reportCount: Int,
        recentReports: [CommunityPriceReport] = []
    ) {
        self.normalizedStationKey = normalizedStationKey
        self.latestReport = latestReport
        self.reportCount = reportCount
        self.recentReports = recentReports
    }

    /// The per-method reading of this station's reports: the Cash price, the Credit price, an unclassified one.
    var breakdown: CommunityPriceBreakdown {
        CommunityPriceBreakdown(reports: recentReports.isEmpty ? (latestReport.map { [$0] } ?? []) : recentReports)
    }

    var latestPrice: Double? {
        latestReport?.price
    }

    var latestReportedAt: Date? {
        latestReport?.reportedAt
    }

    /// The backend's stable station identifier (`community_stations.id`), as carried by the latest
    /// report's `station_id`. `nil` means "not known from this summary" — never "this station has
    /// no community row". See CommunityStationIdentity.
    var communityStationID: UUID? {
        latestReport?.stationID
    }

    var latestReportedMileageLabel: String {
        "Community reported"
    }
}
