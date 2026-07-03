//
//  NRELStationService.swift
//  EightyFiveBlends
//
//  This file contains the NLRStationService implementation for the updated
//  NLR AFDC endpoint. The file name is kept for target compatibility.

import Foundation

struct NLRNearestStationsResponse: Decodable {
    let fuelStations: [NLRFuelStationResponse]

    enum CodingKeys: String, CodingKey {
        case fuelStations = "fuel_stations"
    }
}

struct NLRFuelStationResponse: Decodable {
    let stationName: String?
    let streetAddress: String?
    let city: String?
    let state: String?
    let zip: String?
    let latitude: Double?
    let longitude: Double?
    let distance: Double?
    let stationPhone: String?
    let accessDaysTime: String?
    let dateLastConfirmed: String?
    let fuelTypeCode: String?

    enum CodingKeys: String, CodingKey {
        case stationName = "station_name"
        case streetAddress = "street_address"
        case city
        case state
        case zip
        case latitude
        case longitude
        case distance
        case stationPhone = "station_phone"
        case accessDaysTime = "access_days_time"
        case dateLastConfirmed = "date_last_confirmed"
        case fuelTypeCode = "fuel_type_code"
    }
}

struct LiveFuelStation: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    let city: String
    let state: String
    let zip: String
    let latitude: Double
    let longitude: Double
    let distanceMiles: Double
    let phone: String
    let accessHours: String
    let dateLastConfirmed: String
    let fuelTypeCode: String

    init(from station: NLRFuelStationResponse) {
        name = station.stationName?.nilIfBlank ?? "Unknown Station"
        address = station.streetAddress?.nilIfBlank ?? ""
        city = station.city?.nilIfBlank ?? ""
        state = station.state?.nilIfBlank ?? ""
        zip = station.zip?.nilIfBlank ?? ""
        latitude = station.latitude ?? 0
        longitude = station.longitude ?? 0
        distanceMiles = station.distance ?? 0
        phone = station.stationPhone?.nilIfBlank ?? ""
        accessHours = station.accessDaysTime?.nilIfBlank ?? ""
        dateLastConfirmed = station.dateLastConfirmed?.nilIfBlank ?? ""
        fuelTypeCode = station.fuelTypeCode?.nilIfBlank ?? ""
    }

    /// Direct field init for constructing synthetic stations — used by RouteE85PlannerTests
    /// to exercise the greedy stop planner without a live NLR station search.
    init(
        name: String,
        address: String = "",
        city: String = "",
        state: String = "",
        zip: String = "",
        latitude: Double,
        longitude: Double,
        distanceMiles: Double = 0,
        phone: String = "",
        accessHours: String = "",
        dateLastConfirmed: String = "",
        fuelTypeCode: String = "E85"
    ) {
        self.name = name
        self.address = address
        self.city = city
        self.state = state
        self.zip = zip
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMiles = distanceMiles
        self.phone = phone
        self.accessHours = accessHours
        self.dateLastConfirmed = dateLastConfirmed
        self.fuelTypeCode = fuelTypeCode
    }
}

enum NLRServiceError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidURL
    case requestFailed(statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "NLR API key not found. Add NLR_API_KEY to Info.plist."
        case .invalidURL:
            return "Could not build a valid NLR API request URL."
        case .requestFailed(let statusCode):
            return "NLR API request failed with status \(statusCode)."
        case .invalidResponse:
            return "NLR API returned an invalid response."
        }
    }
}

// MARK: - Key Safety Notes
//
// NLR_API_KEY is a public developer API key for the AFDC (Alternative Fuels Data Center)
// nearest-stations endpoint. These keys are issued free at developer.nlr.gov and are
// explicitly designed for client-side distribution — rate-limited per key, not per user.
// Embedding it in the app binary is the standard and expected usage pattern.
//
// The key is sent as a URL query parameter (?api_key=…), which is how the AFDC API
// requires it. This is visible in network logs but is not a secret.

struct NLRStationService {
    private static let baseURL = "https://developer.nlr.gov/api/alt-fuel-stations/v1/nearest.json"
    private static let defaultTimeoutInterval: TimeInterval = 18

    private let session: URLSession

    init(session: URLSession = NLRStationService.defaultSession) {
        self.session = session
    }

    static var defaultSession: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = defaultTimeoutInterval
        configuration.timeoutIntervalForResource = defaultTimeoutInterval
        return URLSession(configuration: configuration)
    }

    func fetchNearbyE85Stations(
        latitude: Double,
        longitude: Double,
        radius: Double,
        limit: Int
    ) async throws -> [LiveFuelStation] {
        let apiKey = try Self.apiKey()
        let request = try Self.makeRequest(
            apiKey: apiKey,
            latitude: latitude,
            longitude: longitude,
            radius: radius,
            limit: limit
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NLRServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NLRServiceError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let decodedResponse = try JSONDecoder().decode(NLRNearestStationsResponse.self, from: data)
        return decodedResponse.fuelStations.map(LiveFuelStation.init(from:))
    }

    private static func apiKey() throws -> String {
        guard
            let rawKey = Bundle.main.object(forInfoDictionaryKey: "NLR_API_KEY") as? String,
            let apiKey = rawKey.nilIfBlank
        else {
            throw NLRServiceError.missingAPIKey
        }

        return apiKey
    }

    private static func makeRequest(
        apiKey: String,
        latitude: Double,
        longitude: Double,
        radius: Double,
        limit: Int
    ) throws -> URLRequest {
        var components = URLComponents(string: baseURL)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "fuel_type", value: "E85"),
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "radius", value: String(radius)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "status", value: "E"),
            URLQueryItem(name: "access", value: "public")
        ]

        guard let url = components?.url else {
            throw NLRServiceError.invalidURL
        }

        return URLRequest(url: url, timeoutInterval: defaultTimeoutInterval)
    }
}

typealias NRELServiceError = NLRServiceError

struct NRELStationService {
    private let service: NLRStationService

    init(session: URLSession = NLRStationService.defaultSession) {
        service = NLRStationService(session: session)
    }

    func fetchNearbyE85Stations(
        latitude: Double,
        longitude: Double,
        radius: Double = 25,
        limit: Int = 20
    ) async throws -> [LiveFuelStation] {
        try await service.fetchNearbyE85Stations(
            latitude: latitude,
            longitude: longitude,
            radius: radius,
            limit: limit
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
