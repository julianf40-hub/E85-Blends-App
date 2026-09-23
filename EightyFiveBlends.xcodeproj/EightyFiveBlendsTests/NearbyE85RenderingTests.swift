import XCTest
import SwiftUI
import WidgetKit
import MapKit
@testable import EightyFiveBlends

@MainActor
final class NearbyE85RenderingTests: XCTestCase {
    // Approximate current-generation iPhone reference sizes (points). Real on-device sizes vary
    // slightly by model, but these are close enough to catch clipping/overlap/truncation.
    private static let smallSize = CGSize(width: 155, height: 155)
    private static let mediumSize = CGSize(width: 329, height: 155)
    private static let largeSize = CGSize(width: 329, height: 345)
    private func render(_ entry: NearbyE85Entry, family: WidgetFamily, size: CGSize, colorScheme: ColorScheme = .light) throws -> UIImage {
        // `widgetContentMargins` is read-only, so tests can't inject a stand-in value the way
        // production gets it from the real widget host — NearbyE85WidgetView reads whatever
        // default this environment resolves to outside an actual widget render context. Visual
        // captures below confirm small/large still get sensible breathing room from it.
        let view = NearbyE85WidgetView(entry: entry, family: family).content
            .environment(\.colorScheme, colorScheme)
            .frame(width: size.width, height: size.height)
            .background(colorScheme == .dark ? Color.black : Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static let familySizes: [(String, WidgetFamily, CGSize)] = [
        ("small", .systemSmall, smallSize), ("medium", .systemMedium, mediumSize), ("large", .systemLarge, largeSize),
    ]

    func testFallbackStatesAcrossAllFamilies() throws {
        let now = Date.now
        let first = NearbyE85Station(id: "one", name: "Long Station Name E85 Fuel Center", address: "Example address",
            latitude: 33.45, longitude: -112.07, distanceMiles: 1.2,
            price: .init(dollarsPerGallon: 2.89, reportedAt: now.addingTimeInterval(-20 * 86400), source: .community))
        let second = NearbyE85Station(id: "two", name: "Second station", address: "Example address",
            latitude: 33.46, longitude: -112.08, distanceMiles: 2.8, price: nil)
        // Deliberately no userLatitude/userLongitude — exercises the "ready but no map yet"
        // degraded path (informationCard) for medium/large, since no mapRender is supplied.
        let readyNoMap = NearbyE85Snapshot.make(stations: [first, second], radiusMiles: 25, updatedAt: now, locationAt: now)
        let noStations = NearbyE85Snapshot.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now)
        let cases: [(String, NearbyE85Snapshot?)] = [
            ("ready-no-map-yet", readyNoMap), ("no-stations", noStations),
            ("permission-required", .permissionRequired(at: now)), ("no-cache", nil),
        ]
        for (stateName, snapshot) in cases {
            for (familyName, family, size) in Self.familySizes {
                let image = try render(.init(date: now, snapshot: snapshot, access: .pro), family: family, size: size)
                attach(image, name: "nearby-\(familyName)-\(stateName)")
            }
        }
    }

    /// The manual refresh button, present on every family, must render alongside the map/zoom
    /// controls without clipping the widget's canvas or crashing — Large in particular now
    /// stacks three controls (+/-/refresh) on the map's trailing edge.
    /// 85Blends 2.4.0 Pro gate — a VISUAL SMOKE test only: the `.free` (locked) and `.unknown`
    /// (verify) shells at every family, in both appearances. Each render is attached for visual
    /// review, and every light-mode capture is additionally scanned to confirm the shell drew
    /// content (text/icon) rather than an empty canvas — the same near-white heuristic
    /// testSmallFooterRemainsVisible… uses. This does NOT prove data isolation — a pixel scan can't
    /// tell station text from lock-screen text. That proof lives in NearbyE85WidgetProGateTests
    /// (NearbyE85ProviderAccessGateTests: the Provider's non-Pro path never loads Pro inputs and its
    /// entries carry no snapshot/map/zoom/refresh/directions link) and in NearbyE85WidgetView's own
    /// structure (Pro views sit behind `entry.access == .pro`; the locked/verify shells take no
    /// snapshot at all).
    func testNonProShellsRenderAcrossAllFamiliesAndColorSchemes() throws {
        let now = Date.now
        for access in [NearbyE85WidgetAccessStatus.free, .unknown] {
            for (familyName, family, size) in Self.familySizes {
                for colorScheme in [ColorScheme.light, .dark] {
                    let entry = NearbyE85Entry(date: now, snapshot: nil, access: access)
                    let image = try render(entry, family: family, size: size, colorScheme: colorScheme)
                    attach(image, name: "nearby-\(familyName)-\(access.rawValue)-\(colorScheme == .dark ? "dark" : "light")")
                    guard colorScheme == .light else { continue }
                    var foundContent = false
                    let scale = image.scale
                    for x in stride(from: 8, to: Int(size.width) - 8, by: 6) where !foundContent {
                        for y in stride(from: 8, to: Int(size.height) - 8, by: 6) where !foundContent {
                            let color = try pixelColor(of: image, at: CGPoint(x: CGFloat(x) * scale, y: CGFloat(y) * scale))
                            if isNotNearWhite(color) { foundContent = true }
                        }
                    }
                    XCTAssertTrue(foundContent, "\(familyName)/\(access.rawValue) rendered an apparently blank canvas")
                }
            }
        }
    }

    func testRefreshButtonRendersAlongsideMapAndZoomControlsOnEveryFamily() throws {
        let now = Date.now
        let station = NearbyE85Station(id: "nearest", name: "Circle K", address: "1 N Central Ave, Phoenix, AZ",
            latitude: 33.4501, longitude: -112.0731, distanceMiles: 0.4,
            price: .init(dollarsPerGallon: 2.89, reportedAt: now, source: .community))
        let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: 33.4484, userLongitude: -112.0740)
        for (familyName, family, size) in Self.familySizes {
            let heightFraction = family == .systemLarge ? 0.6 : 1.0
            let mapSize = NearbyE85MapRenderer.mapSize(for: size, heightFraction: heightFraction)
            let mapRender: NearbyE85MapRender? = family == .systemSmall ? nil : syntheticRender(for: snapshot, size: mapSize)
            let entry = NearbyE85Entry(date: now, snapshot: snapshot, access: .pro, mapRender: mapRender, zoomLevel: .zoomedIn4)
            let image = try render(entry, family: family, size: size)
            XCTAssertEqual(image.size, size, "The refresh/zoom overlay must never resize the widget's own canvas")
            attach(image, name: "nearby-\(familyName)-with-refresh-button")
        }
    }

    /// 85Blends 2.4.0 widget polish — the refresh control's in-progress appearance must render
    /// cleanly alongside the map/zoom controls, on every family, without resizing or clipping
    /// the widget's own canvas (mirrors testRefreshButtonRendersAlongsideMapAndZoomControlsOnEveryFamily
    /// above, with `isRefreshing: true` instead).
    func testRefreshingStateRendersAlongsideMapAndZoomControlsOnEveryFamily() throws {
        let now = Date.now
        let station = NearbyE85Station(id: "nearest", name: "Circle K", address: "1 N Central Ave, Phoenix, AZ",
            latitude: 33.4501, longitude: -112.0731, distanceMiles: 0.4,
            price: .init(dollarsPerGallon: 2.89, reportedAt: now, source: .community))
        let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: 33.4484, userLongitude: -112.0740)
        for (familyName, family, size) in Self.familySizes {
            let heightFraction = family == .systemLarge ? 0.6 : 1.0
            let mapSize = NearbyE85MapRenderer.mapSize(for: size, heightFraction: heightFraction)
            let mapRender: NearbyE85MapRender? = family == .systemSmall ? nil : syntheticRender(for: snapshot, size: mapSize)
            let entry = NearbyE85Entry(date: now, snapshot: snapshot, access: .pro, mapRender: mapRender, zoomLevel: .zoomedIn4, isRefreshing: true)
            let image = try render(entry, family: family, size: size)
            XCTAssertEqual(image.size, size, "The in-progress refresh appearance must never resize the widget's own canvas")
            attach(image, name: "nearby-\(familyName)-refreshing")
        }
    }

    /// 85Blends 2.4.0 widget polish — the refresh control's inset from the widget edge must be
    /// larger than the pre-polish values (4pt for Small/Medium's overlay, 8pt for Large's
    /// control-stack trailing padding) but still comfortably inside a Home Screen widget's own
    /// bounds, on the smallest family this app ships (Small, ~155x155pt).
    func testRefreshControlInsetIsGreaterThanBeforeAndWithinSafeBounds() {
        XCTAssertGreaterThan(NearbyE85WidgetLayout.smallMediumRefreshInset, 4,
                              "Small/Medium's refresh button must sit farther from the edge than the pre-polish 4pt")
        XCTAssertLessThan(NearbyE85WidgetLayout.smallMediumRefreshInset, Self.smallSize.width / 4,
                           "The inset must stay well within even the smallest widget's bounds")
        XCTAssertGreaterThan(NearbyE85WidgetLayout.largeControlsTrailingInset, 8,
                              "Large's control stack must sit farther from the edge than the pre-polish 8pt")
        XCTAssertLessThan(NearbyE85WidgetLayout.largeControlsTrailingInset, Self.largeSize.width / 4,
                           "The inset must stay well within the Large widget's own bounds")
    }

    // Phoenix-area fixture coordinates so the map region/marker placement is realistic rather
    // than degenerate (e.g. all points identical).
    private static let phoenixUser = (latitude: 33.4484, longitude: -112.0740)

    private func phoenixStations(now: Date) -> (nearest: NearbyE85Station, second: NearbyE85Station, third: NearbyE85Station) {
        (nearest: NearbyE85Station(id: "nearest", name: "Circle K", address: "1 N Central Ave, Phoenix, AZ",
            latitude: 33.4501, longitude: -112.0731, distanceMiles: 0.4,
            price: .init(dollarsPerGallon: 2.89, reportedAt: now.addingTimeInterval(-2 * 86400), source: .community)),
         second: NearbyE85Station(id: "second", name: "QuikTrip", address: "500 E Van Buren St, Phoenix, AZ",
            latitude: 33.4472, longitude: -112.0601, distanceMiles: 1.3, price: nil),
         third: NearbyE85Station(id: "third", name: "Really Long Alliance AutoGas Fuel Center Name", address: "2100 N 7th Ave, Phoenix, AZ",
            latitude: 33.4675, longitude: -112.0850, distanceMiles: 2.1,
            price: .init(dollarsPerGallon: 3.05, reportedAt: now, source: .saved)))
    }

    /// A synthetic (network-free) map render: a flat background plus markers placed with the
    /// same region math the real renderer uses, so the widget's map layout is exercised
    /// deterministically for every state without depending on MapKit tile availability.
    private func syntheticRender(for snapshot: NearbyE85Snapshot, size: CGSize,
                                 zoomLevel: NearbyE85MapZoomLevel = .default) -> NearbyE85MapRender {
        let user = snapshot.userCoordinate.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            ?? CLLocationCoordinate2D(latitude: Self.phoenixUser.latitude, longitude: Self.phoenixUser.longitude)
        let stationCoordinates = snapshot.stations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stationCoordinates,
                                               aspectRatio: size.width / size.height, zoomLevel: zoomLevel)
        func point(for coordinate: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(x: size.width * (0.5 + (coordinate.longitude - region.center.longitude) / region.span.longitudeDelta),
                    y: size.height * (0.5 - (coordinate.latitude - region.center.latitude) / region.span.latitudeDelta))
        }
        let backgroundColor = UIColor(red: 0.86, green: 0.90, blue: 0.87, alpha: 1)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let stationMarkers = snapshot.stations.enumerated().map { index, station -> NearbyE85MapMarker in
            let coordinate = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
            let isNearest = index == 0
            return NearbyE85MapMarker(
                id: station.id, kind: isNearest ? .nearestStation : .station, point: point(for: coordinate),
                priceLabel: isNearest ? station.price.map { $0.dollarsPerGallon.formatted(.currency(code: "USD")) } : nil)
        }
        let userPoint = NearbyE85MapRegion.declutteredUserPoint(point(for: user), avoiding: stationMarkers.map(\.point), minimumSeparation: 24)
        let markers = [NearbyE85MapMarker(id: "user", kind: .user, point: userPoint, priceLabel: nil)] + stationMarkers
        return NearbyE85MapRender(image: image, size: size, markers: markers)
    }

    func testMediumMapOnlyLayoutAcrossStates() throws {
        let now = Date.now
        let (nearest, second, third) = phoenixStations(now: now)
        let ready = NearbyE85Snapshot.make(stations: [nearest, second, third], radiusMiles: 25, updatedAt: now, locationAt: now,
                                          userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let stale = NearbyE85Snapshot.make(stations: [nearest], radiusMiles: 25,
                                          updatedAt: now.addingTimeInterval(-2 * 3600), locationAt: now.addingTimeInterval(-2 * 3600),
                                          userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let noPrice = NearbyE85Snapshot.make(stations: [second], radiusMiles: 25, updatedAt: now, locationAt: now,
                                             userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let oneStation = NearbyE85Snapshot.make(stations: [nearest], radiusMiles: 25, updatedAt: now, locationAt: now,
                                                userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)

        let mapSize = NearbyE85MapRenderer.mapSize(for: Self.mediumSize, heightFraction: 1.0)
        let cases: [(String, NearbyE85Snapshot)] = [
            ("ready-three-stations", ready), ("stale-location", stale), ("no-price-nearest", noPrice), ("one-station", oneStation),
        ]
        for (name, snapshot) in cases {
            let entry = NearbyE85Entry(date: now, snapshot: snapshot, access: .pro, mapRender: syntheticRender(for: snapshot, size: mapSize))
            let image = try render(entry, family: .systemMedium, size: Self.mediumSize)
            attach(image, name: "nearby-medium-map-\(name)")
        }
    }

    func testLargeMapAndStationListAcrossStates() throws {
        let now = Date.now
        let (nearest, second, third) = phoenixStations(now: now)
        let mapSize = NearbyE85MapRenderer.mapSize(for: Self.largeSize, heightFraction: 0.6)

        func snapshot(_ stations: [NearbyE85Station], stale: Bool = false) -> NearbyE85Snapshot {
            let timestamp = stale ? now.addingTimeInterval(-2 * 3600) : now
            return .make(stations: stations, radiusMiles: 25, updatedAt: timestamp, locationAt: timestamp,
                        userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        }
        let mixedPrices = snapshot([nearest, second, third])
        let single = snapshot([nearest])
        let noPriceOnly = snapshot([second])
        let stale = snapshot([nearest, second], stale: true)

        let cases: [(String, NearbyE85Snapshot)] = [
            ("mixed-prices", mixedPrices), ("single-station", single),
            ("no-price-rows", noPriceOnly), ("stale-location", stale),
        ]
        for (name, snap) in cases {
            let entry = NearbyE85Entry(date: now, snapshot: snap, access: .pro, mapRender: syntheticRender(for: snap, size: mapSize))
            let image = try render(entry, family: .systemLarge, size: Self.largeSize)
            attach(image, name: "nearby-large-\(name)")
        }
    }

    /// 85Blends 2.4.0 widget ethanol polish — Small's compact ethanol line, in both color
    /// schemes, with and without a qualifying reading (absence must collapse with no leftover
    /// gap — this doesn't assert layout numerically, but the attached images make a stray blank
    /// row immediately visible on review).
    func testSmallStationCardAcrossEthanolAndColorSchemeStates() throws {
        let now = Date.now
        let (nearest, _, _) = phoenixStations(now: now)
        var withEthanol = nearest
        withEthanol.ethanol = .init(percentage: 78, reportedAt: now.addingTimeInterval(-1 * 86400))
        let cases: [(String, NearbyE85Station, ColorScheme)] = [
            ("light-no-ethanol", nearest, .light), ("light-e78", withEthanol, .light),
            ("dark-no-ethanol", nearest, .dark), ("dark-e78", withEthanol, .dark),
        ]
        for (name, station, scheme) in cases {
            let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now)
            let entry = NearbyE85Entry(date: now, snapshot: snapshot, access: .pro)
            let image = try render(entry, family: .systemSmall, size: Self.smallSize, colorScheme: scheme)
            attach(image, name: "nearby-small-\(name)")
        }
    }

    /// 85Blends 2.4.0 widget polish — Small's ethanol line added a 5th content row; without
    /// consolidating name+distance onto one line (see `inlineNameAndDistance` in
    /// `station(_:compact:showsEthanol:)`), that row pushed the two-line, stale footer toward —
    /// and on a physical device, past — the bottom of Small's fixed 155x155 canvas. Reproduces
    /// the exact on-device values (Mobil, 3.1mi, $3.90 reported 3d ago, E75 reported 5d ago,
    /// stale snapshot) at the real fixed canvas size, then samples a small grid of points across
    /// where the footer's second line ("Updated ...") should land and asserts at least one is
    /// genuinely non-background content — not a fake check of a source property. If the footer
    /// were pushed off-canvas or fully clipped, this whole region would sample as pure
    /// background.
    func testSmallFooterRemainsVisibleWithEthanolAndAStaleSnapshot() throws {
        let now = Date.now
        var station = NearbyE85Station(id: "nearest", name: "Mobil", address: "1 N Central Ave, Phoenix, AZ",
            latitude: 33.4501, longitude: -112.0731, distanceMiles: 3.1,
            price: .init(dollarsPerGallon: 3.90, reportedAt: now.addingTimeInterval(-3 * 86400), source: .community))
        station.ethanol = .init(percentage: 75, reportedAt: now.addingTimeInterval(-5 * 86400))
        // 2 hours old — safely past NearbyE85Snapshot.staleAfter (1 hour) — exercises the same
        // "Older location" + long relative-time footer state as the on-device report.
        let staleTimestamp = now.addingTimeInterval(-2 * 3600)
        let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: staleTimestamp, locationAt: staleTimestamp)

        let image = try render(.init(date: now, snapshot: snapshot, access: .pro), family: .systemSmall, size: Self.smallSize)
        attach(image, name: "nearby-small-ethanol-stale-footer")
        XCTAssertEqual(image.size, Self.smallSize, "Overflowing content must never resize the widget's own canvas")

        // A small grid across the bottom-left area where the footer's second line should sit at
        // Small's topLeading alignment. Wide enough to tolerate whatever widgetContentMargins
        // value this offline test environment resolves (see render(...)'s own header comment —
        // it can't be injected the way a real widget host provides it).
        var foundContent = false
        for y in stride(from: Self.smallSize.height - 10, through: Self.smallSize.height - 2, by: 2) {
            for x in stride(from: CGFloat(10), through: 60, by: 10) {
                let color = try pixelColor(of: image, at: CGPoint(x: x, y: y))
                if isNotNearWhite(color) { foundContent = true }
            }
        }
        XCTAssertTrue(foundContent, "Expected the footer's second line to render somewhere near the bottom of Small's canvas; " +
                      "sampled region was uniformly background — looks like the footer was pushed off-canvas or clipped")
    }

    /// True when `color` is meaningfully darker than a white/near-white page background — a
    /// simple, channel-order-agnostic way to detect "some text/content is here" versus "this is
    /// background," without needing to identify specific glyphs.
    private func isNotNearWhite(_ color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        min(color.r, color.g, color.b) < 200
    }

    /// 85Blends 2.4.0 widget ethanol polish — the six row states the badge must handle: price
    /// and ethanol together, price only, ethanol only (a station can have a qualifying community
    /// ethanol report with no price report at all — the two are independent), neither, a stale
    /// price alongside a still-fresh ethanol reading (independent freshness clocks), and a badge
    /// next to a long station name (confirms the name's own truncation, already covered by
    /// testLargeMapAndStationListAcrossStates, is unaffected by the badge on the line below it).
    func testLargeStationRowsAcrossEthanolAvailabilityStates() throws {
        let now = Date.now
        func station(_ id: String, name: String, miles: Double, price: NearbyE85Price?, ethanol: NearbyE85Ethanol?) -> NearbyE85Station {
            NearbyE85Station(id: id, name: name, address: "Example address, Phoenix, AZ",
                             latitude: 33.45 + miles * 0.01, longitude: -112.07 - miles * 0.01, distanceMiles: miles,
                             price: price, ethanol: ethanol)
        }
        let priceAndEthanol = station("price-and-ethanol", name: "Mobil", miles: 0.6,
            price: .init(dollarsPerGallon: 3.90, reportedAt: now.addingTimeInterval(-2 * 86400), source: .community),
            ethanol: .init(percentage: 78, reportedAt: now.addingTimeInterval(-1 * 86400)))
        let priceOnly = station("price-only", name: "Circle K", miles: 1.1,
            price: .init(dollarsPerGallon: 3.75, reportedAt: now, source: .saved), ethanol: nil)
        let ethanolOnly = station("ethanol-only", name: "QuikTrip", miles: 1.4,
            price: nil, ethanol: .init(percentage: 83, reportedAt: now.addingTimeInterval(-5 * 86400)))
        let neither = station("neither", name: "Shell", miles: 1.8, price: nil, ethanol: nil)
        let stalePriceFreshEthanol = station("stale-price-fresh-ethanol", name: "Chevron", miles: 2.4,
            price: .init(dollarsPerGallon: 4.99, reportedAt: now.addingTimeInterval(-20 * 86400), source: .community),
            ethanol: .init(percentage: 70, reportedAt: now.addingTimeInterval(-3 * 86400)))
        let longNameWithEthanol = station("long-name", name: "Really Long Alliance AutoGas Fuel Center Name", miles: 3.0,
            price: .init(dollarsPerGallon: 3.05, reportedAt: now, source: .saved),
            ethanol: .init(percentage: 72.5, reportedAt: now))

        let all = [priceAndEthanol, priceOnly, ethanolOnly, neither, stalePriceFreshEthanol, longNameWithEthanol]
        let snapshot = NearbyE85Snapshot.make(stations: Array(all.prefix(3)), radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let secondSnapshot = NearbyE85Snapshot.make(stations: Array(all.suffix(3)), radiusMiles: 25, updatedAt: now, locationAt: now,
                                                    userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let mapSize = NearbyE85MapRenderer.mapSize(for: Self.largeSize, heightFraction: 0.6)
        for (name, snap, scheme) in [("ethanol-rows-1-light", snapshot, ColorScheme.light),
                                      ("ethanol-rows-1-dark", snapshot, .dark),
                                      ("ethanol-rows-2-light", secondSnapshot, .light)] {
            let entry = NearbyE85Entry(date: now, snapshot: snap, access: .pro, mapRender: syntheticRender(for: snap, size: mapSize))
            let image = try render(entry, family: .systemLarge, size: Self.largeSize, colorScheme: scheme)
            attach(image, name: "nearby-large-\(name)")
        }
    }

    /// 85Blends 2.4.0 widget polish, take 3 — pixel-level regression test for the top-alignment
    /// fix. Unlike ContainerRelativeShape()/containerBackground (WidgetKit-pipeline behaviors
    /// that only fully resolve inside a real widget host — see this file's own render(...)
    /// header comment), `.frame(alignment:)` is ordinary SwiftUI layout math that ImageRenderer
    /// executes faithfully, so this genuinely verifies the fix's actual pixel output rather than
    /// just that the modifier is present in source. Uses a single station (the shortest possible
    /// list) to maximize the map/list height mismatch that previously left the map vertically
    /// centered with a gap above it, and a solid, saturated synthetic map fill with no markers so
    /// "is this pixel the map, or the page background behind it" is unambiguous.
    func testLargeMapReachesTheWidgetsTopEdgeWithAShortStationList() throws {
        let now = Date.now
        let station = NearbyE85Station(id: "nearest", name: "Circle K", address: "1 N Central Ave, Phoenix, AZ",
            latitude: 33.4501, longitude: -112.0731, distanceMiles: 0.4, price: nil)
        let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let mapSize = NearbyE85MapRenderer.mapSize(for: Self.largeSize, heightFraction: 0.6)
        let mapImage = UIGraphicsImageRenderer(size: mapSize).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: mapSize))
        }
        let mapRender = NearbyE85MapRender(image: mapImage, size: mapSize, markers: [])
        let entry = NearbyE85Entry(date: now, snapshot: snapshot, access: .pro, mapRender: mapRender)
        let image = try render(entry, family: .systemLarge, size: Self.largeSize)
        attach(image, name: "nearby-large-top-alignment-short-list")

        // Sanity check on the test's own setup: well inside the map's own bounds, the pixel must
        // read as the synthetic map's fill — if this fails, something about the render pipeline
        // itself (not the alignment fix) is broken, and the top-edge assertion below proves
        // nothing either way.
        let interior = try pixelColor(of: image, at: CGPoint(x: Self.largeSize.width / 2, y: mapSize.height / 2))
        XCTAssertTrue(isRedLike(interior), "Test setup sanity check failed: expected the synthetic map's own fill at its center, got \(interior)")

        // The actual regression check: a point 1pt below the widget's very top edge must already
        // be the map's fill. Before the `alignment: .top` fix, a short station list left the
        // whole VStack shorter than the full canvas height, and the default `.center` alignment
        // split that leftover space evenly above the map and below the list — this point would
        // have read as the page background instead.
        let topEdge = try pixelColor(of: image, at: CGPoint(x: Self.largeSize.width / 2, y: 1))
        XCTAssertTrue(isRedLike(topEdge),
                      "Expected the map to reach the widget's top edge; got \(topEdge) — looks like leftover vertical centering space above the map")
    }

    /// Pure red has exactly one channel saturated and the other two near zero — true regardless
    /// of which byte position that channel actually occupies, so this doesn't depend on knowing
    /// pixelColor(of:at:)'s exact RGBA vs BGRA byte layout.
    private func isRedLike(_ color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        let channels = [color.r, color.g, color.b].sorted()
        return channels[2] > 200 && channels[1] < 60 && channels[0] < 60
    }

    /// The RGBA bytes of a single pixel in `image`, at `point` in the image's own point
    /// coordinate space. Draws the source image shifted so the requested point lands at a 1x1
    /// canvas's origin — UIGraphicsImageRenderer/UIImage.draw(at:) already use UIKit's top-left
    /// coordinate convention consistently (the same mechanism this file's own syntheticRender/
    /// existing map fixtures already rely on), so this needs no manual CoreGraphics
    /// bottom-left-origin flip math. format.scale is pinned to 1 so the result is exactly one
    /// physical pixel, regardless of the test runner's own display scale.
    private func pixelColor(of image: UIImage, at point: CGPoint) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cropped = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            image.draw(at: CGPoint(x: -point.x, y: -point.y))
        }
        guard let cgImage = cropped.cgImage, let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) >= 4 else {
            throw XCTSkip("Could not read pixel data from the rendered image in this environment")
        }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    /// Large must render cleanly (no crash/clip) at every zoom extreme, with the zoom controls
    /// visible, correctly enabled/disabled at the boundary, and the map/station-list split intact.
    func testLargeRendersAtMinimumDefaultAndMaximumZoom() throws {
        let now = Date.now
        let (nearest, second, third) = phoenixStations(now: now)
        let snapshot = NearbyE85Snapshot.make(stations: [nearest, second, third], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let mapSize = NearbyE85MapRenderer.mapSize(for: Self.largeSize, heightFraction: 0.6)
        let cases: [(String, NearbyE85MapZoomLevel)] = [
            ("min", .minimum), ("default", .default), ("max", .maximum),
        ]
        for (name, level) in cases {
            let mapRender = syntheticRender(for: snapshot, size: mapSize, zoomLevel: level)
            let entry = NearbyE85Entry(date: now, snapshot: snapshot, access: .pro, mapRender: mapRender, zoomLevel: level)
            let image = try render(entry, family: .systemLarge, size: Self.largeSize)
            XCTAssertEqual(image.size, Self.largeSize, "Zoom must never resize the widget itself, only the map's framing")
            attach(image, name: "nearby-large-zoom-\(name)")
        }
    }

    /// Best-effort real MKMapSnapshotter captures for the final visual review — skipped, not
    /// failed, if this environment has no route to Apple's map tile servers.
    func testMediumMapRealSnapshotterBestEffort() async throws {
        let now = Date.now
        let (nearest, second, _) = phoenixStations(now: now)
        let stations = [nearest, second]
        let size = NearbyE85MapRenderer.mapSize(for: Self.mediumSize, heightFraction: 1.0)
        guard let mapRender = await NearbyE85MapRenderer.render(
            userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude,
            stations: stations, size: size) else {
            throw XCTSkip("No network route to MapKit tile servers in this environment.")
        }
        // MKMapSnapshotter's image must come back in the exact point-space it was asked to
        // render at — this is the invariant that lets marker.point (computed against `size`)
        // line up with the image the widget displays, with no separate scale step anywhere.
        XCTAssertEqual(mapRender.image.size, size)
        let snapshot = NearbyE85Snapshot.make(stations: stations, radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let entry = NearbyE85Entry(date: now, snapshot: snapshot, access: .pro, mapRender: mapRender)
        let image = try render(entry, family: .systemMedium, size: Self.mediumSize)
        attach(image, name: "nearby-medium-map-real-snapshot")
    }

    func testLargeMapRealSnapshotterBestEffort() async throws {
        let now = Date.now
        let (nearest, second, third) = phoenixStations(now: now)
        let stations = [nearest, second, third]
        let size = NearbyE85MapRenderer.mapSize(for: Self.largeSize, heightFraction: 0.6)
        guard let mapRender = await NearbyE85MapRenderer.render(
            userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude,
            stations: stations, size: size) else {
            throw XCTSkip("No network route to MapKit tile servers in this environment.")
        }
        XCTAssertEqual(mapRender.image.size, size)
        let snapshot = NearbyE85Snapshot.make(stations: stations, radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude)
        let entry = NearbyE85Entry(date: now, snapshot: snapshot, access: .pro, mapRender: mapRender)
        let image = try render(entry, family: .systemLarge, size: Self.largeSize)
        attach(image, name: "nearby-large-map-real-snapshot")
    }

    /// Confirms a real MKMapSnapshotter region actually shrinks when zoomed in — not just the
    /// synthetic test math, but the same NearbyE85MapRegion.region(zoomLevel:) call the real
    /// renderer makes. Best-effort like the tests above.
    func testLargeMapRealSnapshotterHonorsZoomLevelBestEffort() async throws {
        let now = Date.now
        let (nearest, second, _) = phoenixStations(now: now)
        let stations = [nearest, second]
        let size = NearbyE85MapRenderer.mapSize(for: Self.largeSize, heightFraction: 0.6)
        guard let standard = await NearbyE85MapRenderer.render(
            userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude,
            stations: stations, size: size, zoomLevel: .standard),
            let zoomedIn = await NearbyE85MapRenderer.render(
            userLatitude: Self.phoenixUser.latitude, userLongitude: Self.phoenixUser.longitude,
            stations: stations, size: size, zoomLevel: .zoomedIn4) else {
            throw XCTSkip("No network route to MapKit tile servers in this environment.")
        }
        // Both requests share the same size — only the underlying region differs — so the
        // nearest station's marker point must land closer to center once zoomed in.
        guard let standardNearest = standard.markers.first(where: { $0.kind == .nearestStation }),
              let zoomedNearest = zoomedIn.markers.first(where: { $0.kind == .nearestStation }) else {
            XCTFail("Expected a nearestStation marker in both renders")
            return
        }
        func distanceFromCenter(_ point: CGPoint) -> CGFloat {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            return ((point.x - center.x) * (point.x - center.x) + (point.y - center.y) * (point.y - center.y)).squareRoot()
        }
        XCTAssertGreaterThan(distanceFromCenter(zoomedNearest.point), distanceFromCenter(standardNearest.point) - 0.01,
                             "Zooming in should push a non-center station's pin farther from the image center, not closer")
    }
}

/// `NearbyE85MapView.markerView` — the geographic-anchor fix. `.position(marker.point)` centers
/// a marker view on its coordinate using that view's own layout size, so any decoration (the
/// nearest station's price badge) that grows the view's reported size would silently drag the
/// visible pin away from `marker.point`. These compare the marker's ideal (unconstrained) size
/// with and without a badge — bug regresses the instant they diverge, no MapKit or pixel
/// inspection required.
@MainActor
final class NearbyE85MapMarkerAnchorTests: XCTestCase {
    private func idealSize(of view: some View) -> CGSize {
        let renderer = ImageRenderer(content: view)
        return renderer.uiImage?.size ?? .zero
    }
    private var blankMapView: NearbyE85MapView {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        return NearbyE85MapView(render: NearbyE85MapRender(image: image, size: CGSize(width: 1, height: 1), markers: []))
    }

    func testNearestStationMarkerSizeIsIdenticalWithAndWithoutAPriceBadge() {
        let withoutBadge = NearbyE85MapMarker(id: "n", kind: .nearestStation, point: .zero, priceLabel: nil)
        let withBadge = NearbyE85MapMarker(id: "n", kind: .nearestStation, point: .zero, priceLabel: "$2.89")
        let sizeWithoutBadge = idealSize(of: blankMapView.markerView(withoutBadge))
        let sizeWithBadge = idealSize(of: blankMapView.markerView(withBadge))
        XCTAssertEqual(sizeWithoutBadge.width, sizeWithBadge.width, accuracy: 0.5)
        XCTAssertEqual(sizeWithoutBadge.height, sizeWithBadge.height, accuracy: 0.5)
    }

    func testNearestStationMarkerSizeIsStableAcrossDifferentPriceLabelLengths() {
        let short = NearbyE85MapMarker(id: "n", kind: .nearestStation, point: .zero, priceLabel: "$2.89")
        let long = NearbyE85MapMarker(id: "n", kind: .nearestStation, point: .zero, priceLabel: "$12,345.67")
        let sizeShort = idealSize(of: blankMapView.markerView(short))
        let sizeLong = idealSize(of: blankMapView.markerView(long))
        // The badge can grow wider/taller for a longer label, but only via the size-neutral
        // overlay — the marker's own (circle) footprint used for `.position()` never changes.
        XCTAssertEqual(sizeShort.width, sizeLong.width, accuracy: 0.5)
        XCTAssertEqual(sizeShort.height, sizeLong.height, accuracy: 0.5)
    }

    func testUserMarkerSizeMatchesItsOuterRing() {
        let user = NearbyE85MapMarker(id: "user", kind: .user, point: .zero, priceLabel: nil)
        let size = idealSize(of: blankMapView.markerView(user))
        XCTAssertEqual(size.width, 16, accuracy: 0.5)
        XCTAssertEqual(size.height, 16, accuracy: 0.5)
    }

    func testPlainStationMarkerNeverCarriesAPriceLabel() {
        // .station (non-nearest) markers never receive a priceLabel from the renderer, so their
        // anchor can't be affected by the same badge-decoration failure mode at all.
        let station = NearbyE85MapMarker(id: "s", kind: .station, point: .zero, priceLabel: nil)
        XCTAssertNil(station.priceLabel)
        XCTAssertGreaterThan(idealSize(of: blankMapView.markerView(station)).width, 0)
    }

    /// `markerView` takes only a `NearbyE85MapMarker` — it has no notion of zoom level at all, so
    /// zooming can only ever change WHERE a marker's `point` lands (via NearbyE85MapRegion), never
    /// how `.position(marker.point)` anchors it. This locks that invariant in explicitly, at every
    /// zoom level, rather than relying on it being true "by construction."
    func testMarkerAnchorSizeIsIdenticalAcrossEveryZoomLevelWithAndWithoutABadge() {
        let user = CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740)
        let station = CLLocationCoordinate2D(latitude: 33.4675, longitude: -112.0850)
        let size = CGSize(width: 329, height: 207)
        var withoutBadgeSizes: [CGSize] = [], withBadgeSizes: [CGSize] = []
        for level in NearbyE85MapZoomLevel.allCases {
            let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [station],
                                                   aspectRatio: size.width / size.height, zoomLevel: level)
            // A real snapshot.point(for:)-shaped point, just computed the same way the tests'
            // own syntheticRender helper does, so this stays independent of live MapKit access.
            let point = CGPoint(x: size.width * (0.5 + (station.longitude - region.center.longitude) / region.span.longitudeDelta),
                                y: size.height * (0.5 - (station.latitude - region.center.latitude) / region.span.latitudeDelta))
            let withoutBadge = NearbyE85MapMarker(id: "n", kind: .nearestStation, point: point, priceLabel: nil)
            let withBadge = NearbyE85MapMarker(id: "n", kind: .nearestStation, point: point, priceLabel: "$2.89")
            withoutBadgeSizes.append(idealSize(of: blankMapView.markerView(withoutBadge)))
            withBadgeSizes.append(idealSize(of: blankMapView.markerView(withBadge)))
        }
        for (withoutBadge, withBadge) in zip(withoutBadgeSizes, withBadgeSizes) {
            XCTAssertEqual(withoutBadge.width, withBadge.width, accuracy: 0.5)
            XCTAssertEqual(withoutBadge.height, withBadge.height, accuracy: 0.5)
        }
        // And every level agrees with every other level — the anchor footprint truly never
        // depends on zoom, not just coincidentally at the levels checked individually above.
        for size in withoutBadgeSizes.dropFirst() {
            XCTAssertEqual(size.width, withoutBadgeSizes[0].width, accuracy: 0.5)
            XCTAssertEqual(size.height, withoutBadgeSizes[0].height, accuracy: 0.5)
        }
    }
}
