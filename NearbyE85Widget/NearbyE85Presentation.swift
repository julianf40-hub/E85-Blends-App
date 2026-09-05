import SwiftUI
import WidgetKit
#if NEARBY_WIDGET_TESTING
@testable import EightyFiveBlends
#endif

nonisolated struct NearbyE85Entry: TimelineEntry {
    let date: Date
    let snapshot: NearbyE85Snapshot?
}

struct NearbyE85WidgetView: View {
    let entry: NearbyE85Entry
    let family: WidgetFamily

    var body: some View {
        content
            .containerBackground(.background, for: .widget)
            .widgetURL(NearbyE85DeepLink.url(stationID: entry.snapshot?.stations.first?.id))
            .privacySensitive()
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Nearby E85", systemImage: "fuelpump.fill")
                .font(.caption.weight(.bold)).foregroundStyle(.green)
            if let snapshot = entry.snapshot, snapshot.state == .ready, let first = snapshot.stations.first {
                if family == .systemSmall {
                    station(first, compact: false)
                } else {
                    ForEach(Array(snapshot.stations.prefix(2))) { item in
                        Link(destination: NearbyE85DeepLink.url(stationID: item.id)) {
                            station(item, compact: true)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
                footer(snapshot)
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func station(_ station: NearbyE85Station, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(station.name).font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(compact ? 1 : 2)
                if compact { Spacer(minLength: 4); distance(station) }
            }
            if !compact { distance(station) }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let price = station.price {
                    Text(price.dollarsPerGallon, format: .currency(code: "USD"))
                        .font(compact ? .subheadline.bold() : .title2.bold())
                        .minimumScaleFactor(0.8)
                    Text("/gal").font(.caption2).foregroundStyle(.secondary)
                    if compact { Text(price.status(at: entry.date)).font(.caption2).lineLimit(1) }
                } else {
                    Text("No price reported").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !compact, let price = station.price {
                Text(price.status(at: entry.date)).font(.caption2).lineLimit(1)
            }
        }.accessibilityElement(children: .combine)
    }
    private func distance(_ station: NearbyE85Station) -> some View {
        Text("≈\(station.distanceMiles, specifier: "%.1f") mi")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityLabel("Approximately \(station.distanceMiles, specifier: "%.1f") miles from last app location")
    }
    private func footer(_ snapshot: NearbyE85Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snapshot.isStale(at: entry.date) ? "Older location · tap to refresh" : "Near last app location")
            HStack(spacing: 3) {
                Text("Updated")
                Text(snapshot.updatedAt, style: .relative)
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
    }
    private var fallback: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.snapshot?.state == .permissionRequired {
                Text("Location needed").font(.headline)
                Text("Open 85Blends to allow location and find nearby E85.")
            } else if let snapshot = entry.snapshot, snapshot.state == .noStations {
                Text("No nearby E85").font(.headline)
                Text("None found within \(Int(snapshot.radiusMiles)) mi. Open the app to search farther.")
                Spacer(minLength: 0)
                footer(snapshot)
            } else {
                Text("Find nearby E85").font(.headline)
                Text("Open 85Blends to refresh nearby stations.")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}


struct NearbyE85WidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NearbyE85Entry
    var body: some View { NearbyE85WidgetView(entry: entry, family: family) }
}
