import SwiftUI
import WidgetKit
import AppIntents
#if NEARBY_WIDGET_TESTING
@testable import EightyFiveBlends
#endif

nonisolated struct NearbyE85Entry: TimelineEntry {
    let date: Date
    let snapshot: NearbyE85Snapshot?
    var mapRender: NearbyE85MapRender? = nil
    // Only meaningful for .systemLarge — Medium/Small always render at .default regardless of
    // this value (see NearbyE85Provider.mapRender).
    var zoomLevel: NearbyE85MapZoomLevel = .default
    // 85Blends 2.4.0 widget polish — true while the manual refresh button should show its
    // in-progress appearance (see NearbyE85RefreshFeedback). Purely a presentation flag: it
    // never implies the snapshot above is any newer than before, and setting it has no effect
    // on `snapshot.updatedAt`/`locationAt`/any station's `priceReportedAt`.
    var isRefreshing: Bool = false
}

/// 85Blends 2.4.0 widget polish — named, testable layout constants for the manual refresh
/// control's inset from the widget edge, so the values aren't scattered as unlabeled magic
/// numbers across three call sites. Not private: EightyFiveBlendsTests exercises these directly
/// (dual-compiled into that target — see this file's own testing note near NearbyE85MapView).
enum NearbyE85WidgetLayout {
    /// Small/Medium's standalone refresh button previously sat only 4pt from the top/trailing
    /// edge, which read as cramped/glued to the corner. This is the new, more comfortable inset.
    static let smallMediumRefreshInset: CGFloat = 10
    /// Large's zoom/refresh control stack previously sat only 8pt from the map's trailing edge.
    static let largeControlsTrailingInset: CGFloat = 14
}

/// The single default tap destination for a whole widget — used as-is for small (one action,
/// the entire widget) and medium (one action, always Stations), and as large's fallback for any
/// area not covered by one of its own explicit `Link` regions (map, each row). Pure and
/// side-effect-free so it's directly testable independent of rendering.
nonisolated enum NearbyE85WidgetURLResolver {
    static func widgetURL(family: WidgetFamily, snapshot: NearbyE85Snapshot?) -> URL {
        if family == .systemSmall, let snapshot, snapshot.state == .ready, let first = snapshot.stations.first {
            return NearbyE85DeepLink.directionsURL(stationID: first.id)
        }
        return NearbyE85DeepLink.stationsURL()
    }
}

/// 85Blends 2.4.0 zoom-boundary tap-through fix — WidgetKit does not guarantee a `.disabled()`
/// `Button` consumes its own tap region; a disabled interactive element can let the tap fall
/// through to a sibling/underlying `Link` instead. Confirmed on-device: before this fix, the
/// Large widget's Zoom In button at max zoom (`.disabled(true)`) mis-fired into the map's
/// "open Stations" `Link` underneath in 6 of 8 real taps.
///
/// Only a genuinely transient, re-entrancy-guarding state may ever actually disable a button
/// here — the refresh button while a refresh is already in flight, so a second tap can't queue a
/// redundant one. A boundary state that can persist indefinitely (zoom sitting at min/max,
/// possibly for the widget's entire lifetime) must NEVER actually disable the button — it stays
/// visually dimmed only (`isVisuallyDimmed`), remaining a real, always-tappable AppIntent target.
/// This is safe because `NearbyE85ZoomAction`'s underlying step function is already a clamped,
/// harmless no-op at the boundary (see NearbyE85MapZoomLevelTests/NearbyE85ZoomActionTests) — so
/// letting the tap actually reach the intent again costs nothing.
enum NearbyE85IconButtonInteractivity {
    /// Whether a button built via `nearbyE85IconButton` should actually be `.disabled()`.
    /// Deliberately ignores any "visually dimmed" state — only `isRefreshing` may disable.
    static func shouldActuallyDisable(isRefreshing: Bool) -> Bool { isRefreshing }
}

/// One shared button style for every interactive widget control (Large's zoom pair, and the
/// refresh action on every family) — a single definition so a future style tweak, or the
/// refresh action itself, never has to be duplicated per family. `size`/`iconSize` default to
/// the 44pt tap target Large's zoom buttons already shipped with; Small/Medium's standalone
/// refresh button asks for a smaller footprint since it's sharing space with actual content
/// rather than floating over an otherwise-empty map edge.
///
/// `isVisuallyDimmed` (zoom's min/max boundary) and `isRefreshing` (refresh's in-flight state)
/// both dim the icon's foreground style, but only `isRefreshing` ever reaches
/// `.disabled(...)` — see `NearbyE85IconButtonInteractivity` above for why that split matters.
///
/// 85Blends 2.4.0 widget quality pass — `size` (the drawn circle) and `tapTargetSize` (the
/// actual interactive region) are deliberately independent. Large's zoom/refresh stack wants a
/// visibly smaller circle so it obscures less of the map, without shrinking the tappable area
/// below Apple's ~44pt recommended minimum. `tapTargetSize` defaults to `size` — every
/// pre-existing call site (e.g. the standalone refresh button below) is untouched by this and
/// keeps its identical, single-size tap target. `.contentShape(Circle())` on the OUTER frame is
/// what actually makes the full `tapTargetSize` tappable; without it SwiftUI would only
/// hit-test the visually-drawn inner circle, silently undoing the decoupling. This is purely a
/// hit-testing change — it never touches `.disabled(...)`, so the boundary/refresh distinction
/// `NearbyE85IconButtonInteractivity` enforces is completely unaffected.
private func nearbyE85IconButton(systemImage: String, intent: some AppIntent, isVisuallyDimmed: Bool = false,
                                  isRefreshing: Bool = false, size: CGFloat = 44, tapTargetSize: CGFloat? = nil,
                                  iconSize: CGFloat = 13, label: String) -> some View {
    let isVisuallyInactive = isVisuallyDimmed || isRefreshing
    return Button(intent: intent) {
        Group {
            if isRefreshing {
                ProgressView()
                    .scaleEffect(0.72)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .bold))
            }
        }
        .foregroundStyle(isVisuallyInactive ? .secondary : .primary)
        .frame(width: size, height: size)
        .background(.thinMaterial, in: Circle())
        .shadow(radius: 1)
        .frame(width: tapTargetSize ?? size, height: tapTargetSize ?? size)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(NearbyE85IconButtonInteractivity.shouldActuallyDisable(isRefreshing: isRefreshing))
    .accessibilityLabel(isRefreshing ? "Refreshing Nearby E85 data" : label)
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
            .widgetURL(NearbyE85WidgetURLResolver.widgetURL(family: family, snapshot: entry.snapshot))
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
                    station(first, compact: false, showsEthanol: true)
                    Spacer(minLength: 0)
                    footer(snapshot)
                }
                // The whole widget is one tap target that starts directions — a single clear
                // announcement beats VoiceOver reading out the name/distance/price separately
                // and leaving the actual tap behavior unstated.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(directionsAccessibilityLabel(for: first))
            } else {
                fallbackBody
            }
        }
        .padding(widgetMargins)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A sibling overlay, not nested inside the directions tap target above — the refresh
        // button is its own independent Button(intent:), so tapping it fires only the refresh
        // AppIntent instead of falling through to the whole-widget directions widgetURL.
        .overlay(alignment: .topTrailing) { refreshButton.padding(NearbyE85WidgetLayout.smallMediumRefreshInset) }
    }

    // MARK: - Medium — map-only: "Where am I, and where is E85 around me?"

    @ViewBuilder private var mediumContent: some View {
        if let snapshot = entry.snapshot, snapshot.state == .ready, let mapRender = entry.mapRender {
            mapArea(mapRender, snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stationsAccessibilityLabel)
                // Sibling overlay of the map, not nested inside its tap region — see
                // smallContent's identical comment above.
                .overlay(alignment: .topTrailing) { refreshButton.padding(NearbyE85WidgetLayout.smallMediumRefreshInset) }
        } else if let snapshot = entry.snapshot, snapshot.state == .ready, let first = snapshot.stations.first {
            // No map yet (offline first render, or an older cached snapshot with no user
            // coordinate) — degrade to the small-style information card rather than a blank map.
            // Medium always opens Stations regardless of what's shown, never directions.
            VStack(alignment: .leading, spacing: 6) {
                header
                station(first, compact: false)
                Spacer(minLength: 0)
                footer(snapshot)
            }
            .padding(widgetMargins)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stationsAccessibilityLabel)
            .overlay(alignment: .topTrailing) { refreshButton.padding(NearbyE85WidgetLayout.smallMediumRefreshInset) }
        } else {
            smallContent
        }
    }

    // MARK: - Large — map on top, readable station list below

    // Deliberately not one global widgetURL for the whole widget: the map and each row are
    // independent Link regions so tapping a row can never fall through to the map's "open
    // Stations" action (or vice versa) — see NearbyE85WidgetURLResolver's doc comment for the
    // fallback region any leftover, unLink-covered area (e.g. the divider) still uses.
    // 85Blends 2.4.0 widget polish, take 2 — physical-device testing showed the previous
    // .clipShape(ContainerRelativeShape()) fix (removed below) did NOT resolve a persistent,
    // few-pixel strip of the widget/container background visible above the map's top edge, in
    // both Light and Dark Mode. A screenshot predating that fix showed substantially the same
    // strip, so the original "independent anti-aliasing mismatch" diagnosis was incomplete.
    //
    // Medium — the one family with no reported strip — renders mapArea(...) directly as its
    // content, wrapped in no Link/Button at all; its own tap behavior comes entirely from the
    // widget-level .widgetURL(...) in NearbyE85WidgetView.body, never from an interactive view
    // inside its own tree. Large was the only family that wrapped the VISUAL map content itself
    // inside a Link. That is the one concrete structural difference between Large and its
    // known-good Medium control — MKMapSnapshotter usage, NearbyE85MapView, containerBackground,
    // and contentMarginsDisabled() are all identical between them — so the map below is now
    // rendered directly, unwrapped, exactly like Medium, and the "open Stations" tap target
    // moves to a separate, fully transparent Link layered on top of it instead.
    @ViewBuilder private var largeContent: some View {
        if let snapshot = entry.snapshot, snapshot.state == .ready, !snapshot.stations.isEmpty {
            VStack(spacing: 0) {
                if let mapRender = entry.mapRender {
                    // Controls are a SIBLING on top of the transparent Link, not nested inside
                    // it — each stays its own independent tap target, so a tap on + / - invokes
                    // that button's AppIntent instead of falling through to the map's "open
                    // Stations" Link underneath. Z-order (first = bottom): visual map, then the
                    // invisible tap layer, then the controls on top of both.
                    ZStack(alignment: .trailing) {
                        mapArea(mapRender, snapshot: snapshot)
                        // Invisible interaction layer, sized identically to mapArea(...) above
                        // (same explicit width/height, not an independent maxHeight: .infinity)
                        // so it can never influence this ZStack's own size — it only ever matches
                        // whatever size the visual map itself already establishes.
                        Link(destination: NearbyE85DeepLink.stationsURL()) {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .frame(height: mapRender.size.height)
                        .accessibilityLabel(stationsAccessibilityLabel)
                        NearbyE85MapControls(currentZoomLevel: entry.zoomLevel, isRefreshing: entry.isRefreshing)
                            .padding(.trailing, NearbyE85WidgetLayout.largeControlsTrailingInset)
                    }
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
            // ContainerRelativeShape() removed here — see this property's own header comment.
            // It measurably did not fix the strip on a physical device, and WidgetKit already
            // clips every widget's content to its own corner radius automatically; Medium's
            // corners already rely on exactly that system behavior with no explicit clip at all.
            // Keeping a clip that provably didn't fix the reported bug would just be a second,
            // redundant no-op sitting on top of the system's own clipping.
        } else {
            smallContent
        }
    }

    private func largeStationList(_ snapshot: NearbyE85Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Each row captures its OWN station's id at construction time — a row can never
            // accidentally route to the nearest/first station instead of the one actually tapped.
            ForEach(snapshot.stations) { item in
                Link(destination: NearbyE85DeepLink.directionsURL(stationID: item.id)) {
                    largeRow(item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(directionsAccessibilityLabel(for: item))
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
            if let ethanol = station.ethanol {
                // ViewThatFits picks the first candidate whose ideal (fixedSize) width actually
                // fits; the badge candidate is asked for honestly — it never silently truncates
                // "Reported E78" down to a bare, more-authoritative-looking "E78" to save space.
                // When there's truly not room for both, price/freshness wins outright (the
                // fallback candidate below is plain priceLine, full width, ordinary lineLimit(1)
                // truncation) and the ethanol badge is dropped entirely for that row — station
                // name/distance/price stay legible; only the least-critical element disappears.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(priceLine(station)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        ethanolBadge(ethanol)
                    }
                    Text(priceLine(station)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(priceLine(station)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }.accessibilityElement(children: .combine)
    }

    /// Compact capsule, visual-only — this row's real VoiceOver text (including ethanol
    /// freshness) comes from the outer Link's own .accessibilityLabel(directionsAccessibilityLabel
    /// (for:)) in largeStationList, which always wins over this view's own .combine anyway; hidden
    /// here defensively so the badge is never a stray, independent VoiceOver stop.
    ///
    /// Says "Reported E78", not a bare "E78" — this is a single most-recent community report (see
    /// NearbyE85Ethanol's own header), not a verified reading, and a bare percentage in an
    /// authoritative-looking capsule reads too easily as a claim about the pump itself.
    private func ethanolBadge(_ ethanol: NearbyE85Ethanol) -> some View {
        Text(ethanol.badgeText)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.green.opacity(0.85), in: Capsule())
            .fixedSize()
            .lineLimit(1)
            .accessibilityHidden(true)
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
            // Top-leading, not top-trailing: the refresh button (Medium) and the zoom/refresh
            // control stack (Large) both live on the trailing side — see mediumContent/
            // largeContent — so this stays clear of both rather than overlapping either.
            .overlay(alignment: .topLeading) {
                if snapshot.isStale(at: entry.date) {
                    freshnessBadge("Older location")
                }
            }
    }

    private var stationsAccessibilityLabel: String { "Open Nearby E85 stations" }

    /// Small/Medium's standalone refresh button — Large gets the same action via
    /// NearbyE85MapControls' stack instead, alongside its zoom buttons. Tap target (`size: 30`)
    /// is unchanged from before this pass — only its inset from the widget edge (applied at the
    /// call site via NearbyE85WidgetLayout.smallMediumRefreshInset) and its in-progress
    /// appearance are new.
    private var refreshButton: some View {
        nearbyE85IconButton(systemImage: "arrow.clockwise", intent: NearbyE85RefreshIntent(),
                            isRefreshing: entry.isRefreshing, size: 30, iconSize: 12, label: "Refresh Nearby E85 data")
    }

    // MARK: - Large's map controls (zoom + refresh)

    /// Independent tap targets stacked on the map's trailing edge — a sibling overlay of the
    /// map's Link (see largeContent), never nested inside it, so each button's AppIntent fires
    /// on its own tap instead of the map's "open Stations" Link firing underneath it. Medium
    /// never shows these and never reads/writes the zoom preference the first two drive; all
    /// three families share the exact same refresh action via the third button.
    private struct NearbyE85MapControls: View {
        let currentZoomLevel: NearbyE85MapZoomLevel
        // 85Blends 2.4.0 — only the refresh button below reads this; the zoom buttons above it
        // are completely independent AppIntents/state and are never disabled or altered by it.
        var isRefreshing: Bool = false

        // 85Blends 2.4.0 widget quality pass — real-device feedback was that this stack covered
        // too much of the map. Each button keeps its full 44pt tap target (`tapTargetSize: 44`,
        // Apple's recommended minimum — real-device feedback was about visual bulk, not
        // difficulty tapping, so the target itself must not shrink) while the drawn circle
        // itself shrinks to 36pt and the stack packs tighter (`spacing: 4`, down from 8) — both
        // reduce how much of the map is visually covered without reducing tappable area or
        // moving any button's center point.
        var body: some View {
            VStack(spacing: 4) {
                // isVisuallyDimmed only — never .disabled() — so a tap at the boundary is still
                // captured by this button instead of falling through to the map's Stations Link
                // underneath. See NearbyE85IconButtonInteractivity's header for why.
                nearbyE85IconButton(systemImage: "plus", intent: NearbyE85ZoomInIntent(),
                                    isVisuallyDimmed: currentZoomLevel.isAtMaximum, size: 36, tapTargetSize: 44,
                                    label: "Zoom in nearby E85 map")
                nearbyE85IconButton(systemImage: "minus", intent: NearbyE85ZoomOutIntent(),
                                    isVisuallyDimmed: currentZoomLevel.isAtMinimum, size: 36, tapTargetSize: 44,
                                    label: "Zoom out nearby E85 map")
                nearbyE85IconButton(systemImage: "arrow.clockwise", intent: NearbyE85RefreshIntent(),
                                    isRefreshing: isRefreshing, size: 36, tapTargetSize: 44,
                                    label: "Refresh Nearby E85 data")
            }
        }
    }

    // Shared by smallContent's whole-widget label and each row's Link label in
    // largeStationList — one place enriches the VoiceOver announcement with ethanol for both
    // families at once. The visible badge in largeRow says "Reported E78", not the freshness
    // ("updated 1 day ago") that qualified it for display — that lives here instead, so
    // VoiceOver users get the same information sighted users get from the badge plus its caption.
    private func directionsAccessibilityLabel(for station: NearbyE85Station) -> String {
        var label = "Get directions to \(station.name), approximately \(String(format: "%.1f", station.distanceMiles)) miles away"
        if let ethanol = station.ethanol {
            label += ". Community reported \(ethanol.labelText), \(ethanol.accessibilityAgeText(at: entry.date))"
        }
        return label
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

    // `showsEthanol` defaults to false so mediumContent's degraded "no map yet" fallback — which
    // calls this same helper — stays byte-for-byte unchanged; only smallContent opts in. Small's
    // own accessibility label already comes entirely from directionsAccessibilityLabel(for:)
    // (children: .ignore below it), so the ethanol Text added here is a purely visual addition —
    // its VoiceOver content lives there instead, not in this view's own (unused) combined label.
    @ViewBuilder private func station(_ station: NearbyE85Station, compact: Bool, showsEthanol: Bool = false) -> some View {
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
            // No placeholder when absent — the `if let` simply contributes no sibling, so the
            // VStack collapses with no leftover gap (spacing only applies between views that
            // actually exist).
            if showsEthanol, let ethanol = station.ethanol {
                ethanolLine(ethanol)
            }
        }.accessibilityElement(children: .combine)
    }

    /// "Reported E78 · 1d ago" — price stays visually dominant (title2/subheadline bold above);
    /// this is deliberately caption2/secondary with only the value itself tinted, mirroring the
    /// main app's own CommunityEthanolPreview treatment (value in the app's green/accent color,
    /// the "reported X ago" portion muted) so the same reading looks familiar in both places.
    private func ethanolLine(_ ethanol: NearbyE85Ethanol) -> some View {
        (Text("Reported ") + Text(ethanol.labelText).foregroundStyle(.green) + Text(" · \(ethanol.agoText(at: entry.date))"))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
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
struct NearbyE85MapView: View {
    let render: NearbyE85MapRender

    var body: some View {
        ZStack {
            // 85Blends 2.4.0 widget quality pass — `render.image` is already produced at exactly
            // `render.size` points (MKMapSnapshotter.Options.size is what was requested;
            // NearbyE85MapRendererTests/testMediumMapRealSnapshotterBestEffort's own
            // `image.size == size` assertion already locks this in), so `.resizable()` has
            // nothing to actually resize today — kept anyway as a safety net against any future
            // edge case where the returned image's point-size doesn't land exactly on `size`
            // (that would only ever cost a cosmetic crop/gap; marker `.position(marker.point)`
            // below is anchored to this ZStack's own `.frame`, never to the image's own
            // dimensions, so it can never desync from this). The actual sharpness fix is letting
            // MKMapSnapshotter pick its own native device-appropriate raster scale (see
            // NearbyE85MapRenderer.render) — `.interpolation(.high)` here is just cheap insurance
            // that any future resample (e.g. if `.resizable()` above ever actually has to resize)
            // uses the sharpest filter available rather than the system default; it does nothing
            // for a same-size image like today's.
            Image(uiImage: render.image).resizable().interpolation(.high)
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

    // Not private: NearbyE85MapMarkerAnchorTests (dual-compiled into this same target via
    // NEARBY_WIDGET_TESTING) constructs marker views directly to verify decorations like the
    // price badge never change a marker's own layout size — and therefore never move the
    // geographic anchor `.position(marker.point)` uses above.
    @ViewBuilder func markerView(_ marker: NearbyE85MapMarker) -> some View {
        switch marker.kind {
        case .user:
            ZStack {
                Circle().fill(.white).frame(width: 16, height: 16)
                Circle().fill(.blue).frame(width: 12, height: 12)
            }
            .shadow(radius: 1)
        case .nearestStation:
            // The circle's own center is the geographic anchor `.position(marker.point)` uses
            // below — the price badge is attached via `.overlay` so it never contributes to this
            // view's layout size. A VStack containing both would shift the circle's center away
            // from `marker.point` whenever a badge is shown, offsetting the visible pin from its
            // true coordinate.
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .padding(5)
                .background(Color.green, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .shadow(radius: 1)
                .overlay(alignment: .top) {
                    if let priceLabel = marker.priceLabel {
                        Text(priceLabel)
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.green, in: Capsule())
                            .shadow(radius: 1)
                            .fixedSize()
                            .alignmentGuide(.top) { dimensions in dimensions.height + 2 }
                    }
                }
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
