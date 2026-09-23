import SwiftUI
import WidgetKit
import CoreLocation

@main
struct NearbyE85Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NearbyE85Configuration.kind, provider: NearbyE85Provider()) { entry in
            NearbyE85WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Nearby E85")
        // 85Blends 2.4.0 — states the Pro requirement up front in the widget gallery, so nobody
        // adds the widget expecting station data and meets a lock instead. Deliberately generic
        // across the three families (Medium is map-only and shows no price/ethanol text).
        .description("Nearby E85 stations on your Home Screen with 85Blends Pro.")
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
    NearbyE85Entry(date: .now, snapshot: NearbyE85Provider.example, access: .pro)
    NearbyE85Entry(date: .now, snapshot: nil, access: .pro)
    NearbyE85Entry(date: .now, snapshot: .permissionRequired(at: .now), access: .pro)
    // 85Blends 2.4.0 Pro gate — the two non-Pro shells. Neither carries a snapshot, map, or
    // control; the second must read as neutral (never "Free"/"Unlock") — see NearbyE85WidgetAccessCopy.
    NearbyE85Entry(date: .now, snapshot: nil, access: .free)
    NearbyE85Entry(date: .now, snapshot: nil, access: .unknown)
}

#Preview(as: .systemMedium) {
    NearbyE85Widget()
} timeline: {
    NearbyE85Entry(date: .now, snapshot: NearbyE85Provider.example, access: .pro)
    NearbyE85Entry(date: .now, snapshot: nil, access: .free)
    NearbyE85Entry(date: .now, snapshot: nil, access: .unknown)
}

#Preview(as: .systemLarge) {
    NearbyE85Widget()
} timeline: {
    NearbyE85Entry(date: .now, snapshot: NearbyE85Provider.example, access: .pro)
    NearbyE85Entry(date: .now, snapshot: nil, access: .free)
    NearbyE85Entry(date: .now, snapshot: nil, access: .unknown)
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
    return NearbyE85Entry(date: .now, snapshot: snapshot, access: .pro, mapRender: mapRender)
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
