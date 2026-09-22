import SwiftUI
import WidgetKit
import CoreLocation

nonisolated struct NearbyE85Provider: TimelineProvider {
    func placeholder(in context: Context) -> NearbyE85Entry {
        .init(date: .now, snapshot: Self.example, mapRender: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (NearbyE85Entry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { @MainActor in
            let now = Date.now
            let snapshot = readAuthorizedSnapshot()
            // Read once per timeline, same as the snapshot itself — zoom is presentation-only,
            // never a reason to touch location or refetch stations.
            let zoomLevel = context.family == .systemLarge ? NearbyE85MapZoomStore().read() : .default
            let mapRender = await mapRender(for: snapshot, context: context, zoomLevel: zoomLevel)
            // 85Blends 2.4.0 widget polish — see getTimeline's identical computation below for
            // why this reads the pending-refresh timestamp rather than faking anything.
            let pendingRefreshAt = NearbyE85RefreshRequestStore().pendingRequestDate()
            let isRefreshing = NearbyE85RefreshFeedback.isRefreshing(requestedAt: pendingRefreshAt, now: now)
            completion(.init(date: now, snapshot: snapshot, mapRender: mapRender, zoomLevel: zoomLevel, isRefreshing: isRefreshing))
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NearbyE85Entry>) -> Void) {
        Task { @MainActor in
            let now = Date.now
            let snapshot = readAuthorizedSnapshot()
            let zoomLevel = context.family == .systemLarge ? NearbyE85MapZoomStore().read() : .default
            // The map only ever needs one render per timeline: the region and pins it depicts
            // don't change across the stale/expiry entries below, only the copy around them.
            let mapRender = await mapRender(for: snapshot, context: context, zoomLevel: zoomLevel)
            // 85Blends 2.4.0 widget polish — the manual refresh button's "in progress" feedback.
            // Read once, same as everything else above: this never claims new data arrived (the
            // snapshot/its timestamps below are completely untouched by this), it only tracks
            // how recently the user tapped refresh so the control can show, and then honestly
            // clear, an in-progress appearance. See NearbyE85RefreshFeedback's header.
            let pendingRefreshAt = NearbyE85RefreshRequestStore().pendingRequestDate()
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
            // A follow-up date exactly when the in-progress window ends, so the control settles
            // back to normal on its own — without this, a refresh tap with no genuinely new data
            // to publish (and no later WidgetCenter reload to trigger a re-render) would leave
            // the spinner showing until the next unrelated timeline boundary above, which could
            // be many minutes away.
            if let pendingRefreshAt {
                let settleDate = pendingRefreshAt.addingTimeInterval(NearbyE85RefreshFeedback.window)
                if settleDate > now { dates.append(settleDate) }
            }
            let entries = Array(Set(dates)).filter { $0 >= now }.sorted().map { date in
                NearbyE85Entry(date: date, snapshot: snapshot.flatMap { $0.isValid(at: date) ? $0 : nil },
                              mapRender: mapRender, zoomLevel: zoomLevel,
                              isRefreshing: NearbyE85RefreshFeedback.isRefreshing(requestedAt: pendingRefreshAt, now: date))
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
    // Medium is map-only (full-bleed); large reserves its bottom portion for a station list.
    // Small keeps its existing text-only layout and never renders a map. Medium always renders
    // at the default zoom level regardless of the Large widget's stored preference — the two
    // families don't share zoom state.
    @MainActor private func mapRender(for snapshot: NearbyE85Snapshot?, context: Context,
                                      zoomLevel: NearbyE85MapZoomLevel) async -> NearbyE85MapRender? {
        let heightFraction: Double
        switch context.family {
        case .systemMedium: heightFraction = 1.0
        case .systemLarge: heightFraction = 0.6
        default: return nil
        }
        guard let snapshot, snapshot.state == .ready, let user = snapshot.userCoordinate else { return nil }
        let size = NearbyE85MapRenderer.mapSize(for: context.displaySize, heightFraction: heightFraction)
        // 85Blends 2.4.0 widget quality pass — no longer passes a `scale` at all (see
        // NearbyE85MapRenderer.render's own comment): MKMapSnapshotter now picks its own native,
        // device-appropriate raster density instead of a hardcoded/manually-resolved one. Both
        // families share this; only the logical point-space `size` above still differs between them.
        return await NearbyE85MapRenderer.render(userLatitude: user.latitude, userLongitude: user.longitude,
                                                  stations: snapshot.stations, size: size,
                                                  zoomLevel: context.family == .systemLarge ? zoomLevel : .default)
    }
    static var example: NearbyE85Snapshot {
        .make(stations: [.init(id: "example", name: "Nearby E85 station", address: "Example address",
                              latitude: 33.45, longitude: -112.07, distanceMiles: 1.2,
                              price: .init(dollarsPerGallon: 2.89, reportedAt: .now, source: .community))],
              radiusMiles: 25, updatedAt: .now, locationAt: .now, userLatitude: 33.44, userLongitude: -112.08)
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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // Medium is a full-bleed map; large's map portion is likewise edge-to-edge. Small and
        // large's station list re-apply the system's own default margins themselves (see
        // NearbyE85WidgetView's use of the widgetContentMargins environment value) so neither
        // regresses to text sitting flush against the widget's edge.
        .contentMarginsDisabled()
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

#Preview(as: .systemLarge) {
    NearbyE85Widget()
} timeline: {
    NearbyE85Entry(date: .now, snapshot: NearbyE85Provider.example)
}

// MARK: - 85Blends 2.4.0 ethanol/seam polish previews
//
// Plain View previews rather than the widget-family #Preview(as:) form above: forcing
// .environment(\.colorScheme, ...) explicitly guarantees each of the four Small combinations
// (and both Large ones) below renders in the exact appearance named, rather than relying on
// Xcode's canvas appearance toggle. Large's previews also carry a synthetic, network-free map
// render (same technique as EightyFiveBlendsTests/NearbyE85RenderingTests' syntheticRender) so
// the top-corner seam fix (NearbyE85WidgetView.largeContent's ContainerRelativeShape() clip) is
// something to actually look at here, against a flat, high-contrast fill color, rather than
// leaving Large's map area empty.

private func nearbyE85PreviewStation(id: String, name: String, distanceMiles: Double,
                                      price: NearbyE85Price?, ethanol: NearbyE85Ethanol?) -> NearbyE85Station {
    NearbyE85Station(id: id, name: name, address: "Example address", latitude: 33.45, longitude: -112.07,
                     distanceMiles: distanceMiles, price: price, ethanol: ethanol)
}

private func nearbyE85PreviewEntry(stations: [NearbyE85Station], mapRender: NearbyE85MapRender? = nil) -> NearbyE85Entry {
    let snapshot = NearbyE85Snapshot.make(stations: stations, radiusMiles: 25, updatedAt: .now, locationAt: .now,
                                          userLatitude: 33.44, userLongitude: -112.08)
    return NearbyE85Entry(date: .now, snapshot: snapshot, mapRender: mapRender)
}

/// A flat-color stand-in map — no network access, no MKMapSnapshotter round trip — just enough
/// to make the widget's top corners visually inspectable against the seam fix.
private func nearbyE85PreviewMapRender(size: CGSize) -> NearbyE85MapRender {
    let image = UIGraphicsImageRenderer(size: size).image { context in
        UIColor(red: 0.86, green: 0.90, blue: 0.87, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    return NearbyE85MapRender(image: image, size: size, markers: [
        NearbyE85MapMarker(id: "user", kind: .user, point: CGPoint(x: size.width * 0.5, y: size.height * 0.55), priceLabel: nil),
        NearbyE85MapMarker(id: "mobil", kind: .nearestStation, point: CGPoint(x: size.width * 0.62, y: size.height * 0.4), priceLabel: "$3.90"),
    ])
}

// Constructs NearbyE85WidgetView directly (family passed as a plain init argument) and renders
// its `.content` rather than `.body` — the same choice EightyFiveBlendsTests/
// NearbyE85RenderingTests already makes for exactly this reason: `widgetFamily` has no public
// setter to inject via `.environment(...)`, and `.containerBackground(_:for:)` is a WidgetKit
// rendering-pipeline API that a bare canvas/ImageRenderer preview outside a real widget host
// isn't guaranteed to resolve the same way a live Home Screen widget would. That also means
// ContainerRelativeShape()'s corner-rounding itself is something only an actual Home Screen
// widget (Simulator or device) can truly confirm — these previews are for reviewing the ethanol
// layout and a rough look at the map area, not final proof the seam is gone.
private func nearbyE85PreviewView(_ entry: NearbyE85Entry, family: WidgetFamily, size: CGSize, colorScheme: ColorScheme) -> some View {
    NearbyE85WidgetView(entry: entry, family: family).content
        .environment(\.colorScheme, colorScheme)
        .frame(width: size.width, height: size.height)
        .background(colorScheme == .dark ? Color.black : Color.white)
}

private let nearbyE85PreviewMobil = nearbyE85PreviewStation(
    id: "mobil", name: "Mobil", distanceMiles: 0.6,
    price: .init(dollarsPerGallon: 3.90, reportedAt: Date.now.addingTimeInterval(-2 * 86400), source: .community),
    ethanol: .init(percentage: 78, reportedAt: Date.now.addingTimeInterval(-1 * 86400)))

private let nearbyE85PreviewMobilNoEthanol = nearbyE85PreviewStation(
    id: "mobil", name: "Mobil", distanceMiles: 0.6,
    price: .init(dollarsPerGallon: 3.90, reportedAt: Date.now.addingTimeInterval(-2 * 86400), source: .community),
    ethanol: nil)

#Preview("Small — Light, no ethanol") {
    nearbyE85PreviewView(nearbyE85PreviewEntry(stations: [nearbyE85PreviewMobilNoEthanol]),
                        family: .systemSmall, size: CGSize(width: 155, height: 155), colorScheme: .light)
}

#Preview("Small — Light, E78") {
    nearbyE85PreviewView(nearbyE85PreviewEntry(stations: [nearbyE85PreviewMobil]),
                        family: .systemSmall, size: CGSize(width: 155, height: 155), colorScheme: .light)
}

#Preview("Small — Dark, no ethanol") {
    nearbyE85PreviewView(nearbyE85PreviewEntry(stations: [nearbyE85PreviewMobilNoEthanol]),
                        family: .systemSmall, size: CGSize(width: 155, height: 155), colorScheme: .dark)
}

#Preview("Small — Dark, E78") {
    nearbyE85PreviewView(nearbyE85PreviewEntry(stations: [nearbyE85PreviewMobil]),
                        family: .systemSmall, size: CGSize(width: 155, height: 155), colorScheme: .dark)
}

private let nearbyE85PreviewLargeStations: [NearbyE85Station] = [
    nearbyE85PreviewMobil,
    nearbyE85PreviewStation(id: "alliance", name: "Alliance AutoGas - 76 Olive Food Mart", distanceMiles: 2.1,
                            price: nil, ethanol: nil),
    nearbyE85PreviewStation(id: "chevron", name: "Chevron", distanceMiles: 3.4,
                            price: .init(dollarsPerGallon: 4.99, reportedAt: Date.now.addingTimeInterval(-20 * 86400), source: .community),
                            ethanol: .init(percentage: 70, reportedAt: Date.now.addingTimeInterval(-3 * 86400))),
]
private let nearbyE85PreviewLargeSize = CGSize(width: 329, height: 345)
private let nearbyE85PreviewLargeMapSize = NearbyE85MapRenderer.mapSize(for: CGSize(width: 329, height: 345), heightFraction: 0.6)

#Preview("Large — Light, mixed ethanol availability") {
    nearbyE85PreviewView(
        nearbyE85PreviewEntry(stations: nearbyE85PreviewLargeStations, mapRender: nearbyE85PreviewMapRender(size: nearbyE85PreviewLargeMapSize)),
        family: .systemLarge, size: nearbyE85PreviewLargeSize, colorScheme: .light)
}

#Preview("Large — Dark, mixed ethanol availability") {
    nearbyE85PreviewView(
        nearbyE85PreviewEntry(stations: nearbyE85PreviewLargeStations, mapRender: nearbyE85PreviewMapRender(size: nearbyE85PreviewLargeMapSize)),
        family: .systemLarge, size: nearbyE85PreviewLargeSize, colorScheme: .dark)
}
