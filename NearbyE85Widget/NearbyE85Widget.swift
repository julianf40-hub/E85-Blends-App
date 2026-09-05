import SwiftUI
import WidgetKit
import CoreLocation

nonisolated struct NearbyE85Provider: TimelineProvider {
    func placeholder(in context: Context) -> NearbyE85Entry {
        .init(date: .now, snapshot: Self.example)
    }
    func getSnapshot(in context: Context, completion: @escaping (NearbyE85Entry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { @MainActor in completion(.init(date: .now, snapshot: readAuthorizedSnapshot())) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NearbyE85Entry>) -> Void) {
        Task { @MainActor in
            let now = Date.now
            let snapshot = readAuthorizedSnapshot()
            // Schedule the stale and expiry states up front: budgeted reloads are not timers.
            var dates = [now, now.addingTimeInterval(30 * 60)]
            if let snapshot, snapshot.state != .permissionRequired {
                let oldest = min(snapshot.locationAt ?? snapshot.updatedAt, snapshot.updatedAt)
                dates += [oldest.addingTimeInterval(NearbyE85Snapshot.staleAfter),
                          oldest.addingTimeInterval(NearbyE85Snapshot.expiresAfter)]
                // Price tiers change by calendar day, using the same rules as the app.
                if let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0), matchingPolicy: .nextTime) {
                    dates.append(midnight)
                }
            }
            let entries = Array(Set(dates)).filter { $0 >= now }.sorted().map { date in
                NearbyE85Entry(date: date, snapshot: snapshot.flatMap { $0.isValid(at: date) ? $0 : nil })
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
        }
    }
    @MainActor private func readAuthorizedSnapshot() -> NearbyE85Snapshot? {
        // Permission is checked again in the extension; it never requests a location or
        // claims to track travel while the app is closed. Denied access hides cached data.
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            return .permissionRequired(at: .now)
        }
        return NearbyE85Cache().read()
    }
    static var example: NearbyE85Snapshot {
        .make(stations: [.init(id: "example", name: "Nearby E85 station", address: "Example address",
                              latitude: 33.45, longitude: -112.07, distanceMiles: 1.2,
                              price: .init(dollarsPerGallon: 2.89, reportedAt: .now, source: .community))],
              radiusMiles: 25, updatedAt: .now, locationAt: .now)
    }
}

@main
struct NearbyE85Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NearbyE85Configuration.kind, provider: NearbyE85Provider()) { entry in
            NearbyE85WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Nearby E85")
        .description("E85 stations and reported prices near your last location in 85Blends. Open the app to refresh.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    NearbyE85Widget()
} timeline: {
    NearbyE85Entry(date: .now, snapshot: NearbyE85Provider.example)
    NearbyE85Entry(date: .now, snapshot: nil)
    NearbyE85Entry(date: .now, snapshot: .permissionRequired(at: .now))
}

#Preview(as: .systemMedium) {
    NearbyE85Widget()
} timeline: {
    NearbyE85Entry(date: .now, snapshot: NearbyE85Provider.example)
}
