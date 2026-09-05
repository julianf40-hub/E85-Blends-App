import XCTest
import SwiftUI
import WidgetKit
@testable import EightyFiveBlends

@MainActor
final class NearbyE85RenderingTests: XCTestCase {
    func testSmallAndMediumFallbackAndPriceLayouts() throws {
        let now = Date.now
        let first = NearbyE85Station(id: "one", name: "Long Station Name E85 Fuel Center", address: "Example address",
            latitude: 33.45, longitude: -112.07, distanceMiles: 1.2,
            price: .init(dollarsPerGallon: 2.89, reportedAt: now.addingTimeInterval(-20 * 86400), source: .community))
        let second = NearbyE85Station(id: "two", name: "Second station", address: "Example address",
            latitude: 33.46, longitude: -112.08, distanceMiles: 2.8, price: nil)
        let ready = NearbyE85Snapshot.make(stations: [first, second], radiusMiles: 25, updatedAt: now, locationAt: now)
        let empty = NearbyE85Snapshot.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now)
        let cases: [(String, NearbyE85Snapshot?)] = [("stations-stale-price", ready), ("empty", empty),
            ("permission", .permissionRequired(at: now)), ("no-cache", nil)]
        for (name, snapshot) in cases {
            for (familyName, family, width) in [("small", WidgetFamily.systemSmall, 142.0), ("medium", .systemMedium, 306.0)] {
                let view = NearbyE85WidgetView(entry: .init(date: now, snapshot: snapshot), family: family).content
                    .environment(\.colorScheme, .light)
                    .frame(width: width, height: 142).padding(16).background(Color.white)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage)
                let attachment = XCTAttachment(image: image)
                attachment.name = "nearby-\(familyName)-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
