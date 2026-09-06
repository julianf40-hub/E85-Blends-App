import SwiftUI
import WidgetKit
#if NEARBY_WIDGET_TESTING
@testable import EightyFiveBlends
#endif

nonisolated struct NearbyE85Entry: TimelineEntry {
    let date: Date
    let snapshot: NearbyE85Snapshot?
    var mapRender: NearbyE85MapRender? = nil
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
            header
            if let snapshot = entry.snapshot, snapshot.state == .ready, let first = snapshot.stations.first {
                if family == .systemSmall {
                    station(first, compact: false)
                    Spacer(minLength: 0)
                    footer(snapshot)
                } else {
                    mediumBody(snapshot: snapshot, first: first)
                }
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Small keeps its original single-line title untouched. Medium adds a trailing freshness
    // label so the map below never has to explain itself, and never implies the location is
    // being tracked live.
    @ViewBuilder private var header: some View {
        if family == .systemMedium, let snapshot = entry.snapshot, snapshot.state == .ready {
            HStack(alignment: .firstTextBaseline) {
                Label("Nearby E85", systemImage: "fuelpump.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(.green)
                Spacer(minLength: 4)
                Group {
                    if snapshot.isStale(at: entry.date) {
                        Text("Older location")
                    } else {
                        HStack(spacing: 3) { Text("Updated"); Text(snapshot.updatedAt, style: .relative) }
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Label("Nearby E85", systemImage: "fuelpump.fill")
                .font(.caption.weight(.bold)).foregroundStyle(.green)
        }
    }

    @ViewBuilder private func mediumBody(snapshot: NearbyE85Snapshot, first: NearbyE85Station) -> some View {
        if let mapRender = entry.mapRender {
            NearbyE85MapView(render: mapRender)
                .frame(height: mapRender.size.height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Divider()
            Link(destination: NearbyE85DeepLink.url(stationID: first.id)) {
                compactStrip(first)
            }.buttonStyle(.plain)
        } else {
            // No map yet (offline first render, or an older cached snapshot with no user
            // coordinate) — fall back to the previous text-only rows rather than showing nothing.
            ForEach(Array(snapshot.stations.prefix(2))) { item in
                Link(destination: NearbyE85DeepLink.url(stationID: item.id)) {
                    station(item, compact: true)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            footer(snapshot)
        }
    }

    private func compactStrip(_ station: NearbyE85Station) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(station.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                distance(station)
                if let price = station.price {
                    Text(price.dollarsPerGallon, format: .currency(code: "USD"))
                        .font(.subheadline.bold()).minimumScaleFactor(0.8).lineLimit(1)
                }
            }
            Text(station.price?.status(at: entry.date) ?? "No price reported")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.accessibilityElement(children: .combine)
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

/// Overlays the user/station pins onto a pre-rendered MKMapSnapshotter image. The marker points
/// were computed once, in the same point-space as the image, so this never needs its own
/// coordinate math or a live MKMapView.
private struct NearbyE85MapView: View {
    let render: NearbyE85MapRender

    var body: some View {
        ZStack {
            Image(uiImage: render.image).resizable()
            // Stations draw first, the user dot last, so a station pin sitting almost on top of
            // the user's own point never hides the blue marker underneath it.
            ForEach(render.markers.filter { $0.kind != .user }) { marker in
                markerView(marker).position(marker.point)
            }
            ForEach(render.markers.filter { $0.kind == .user }) { marker in
                markerView(marker).position(marker.point)
            }
        }
        .frame(width: render.size.width, height: render.size.height)
    }

    @ViewBuilder private func markerView(_ marker: NearbyE85MapMarker) -> some View {
        switch marker.kind {
        case .user:
            ZStack {
                Circle().fill(.white).frame(width: 16, height: 16)
                Circle().fill(.blue).frame(width: 12, height: 12)
            }
            .shadow(radius: 1)
        case .nearestStation:
            VStack(spacing: 2) {
                if let priceLabel = marker.priceLabel {
                    Text(priceLabel)
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.green, in: Capsule())
                }
                Image(systemName: "fuelpump.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .padding(5)
                    .background(Color.green, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
            }
            .shadow(radius: 1)
        case .station:
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                .padding(4)
                .background(Color.green.opacity(0.85), in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 1))
        }
    }
}

struct NearbyE85WidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NearbyE85Entry
    var body: some View { NearbyE85WidgetView(entry: entry, family: family) }
}
