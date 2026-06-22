//
//  StationReportStore.swift
//  EightyFiveBlends
//
//  Local-only station availability reports for the Trip Planner.
//  Reports are stored in UserDefaults — no server or community sync yet.
//  TODO: Add community / cloud reporting in a future version.
//

import Foundation

enum StationReportType: String, Codable, CaseIterable {
    case e85Confirmed       = "E85 Confirmed"
    case e85Unavailable     = "E85 Unavailable"
    case pumpOffline        = "Pump Offline"
    case priceUpdated       = "Price Updated"   // TODO: wire up price input in a future pass
    case stationOpen        = "Station Open"
    case stationUnavailable = "Station Unavailable"

    var isNegative: Bool {
        switch self {
        case .e85Unavailable, .pumpOffline, .stationUnavailable: return true
        default: return false
        }
    }
}

enum StationReportStationType: String, Codable {
    case e85
    case backupGas
}

struct StationReport: Codable, Identifiable {
    let id: UUID
    let stationKey: String
    let stationName: String
    let stationType: StationReportStationType
    let reportType: StationReportType
    let timestamp: Date
}

@Observable
final class StationReportStore {
    static let shared = StationReportStore()

    private static let defaultsKey   = "stationReports_v1"
    private static let recentDays    = 14
    private static let maxReports    = 500

    private(set) var reports: [StationReport] = []

    private init() { load() }

    func add(_ report: StationReport) {
        reports.insert(report, at: 0)
        if reports.count > Self.maxReports {
            reports = Array(reports.prefix(Self.maxReports))
        }
        persist()
    }

    func hasRecentNegativeReport(for stationKey: String) -> Bool {
        reports.contains { $0.stationKey == stationKey && $0.reportType.isNegative && isRecent($0.timestamp) }
    }

    /// Keys with at least one recent negative report — captured by the route planner to
    /// deprioritize reported-unavailable stations when alternatives exist.
    var recentNegativeKeys: Set<String> {
        Set(reports.filter { $0.reportType.isNegative && isRecent($0.timestamp) }.map { $0.stationKey })
    }

    // MARK: - Private

    private func isRecent(_ date: Date) -> Bool {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.recentDays, to: Date()) else { return false }
        return date > cutoff
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([StationReport].self, from: data) else { return }
        reports = decoded
    }
}
