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
    // contentMarginsDisabled() (set on the widget configuration) hands content the entire
    // canvas; this is the system's own default inset, applied back manually wherever text
    // shouldn't sit flush against the widget's edge. Medium/large's map areas deliberately never
    // apply this — the map is meant to run edge-to-edge.
    @Environment(\.widgetContentMargins) private var widgetMargins

    var body: some View {
        content
            .containerBackground(.background, for: .widget)
            .widgetURL(NearbyE85DeepLink.url(stationID: entry.snapshot?.stations.first?.id))
            .privacySensitive()
    }

    @ViewBuilder var content: some View {
        switch family {
        case .systemMedium: mediumContent
        case .systemLarge: largeContent
        default: smallContent
        }
    }

    // MARK: - Small — information-first nearest-station card (unchanged visual design)

    private var smallContent: some View {
        Group {
            if let snapshot = entry.snapshot, snapshot.state == .ready, let first = snapshot.stations.first {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    station(first, compact: false)
                    Spacer(minLength: 0)
                    footer(snapshot)
                }
            } else {
                fallbackBody
            }
        }
        .padding(widgetMargins)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Medium — map-only: "Where am I, and where is E85 around me?"

    @ViewBuilder private var mediumContent: some View {
        if let snapshot = entry.snapshot, snapshot.state == .ready, let mapRender = entry.mapRender {
            mapArea(mapRender, snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot = entry.snapshot, snapshot.state == .ready, let first = snapshot.stations.first {
            // No map yet (offline first render, or an older cached snapshot with no user
            // coordinate) — degrade to the small-style information card rather than a blank map.
            VStack(alignment: .leading, spacing: 6) {
                header
                station(first, compact: false)
                Spacer(minLength: 0)
                footer(snapshot)
            }
            .padding(widgetMargins)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            smallContent
        }
    }

    // MARK: - Large — map on top, readable station list below

    @ViewBuilder private var largeContent: some View {
        if let snapshot = entry.snapshot, snapshot.state == .ready, !snapshot.stations.isEmpty {
            VStack(spacing: 0) {
                if let mapRender = entry.mapRender {
                    mapArea(mapRender, snapshot: snapshot)
                } else {
                    // No map yet — still lead with something other than blank space.
                    HStack { header; Spacer(minLength: 0) }
                        .padding(widgetMargins)
                    Spacer(minLength: 0)
                }
                Divider()
                largeStationList(snapshot)
                    .padding(.leading, widgetMargins.leading).padding(.trailing, widgetMargins.trailing)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            smallContent
        }
    }

    private func largeStationList(_ snapshot: NearbyE85Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.stations) { item in
                Link(destination: NearbyE85DeepLink.url(stationID: item.id)) {
                    largeRow(item)
                }.buttonStyle(.plain)
            }
        }
    }

    private func largeRow(_ station: NearbyE85Station) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(station.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                distance(station)
            }
            Text(priceLine(station)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }

    private func priceLine(_ station: NearbyE85Station) -> String {
        guard let price = station.price else { return "No price reported" }
        return "\(price.dollarsPerGallon.formatted(.currency(code: "USD"))) · \(price.status(at: entry.date))"
    }

    // MARK: - Shared map area (medium's full canvas, large's top portion)

    /// Overlays the user/station pins onto a pre-rendered MKMapSnapshotter image and, only when
    /// stale, a single small unobtrusive badge — no persistent header bar or branding repeated
    /// over the map (the Home Screen already labels the widget by app name underneath it).
    @ViewBuilder private func mapArea(_ mapRender: NearbyE85MapRender, snapshot: NearbyE85Snapshot) -> some View {
        NearbyE85MapView(render: mapRender)
            .frame(maxWidth: .infinity)
            .frame(height: mapRender.size.height)
            .overlay(alignment: .topTrailing) {
                if snapshot.isStale(at: entry.date) {
                    freshnessBadge("Older location")
                }
            }
    }

    private func freshnessBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .padding(6)
    }

    // MARK: - Shared small-scale building blocks

    private var header: some View {
        Label("Nearby E85", systemImage: "fuelpump.fill")
            .font(.caption.weight(.bold)).foregroundStyle(.green)
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
    private var fallbackBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
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
        }
        .font(.caption).foregroundStyle(.secondary)
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
