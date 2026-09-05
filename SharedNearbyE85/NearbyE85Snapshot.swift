import Foundation

// Value-only boundary: the extension never opens SwiftData, CloudKit, or the network.
nonisolated enum NearbyE85Configuration {
    static let kind = "NearbyE85"
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "NearbyE85AppGroup") as? String
    }
    static var urlScheme: String {
        Bundle.main.object(forInfoDictionaryKey: "NearbyE85URLScheme") as? String ?? "e85blends"
    }
}

nonisolated struct NearbyE85Price: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case saved, community }
    let dollarsPerGallon: Double
    let reportedAt: Date?
    let source: Source

    static func validated(_ amount: Double?, reportedAt: Date?, source: Source, now: Date) -> Self? {
        guard let amount, StationDataValidation.isValidPrice(amount) else { return nil }
        return Self(dollarsPerGallon: amount,
                    reportedAt: reportedAt.flatMap { StationDataValidation.isValidTimestamp($0, asOf: now) ? $0 : nil },
                    source: source)
    }

    func status(at date: Date) -> String {
        guard let reportedAt else { return "Age unknown" }
        let days = StationDataValidation.daysSince(reportedAt, asOf: date)
        switch StationDataValidation.priceFreshnessTier(hasPrice: true, daysSinceUpdate: days) {
        case .stale: return "Stale · \(days)d ago"
        case .checkPrice: return "Check price · \(days)d ago"
        case .fresh: return days == 0 ? "Reported today" : "Reported \(days)d ago"
        case .noPrice: return "No price reported"
        }
    }
}

nonisolated struct NearbyE85Station: Codable, Equatable, Identifiable, Sendable {
    let id: String // Existing canonical community station key, never LiveFuelStation's random UUID.
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let distanceMiles: Double
    var price: NearbyE85Price?
}

nonisolated struct NearbyE85Snapshot: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case ready, noStations, permissionRequired }
    static let schemaVersion = 1
    static let staleAfter: TimeInterval = 60 * 60
    static let expiresAfter: TimeInterval = 24 * 60 * 60
    let version: Int
    let state: State
    let stations: [NearbyE85Station]
    let radiusMiles: Double
    let updatedAt: Date // Successful station search time; reading/enriching the cache never advances it.
    let locationAt: Date?

    static func make(stations: [NearbyE85Station], radiusMiles: Double, updatedAt: Date, locationAt: Date) -> Self {
        var seen = Set<String>()
        let nearest = stations.filter {
            !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            StationDataValidation.isValidCoordinate(latitude: $0.latitude, longitude: $0.longitude) &&
            $0.distanceMiles.isFinite && $0.distanceMiles >= 0 && $0.distanceMiles <= radiusMiles
        }.sorted {
            $0.distanceMiles == $1.distanceMiles ? $0.id < $1.id : $0.distanceMiles < $1.distanceMiles
        }.filter { seen.insert($0.id).inserted }.prefix(3)
        return Self(version: schemaVersion, state: nearest.isEmpty ? .noStations : .ready,
                    stations: Array(nearest), radiusMiles: radiusMiles, updatedAt: updatedAt, locationAt: locationAt)
    }

    static func permissionRequired(at date: Date) -> Self {
        Self(version: schemaVersion, state: .permissionRequired, stations: [], radiusMiles: 25, updatedAt: date, locationAt: nil)
    }

    func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(locationAt ?? updatedAt) >= Self.staleAfter || date.timeIntervalSince(updatedAt) >= Self.staleAfter
    }

    func isValid(at date: Date) -> Bool {
        guard version == Self.schemaVersion,
              StationDataValidation.isValidTimestamp(updatedAt, asOf: date),
              radiusMiles.isFinite, radiusMiles > 0, radiusMiles <= 100,
              stations.count <= 3,
              Set(stations.map(\.id)).count == stations.count else { return false }
        if state == .permissionRequired { return stations.isEmpty && locationAt == nil }
        guard let locationAt, StationDataValidation.isValidTimestamp(locationAt, asOf: date),
              date.timeIntervalSince(locationAt) < Self.expiresAfter,
              date.timeIntervalSince(updatedAt) < Self.expiresAfter,
              (state == .ready) == !stations.isEmpty else { return false }
        return stations.allSatisfy { station in
            !station.id.isEmpty && station.id.count <= 1024 && !station.name.isEmpty && station.name.count <= 256 &&
            station.address.count <= 1024 &&
            StationDataValidation.isValidCoordinate(latitude: station.latitude, longitude: station.longitude) &&
            station.distanceMiles.isFinite && station.distanceMiles >= 0 && station.distanceMiles <= radiusMiles &&
            (station.price.map { price in
                StationDataValidation.isValidPrice(price.dollarsPerGallon) &&
                (price.reportedAt.map { StationDataValidation.isValidTimestamp($0, asOf: date) } ?? true)
            } ?? true)
        }
    }
}

nonisolated struct NearbyE85Cache {
    let fileURL: URL?
    init(fileURL: URL?) { self.fileURL = fileURL }
    init() {
        fileURL = NearbyE85Configuration.appGroup.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }?.appendingPathComponent("NearbyE85/snapshot-v1.json")
    }

    func read(now: Date = .now) -> NearbyE85Snapshot? {
        guard let fileURL,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(NearbyE85Snapshot.self, from: data),
              value.isValid(at: now) else { return nil }
        return value
    }

    // App is the sole writer. No private-container fallback: missing entitlements must never
    // look like successful sharing. Atomic replacement gives concurrent readers whole snapshots.
    @discardableResult
    func write(_ snapshot: NearbyE85Snapshot, now: Date = .now) throws -> Bool {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        guard snapshot.isValid(at: now) else { throw CocoaError(.fileWriteInvalidFileName) }
        if read(now: now) == snapshot { return false }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 65_536 else { throw CocoaError(.fileWriteOutOfSpace) }
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }
}

nonisolated enum NearbyE85DeepLink {
    enum Destination: Equatable { case nearby, station(String) }
    static func url(stationID: String? = nil, scheme: String = NearbyE85Configuration.urlScheme) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "nearby"
        if let stationID { parts.queryItems = [URLQueryItem(name: "station", value: stationID)] }
        return parts.url!
    }
    static func parse(_ url: URL, scheme: String = NearbyE85Configuration.urlScheme) -> Destination? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == scheme, parts.host == "nearby", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        let items = parts.queryItems ?? []
        if items.isEmpty { return .nearby }
        guard items.count == 1, items[0].name == "station", let id = items[0].value,
              !id.isEmpty, id.count <= 1024 else { return nil }
        return .station(id)
    }
}
