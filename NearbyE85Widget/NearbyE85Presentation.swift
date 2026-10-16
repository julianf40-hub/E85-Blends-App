import SwiftUI
import WidgetKit
import AppIntents
#if NEARBY_WIDGET_TESTING
@testable import EightyFiveBlends
#endif

nonisolated struct NearbyE85Entry: TimelineEntry {
    let date: Date
    let snapshot: NearbyE85Snapshot?
    // 85Blends 2.4.0 Pro gate — what this entry is allowed to render. Deliberately NOT defaulted:
    // a TimelineEntry for a Pro-gated widget must never fall open by omission, so every producer
    // (NearbyE85Provider, previews, tests) states it explicitly. Only `.pro` entries ever carry a
    // snapshot/mapRender — see NearbyE85Provider.lockedEntry.
    let access: NearbyE85WidgetAccessStatus
    var mapRender: NearbyE85MapRender? = nil
    // Only meaningful for .systemLarge — Medium/Small always render at .default regardless of
    // this value (see NearbyE85Provider.mapRender).
    var zoomLevel: NearbyE85MapZoomLevel = .default
    // 85Blends 2.4.0 widget polish — true while the manual refresh button should show its
    // in-progress appearance (see NearbyE85RefreshFeedback). Purely a presentation flag: it
    // never implies the snapshot above is any newer than before, and setting it has no effect
    // on `snapshot.updatedAt`/`locationAt`/any station's `priceReportedAt`.
    var isRefreshing: Bool = false
    // 85Blends 2.4.1 — true when the cached snapshot's stations are no longer geographically
    // relevant (the user travelled far enough that every one of them fell outside the original
    // search radius) — see NearbyE85AreaRelevance. Purely a presentation flag computed fresh
    // per entry, exactly like `isRefreshing` above: it never mutates `snapshot` itself, so a
    // `.ready` snapshot can still be present on an entry whose `isOutOfArea` is true — every
    // render site must check this explicitly rather than trusting `snapshot.state` alone.
    var isOutOfArea: Bool = false
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

    /// 85Blends 2.4.0 Pro gate — what NearbyE85WidgetView.body actually installs. A non-Pro shell
    /// (locked or verify) always opens the app at Stations, never a directions link, regardless of
    /// family or of any snapshot that might (defensively) be attached to the entry; the app's own
    /// entitlement gate then decides between the ordinary route and the paywall — see
    /// NearbyE85WidgetEntitlementRoute. `.pro` is exactly the pre-existing rule above.
    static func widgetURL(family: WidgetFamily, snapshot: NearbyE85Snapshot?, access: NearbyE85WidgetAccessStatus,
                          isOutOfArea: Bool = false) -> URL {
        guard access.permitsWidgetInteraction else { return NearbyE85DeepLink.stationsURL() }
        // 85Blends 2.4.1 — an out-of-area entry must never ship a stale directions link (the
        // nearest station it remembers is for a place the user has since left); always Stations,
        // exactly like the non-Pro shells above.
        guard !isOutOfArea else { return NearbyE85DeepLink.stationsURL() }
        return widgetURL(family: family, snapshot: snapshot)
    }
}

/// 85Blends 2.4.0 Pro gate — every user-facing string the non-Pro shells show, in one place so the
/// "unknown must never read as Free/expired/upgrade" rule is something a test can actually hold the
/// copy to (see NearbyE85WidgetProGateTests), not just a comment. Not private for that reason.
nonisolated enum NearbyE85WidgetAccessCopy {
    static let title = "Nearby E85"
    static let proName = "85Blends Pro"
    /// Small (`.free`).
    static let smallLockedHeadline = "Unlock the Nearby E85 widget"
    static let smallLockedAction = "Open 85Blends"
    /// Medium and Large (`.free`).
    static let lockedHeadline = "Nearby E85 on your Home Screen"
    static let lockedAvailability = "Available with 85Blends Pro"
    static let lockedAction = "Open 85Blends to unlock"
    /// Every family (`.unknown`) — deliberately neutral: this state means "the app hasn't told the
    /// widget anything authoritative yet," which is just as true for a Pro subscriber on a fresh
    /// install as for anyone else, so it must not suggest the user lacks Pro.
    static let unverifiedHeadline = "Verify Pro Access"
    static let unverifiedBody = "Open 85Blends to verify your widget access."
    /// Everything the `.unknown` shell can ever display — what the neutrality test scans.
    static let unverifiedStrings = [title, unverifiedHeadline, unverifiedBody]
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

/// 85Blends 2.4.1 Phase 2F tinted-mode fix — the pure decision nearbyE85IconButton's chrome
/// branches on, pulled out so it's directly unit-testable. Deliberately NOT a pixel-rendering
/// test: WidgetKit's actual accented-mode compositing (which tints content white and only
/// preserves opacity — see this function's own call site comment) is applied by WidgetKit's
/// real host process, not by generic SwiftUI rendering (ImageRenderer renders every literal
/// color/opacity value faithfully but doesn't apply that host-level recoloring at all), so the
/// only thing a test here can honestly prove is that accented mode selects the outlined (not
/// opaque-material) treatment — not that the result is visually correct on a real Home Screen.
/// See this file's own render(...) header for the same ImageRenderer-vs-WidgetKit-host
/// distinction made elsewhere in this codebase.
enum NearbyE85IconButtonChrome {
    static func usesOutlinedTreatment(renderingMode: WidgetRenderingMode) -> Bool {
        renderingMode == .accented
    }
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
// 85Blends 2.4.1 Phase 2F tinted-mode fix, confirmed working on a physical iPhone 17 Pro Max —
// and confirmed, by a LATER round of screenshots plus Apple's own documentation, to work for a
// different reason than originally written here. `.accented` mode does NOT give the "accent
// group" and "default group" two different colors on this app's target platforms — Apple's
// "Optimizing your widget for accented rendering mode and Liquid Glass" guide states plainly
// that iOS/macOS "tints primary and accented content white" (both groups); only watchOS gets a
// second, watch-face-derived color. The `.widgetAccentable()` call below is therefore inert
// here — real contrast comes from swapping the opaque `.thinMaterial` circle for a thin stroked
// outline with mostly-transparent interior specifically in accented mode: a stroke (painted) vs.
// empty space (fully transparent) differs in OPACITY, which IS preserved under accented
// compositing, unlike hue. `.fullColor`/`.vibrant` (ordinary Light and Dark Mode) keep the exact
// pre-existing `.thinMaterial` circle, byte-for-byte unchanged.
private func nearbyE85IconButton(systemImage: String, intent: some AppIntent, renderingMode: WidgetRenderingMode,
                                  isVisuallyDimmed: Bool = false, isRefreshing: Bool = false, size: CGFloat = 44,
                                  tapTargetSize: CGFloat? = nil, iconSize: CGFloat = 13, label: String) -> some View {
    let isVisuallyInactive = isVisuallyDimmed || isRefreshing
    return Button(intent: intent) {
        ZStack {
            if NearbyE85IconButtonChrome.usesOutlinedTreatment(renderingMode: renderingMode) {
                Circle().strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
            } else {
                Circle().fill(.thinMaterial).shadow(radius: 1)
            }
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
            // Inert outside `.accented` mode — fullColor/vibrant never alter colors based on
            // group membership, so this has zero visual effect in ordinary Light/Dark Mode.
            .widgetAccentable()
        }
        .frame(width: size, height: size)
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
    // 85Blends 2.4.1 Phase 2F — read once here, passed down to nearbyE85IconButton so its
    // tinted-mode outline treatment only applies under genuine accented rendering.
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        content
            .containerBackground(.background, for: .widget)
            .widgetURL(NearbyE85WidgetURLResolver.widgetURL(family: family, snapshot: entry.snapshot, access: entry.access,
                                                             isOutOfArea: entry.isOutOfArea))
            .privacySensitive()
    }

    // 85Blends 2.4.0 Pro gate — access is the OUTER switch, family the inner one, so the three
    // shipped Pro layouts below (`proContent`) are reached through exactly the same
    // family dispatch as before and are otherwise untouched. A non-Pro entry never reaches any
    // view that renders a snapshot, map, price, ethanol, Link, or AppIntent button.
    @ViewBuilder var content: some View {
        switch entry.access {
        case .pro: proContent
        case .free: lockedContent
        case .unknown: unverifiedContent
        }
    }

    @ViewBuilder private var proContent: some View {
        switch family {
        case .systemMedium: mediumContent
        case .systemLarge: largeContent
        default: smallContent
        }
    }

    // MARK: - Non-Pro shells (85Blends 2.4.0 Pro gate)
    //
    // Text and SF Symbols only: no placeholder map, no sample stations, no blurred/redacted
    // "preview" of Pro content, no refresh/zoom controls, no per-region Links. The whole widget
    // is one tap target (the widget-level .widgetURL in body — always Stations for these; see
    // NearbyE85WidgetURLResolver.widgetURL(family:snapshot:access:)). AppTheme isn't available in
    // the widget extension, so the PRO badge below uses a literal matching AppTheme.Colors.
    // stationYellow rather than importing anything new.

    private static let proBadgeColor = Color(red: 0.98, green: 0.78, blue: 0.20)

    private var proBadge: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Self.proBadgeColor, in: Capsule())
            .accessibilityHidden(true)
    }

    private var lockedAccessibilityLabel: String {
        "Nearby E85 widget. Available with 85Blends Pro. Open 85Blends to unlock."
    }

    @ViewBuilder private var lockedContent: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                header
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "crown.fill").foregroundStyle(Self.proBadgeColor)
                    Text(NearbyE85WidgetAccessCopy.proName)
                }
                .font(.caption.weight(.bold))
                Text(NearbyE85WidgetAccessCopy.smallLockedHeadline)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2).minimumScaleFactor(0.85)
                Text(NearbyE85WidgetAccessCopy.smallLockedAction)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(widgetMargins)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lockedAccessibilityLabel)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { header; proBadge }
                Spacer(minLength: 0)
                if family == .systemLarge {
                    Image(systemName: "crown.fill")
                        .font(.title2).foregroundStyle(Self.proBadgeColor)
                }
                Text(NearbyE85WidgetAccessCopy.lockedHeadline)
                    .font(family == .systemLarge ? .title3.weight(.semibold) : .headline)
                    .lineLimit(2)
                Text(NearbyE85WidgetAccessCopy.lockedAvailability)
                    .font(.caption).foregroundStyle(.secondary)
                Text(NearbyE85WidgetAccessCopy.lockedAction)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(widgetMargins)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lockedAccessibilityLabel)
        }
    }

    /// `.unknown` — see NearbyE85WidgetAccessCopy.unverified* for why this wording is neutral.
    private var unverifiedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            Text(NearbyE85WidgetAccessCopy.unverifiedHeadline)
                .font(family == .systemSmall ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(2).minimumScaleFactor(0.85)
            Text(NearbyE85WidgetAccessCopy.unverifiedBody)
                .font(family == .systemSmall ? .caption2 : .caption).foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(widgetMargins)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nearby E85 widget. \(NearbyE85WidgetAccessCopy.unverifiedHeadline). \(NearbyE85WidgetAccessCopy.unverifiedBody)")
    }

    // MARK: - Small — information-first nearest-station card (unchanged visual design)

    private var smallContent: some View {
        Group {
            if !entry.isOutOfArea, let snapshot = entry.snapshot, snapshot.state == .ready, let first = snapshot.stations.first {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    station(first, compact: false, showsEthanol: true)
                    Spacer(minLength: 0)
                    footer(snapshot, staleText: "Older location")
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
        if !entry.isOutOfArea, let snapshot = entry.snapshot, snapshot.state == .ready, let mapRender = entry.mapRender {
            mapArea(mapRender, snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stationsAccessibilityLabel)
                // Sibling overlay of the map, not nested inside its tap region — see
                // smallContent's identical comment above.
                .overlay(alignment: .topTrailing) { refreshButton.padding(NearbyE85WidgetLayout.smallMediumRefreshInset) }
        } else if !entry.isOutOfArea, let snapshot = entry.snapshot, snapshot.state == .ready, let first = snapshot.stations.first {
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
        if !entry.isOutOfArea, let snapshot = entry.snapshot, snapshot.state == .ready, !snapshot.stations.isEmpty {
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
            // 85Blends 2.4.0 widget polish, take 3 — real-device testing after take 2 (the
            // Link-decoupling above) confirmed interaction works correctly but the top strip
            // persisted, ruling out the Link wrapper as its cause. The map's height is fixed at
            // exactly 60% of the widget's display height (see NearbyE85MapRenderer.mapSize /
            // NearbyE85Widget's mapRender(for:context:zoomLevel:)), while largeStationList below
            // has no forcing frame at all — its height is purely intrinsic (rows + spacing +
            // padding). Nothing guarantees those two heights plus the Divider sum to exactly the
            // full canvas height, so this VStack's own natural height can be shorter than the
            // frame below expands it to. `alignment: .top` (SwiftUI's frame default is `.center`
            // when omitted) is what actually matters here: without it, any leftover vertical
            // space split evenly above the map and below the list — the top half exposed the
            // widget/container background as a visible strip, while the bottom half was
            // invisible against the same-colored background behind the list. Small already does
            // this correctly (`alignment: .topLeading` on its own frame); Medium never needed it
            // since its map is sized to 100% of the canvas, leaving nothing to redistribute.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    // 85Blends 2.4.1 Phase 2F tinted-mode fix, REVISED — see markerView's own comment for the
    // full correction. `.widgetAccentable()` doesn't give the capsule a different color from
    // the text on iOS (Apple's own docs: accented mode "tints primary and accented content
    // white" — both groups). A second round of on-device screenshots confirmed the original
    // fix here didn't work for that reason. Real contrast in `.accented` mode comes from a
    // reduced-opacity fill plus a fully-opaque stroke outline, vs. the text's own full opacity —
    // a density difference that survives accented compositing even though hue doesn't.
    // `.fullColor` (ordinary Light/Dark Mode) keeps the exact pre-existing solid fill.
    private func ethanolBadge(_ ethanol: NearbyE85Ethanol) -> some View {
        Text(ethanol.badgeText)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background {
                if renderingMode == .accented {
                    Capsule().fill(Color.white.opacity(0.35))
                        .overlay(Capsule().stroke(Color.white, lineWidth: 1))
                } else {
                    Capsule().fill(Color.green.opacity(0.85))
                }
            }
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
        // 85Blends 2.4.1 Phase 2F — this entry's own date, not the map's render-time `now`, so
        // the nearest station's price badge re-evaluates freshness correctly even though the
        // same mapRender (and its markers' raw, unevaluated prices) is reused across every
        // entry in the timeline. See NearbyE85MapMarker's own header for why.
        NearbyE85MapView(render: mapRender, referenceDate: entry.date)
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
        nearbyE85IconButton(systemImage: "arrow.clockwise", intent: NearbyE85RefreshIntent(), renderingMode: renderingMode,
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
        // 85Blends 2.4.1 Phase 2F — this struct is its own View, so it reads the environment
        // directly rather than taking it as an init parameter.
        @Environment(\.widgetRenderingMode) private var renderingMode

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
                nearbyE85IconButton(systemImage: "plus", intent: NearbyE85ZoomInIntent(), renderingMode: renderingMode,
                                    isVisuallyDimmed: currentZoomLevel.isAtMaximum, size: 36, tapTargetSize: 44,
                                    label: "Zoom in nearby E85 map")
                nearbyE85IconButton(systemImage: "minus", intent: NearbyE85ZoomOutIntent(), renderingMode: renderingMode,
                                    isVisuallyDimmed: currentZoomLevel.isAtMinimum, size: 36, tapTargetSize: 44,
                                    label: "Zoom out nearby E85 map")
                nearbyE85IconButton(systemImage: "arrow.clockwise", intent: NearbyE85RefreshIntent(), renderingMode: renderingMode,
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
    //
    // 85Blends 2.4.0 widget polish — real-device testing found Small's ethanol line pushed the
    // footer to the bottom edge (clipped/crowded): non-compact mode already gave distance its own
    // full line, so adding the ethanol line made a 5th content row where there'd only ever been 4.
    // `inlineNameAndDistance` recovers exactly that one row by combining name+distance onto a
    // single line — the same layout `compact` mode already uses — but ONLY when the ethanol line
    // is actually about to render (`showsEthanolLine`), and WITHOUT `compact`'s other effects
    // (price stays .title2/.bold, price freshness keeps its own line): those weren't the problem,
    // and shrinking them wasn't asked for. When ethanol is absent (or not requested), this
    // resolves to `compact` alone, exactly the original behavior — Medium's fallback call below
    // never passes showsEthanol, so it's completely unaffected regardless.
    @ViewBuilder private func station(_ station: NearbyE85Station, compact: Bool, showsEthanol: Bool = false) -> some View {
        let showsEthanolLine = showsEthanol && station.ethanol != nil
        let inlineNameAndDistance = compact || showsEthanolLine
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(station.name).font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(inlineNameAndDistance ? 1 : 2)
                // Spacer(minLength:) only enforces a floor, and the name's own lineLimit(1) +
                // truncation gives HStack a much wider compressible range than distance's short,
                // barely-truncatable string — so in practice a long name yields space long before
                // distance would. But neither fact is an actual guarantee: without .fixedSize()
                // here, an extreme case (very large Dynamic Type) could still force distance
                // itself to compress or wrap once the name has already hit its ellipsis-minimum.
                // .fixedSize(horizontal:true, vertical:false) makes that a real guarantee instead
                // of a practical tendency — distance always renders at its natural single-line
                // width, never wrapping or disappearing, which only matters in that same extreme
                // case (a normal short distance string already renders at its natural width
                // regardless, so this is a no-op for the common case). Applied only at this call
                // site, not to distance(_:) itself, so largeRow's own, independent distance(...)
                // usage — Large is untouched by this pass — is completely unaffected.
                if inlineNameAndDistance { Spacer(minLength: 4); distance(station).fixedSize(horizontal: true, vertical: false) }
            }
            if !inlineNameAndDistance { distance(station) }
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
            if showsEthanolLine, let ethanol = station.ethanol {
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
    // `staleText` defaults to the original wording so Medium's fallback and the "no stations"
    // fallbackBody call sites stay byte-for-byte unchanged — only Small overrides it below.
    // Small's own whole-widget tap starts directions (see smallContent's own comment and
    // NearbyE85WidgetURLResolver), never refresh — only the dedicated refresh icon refreshes — so
    // "tap to refresh" was never accurate there. This is scoped to Small specifically rather than
    // changed globally: Medium's fallback tap semantics ("always opens Stations, never directions"
    // — see mediumContent's own comment) are a separate call site this task doesn't touch.
    private func footer(_ snapshot: NearbyE85Snapshot, staleText: String = "Older location · tap to refresh") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snapshot.isStale(at: entry.date) ? staleText : "Near last app location")
            HStack(spacing: 3) {
                Text("Updated")
                Text(snapshot.updatedAt, style: .relative)
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
    }
    // 85Blends 2.4.1 Phase 2E accessibility fix — previously had no accessibility grouping at
    // all, so VoiceOver announced the header, headline, and explanation as separate fragments
    // across all four fallback states (every family routes through this). Mirrors the existing
    // `.accessibilityElement(children: .ignore)` + explicit-label pattern lockedContent/
    // unverifiedContent already use above, rather than `.combine`, so the announcement reads as
    // one clean "Nearby E85 widget. <title>. <body>." sentence instead of whatever order/
    // punctuation `.combine` would assemble from the Label + Text children.
    // Not private: EightyFiveBlendsTests exercises this directly, the same way
    // NearbyE85WidgetLayout/markerView above are deliberately left testable.
    //
    // 85Blends 2.4.1 Phase 2F — Codex P2 finding: the `.noStations` case visually shows
    // `footer(snapshot)` (whether the cached location is stale, and when it was last updated),
    // but `children: .ignore` discarded that content for VoiceOver with nothing here to replace
    // it — sighted and VoiceOver users saw/heard materially different information. The
    // `.noStations` branch below now folds that same freshness information (same
    // `snapshot.isStale(at: entry.date)` check `footer` itself uses, same `snapshot.updatedAt`)
    // into the spoken label instead. No other branch shows a footer, so no other branch changes.
    var fallbackAccessibilityLabel: String {
        let title: String
        let body: String
        if entry.isOutOfArea {
            title = "Location changed"
            body = "Open 85Blends to find nearby E85."
        } else if entry.snapshot?.state == .permissionRequired {
            title = "Location needed"
            body = "Open 85Blends to allow location and find nearby E85."
        } else if let snapshot = entry.snapshot, snapshot.state == .noStations {
            title = "No nearby E85"
            body = "None found within \(Int(snapshot.radiusMiles)) mi. \(noStationsFreshnessPhrase(for: snapshot)) Open the app to search farther."
        } else {
            title = "Find nearby E85"
            body = "Open 85Blends to refresh nearby stations."
        }
        return "Nearby E85 widget. \(title). \(body)"
    }

    /// "Location may be outdated. Updated 3 hours ago." / "Near last app location. Updated 5
    /// minutes ago." — spoken-form equivalent of `footer(_:)`'s own two-line visual status
    /// (same `isStale(at:)` call, same `updatedAt`), not a new freshness rule. Locale pinned to
    /// `en_US` since every other string in this widget is a hardcoded English literal — this is
    /// the one spot that would otherwise silently follow the device's locale instead — and so a
    /// test can assert the formatted phrase deterministically regardless of the test runner's
    /// own locale.
    private func noStationsFreshnessPhrase(for snapshot: NearbyE85Snapshot) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: snapshot.updatedAt, relativeTo: entry.date)
        let status = snapshot.isStale(at: entry.date) ? "Location may be outdated" : "Near last app location"
        return "\(status). Updated \(relative)."
    }

    private var fallbackBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if entry.isOutOfArea {
                // 85Blends 2.4.1 — distinct from every state below: there IS a cached
                // snapshot, and it may even still be `.ready`, but it's for a place the user
                // has since left (see NearbyE85AreaRelevance). Checked first so a stale
                // "permission required"/"no nearby E85" copy never masks the real reason.
                Text("Location changed").font(.headline)
                Text("Open 85Blends to find nearby E85.")
            } else if entry.snapshot?.state == .permissionRequired {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fallbackAccessibilityLabel)
    }
}

/// Overlays the user/station pins onto a pre-rendered MKMapSnapshotter image. The marker points
/// were computed once, in the same point-space as the image, so this never needs its own
/// coordinate math or a live MKMapView.
struct NearbyE85MapView: View {
    let render: NearbyE85MapRender
    // 85Blends 2.4.1 Phase 2F — Codex P2 finding: the nearest station's raw `price` on each
    // marker (see NearbyE85MapMarker's own header) is evaluated for freshness against THIS
    // date, not whatever moment the shared map image was generated at — callers always pass
    // the actual timeline entry's own `date` (see NearbyE85WidgetView.mapArea). Defaults to
    // `.now` purely so tests unconcerned with price freshness (e.g. the marker-anchor geometry
    // suite) don't all need to pass one.
    let referenceDate: Date
    // 85Blends 2.4.1 Phase 2F — see markerView's own corrected comment below for why this is
    // now read directly (instead of relying on `.widgetAccentable()` grouping, which turned
    // out to do nothing for this app's contrast problem on iOS).
    @Environment(\.widgetRenderingMode) private var renderingMode

    init(render: NearbyE85MapRender, referenceDate: Date = .now) {
        self.render = render
        self.referenceDate = referenceDate
    }

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
            // 85Blends 2.4.1 Phase 2E tinted-mode fix — in `.accented` rendering mode WidgetKit
            // treats every view as a template image, using only its alpha channel (see Apple's
            // "Optimizing your widget for accented rendering mode" guidance). The map snapshot
            // is a fully-opaque bitmap, so without this it would flatten into a single solid
            // tinted rectangle — hiding the geography and every station pin — rather than just
            // losing some color richness. `.fullColor` is the documented opt-out for exactly this
            // case. Markers below handle their own contrast separately — see markerView's own
            // Phase 2F comment for the (twice-revised, now documentation-confirmed) reasoning.
            // `widgetAccentedRenderingMode` requires iOS 18 — the production deployment target is
            // 17.6 (see CLAUDE.md), so this must stay availability-gated; on older OS versions the
            // system doesn't have an accented mode to opt out of, so no fallback is needed.
            if #available(iOS 18.0, *) {
                Image(uiImage: render.image).resizable().interpolation(.high)
                    .widgetAccentedRenderingMode(.fullColor)
            } else {
                Image(uiImage: render.image).resizable().interpolation(.high)
            }
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
    //
    // 85Blends 2.4.1 Phase 2F tinted-mode fix, REVISED — the first attempt here marked each
    // colored shape `.widgetAccentable()`, on the theory that the "accent group" and "default
    // group" render as two different colors. Confirmed wrong by a second round of physical-
    // device screenshots (pale circles, unreadable price text) AND by Apple's own documentation
    // ("Optimizing your widget for accented rendering mode and Liquid Glass": "Tints primary
    // and accented content white in iOS and macOS" — BOTH groups are white on this app's actual
    // target platforms; only watchOS gets a second, watch-face-derived color). `.widgetAccentable()`
    // is therefore a no-op for contrast on iOS and has been removed below.
    //
    // The one thing the same documentation DOES guarantee survives accented compositing is
    // opacity ("maintains opacity for transparent content... and tints them white") — exactly
    // why nearbyE85IconButton's outlined treatment above already worked: its contrast comes
    // from "painted vs. transparent," not from two different hues. Markers/badges now use the
    // same principle in `.accented` mode only: a reduced-opacity fill (lets some of whatever is
    // behind it — the map, or just less of the eventual white tint — show through) plus a
    // fully-opaque stroke/icon/text on top, so there's a real density difference regardless of
    // what single color the system actually paints everything. `.fullColor` (ordinary Light/
    // Dark Mode) keeps the exact pre-existing solid-fill look, byte-for-byte.
    @ViewBuilder func markerView(_ marker: NearbyE85MapMarker) -> some View {
        switch marker.kind {
        case .user:
            // Deliberately a different silhouette from the station pins below (a soft dot with
            // no stroke or icon, vs. their crisp ring + glyph) so the two stay visually distinct
            // by shape/density even though `.accented` mode can't give them different hues.
            ZStack {
                Circle()
                    .fill(renderingMode == .accented ? Color.white.opacity(0.35) : Color.white)
                    .frame(width: 16, height: 16)
                Circle().fill(.blue).frame(width: 12, height: 12)
            }
            .shadow(radius: 1)
        case .nearestStation:
            // The circle's own center is the geographic anchor `.position(marker.point)` uses
            // below — the price badge is attached via `.overlay` so it never contributes to this
            // view's layout size. A VStack containing both would shift the circle's center away
            // from `marker.point` whenever a badge is shown, offsetting the visible pin from its
            // true coordinate.
            //
            // 85Blends 2.4.1 Phase 2F — confirmed this badge is a genuinely SEPARATE overlay, not
            // part of the same shape: `.alignmentGuide(.top) { dimensions.height + 2 }` below
            // deliberately lies about the badge's own top anchor (claims it sits `height + gap`
            // below its real top edge), so aligning that claimed anchor with the circle's real
            // top edge pushes the whole badge straight up, clear of the circle, by exactly
            // `height + gap` points — the math doesn't produce literal frame overlap. On-device
            // screenshots nonetheless read the two as merged: the badge is now ALSO only ever
            // shown for a confirmed-fresh price (evaluated against `referenceDate` just below —
            // see NearbyE85MapMarker's own header for why that can't be baked in at render time)
            // rather than every tier, which removes most real-world crowding outright, and the
            // gap below is widened (2pt → 4pt) as a safety margin for the cases that remain — two
            // independently-shadowed, near-identical translucent-white shapes (since accented
            // mode can't give them different hues — see markerView's own header) read as touching
            // at the tightest possible gap, even though their bounding boxes never cross.
            //
            // 85Blends 2.4.1 Phase 2F — Codex P2 finding: re-evaluated here, against THIS
            // instance's `referenceDate` (the actual timeline entry being displayed), rather than
            // once at map-render time. The same rendered map is reused across every entry in a
            // timeline (see NearbyE85Provider.proInputs's own comment on why), so a price that
            // was fresh when the map was generated could cross into `.checkPrice` by the time a
            // later entry's own date arrives — e.g. the explicit midnight boundary entry
            // `NearbyE85Provider.timeline` schedules. Re-deriving the label here means that later
            // entry correctly shows the plain pin with no badge, with no new MKMapSnapshotter
            // call and no change to the marker's own geographic anchor.
            let priceLabel = marker.priceBadgeLabel(at: referenceDate)
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .padding(5)
                .background {
                    Circle().fill(renderingMode == .accented ? Color.white.opacity(0.35) : Color.green)
                }
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .shadow(radius: 1)
                .overlay(alignment: .top) {
                    if let priceLabel {
                        Text(priceLabel)
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background {
                                if renderingMode == .accented {
                                    Capsule().fill(Color.white.opacity(0.35))
                                        .overlay(Capsule().stroke(Color.white, lineWidth: 1))
                                } else {
                                    Capsule().fill(Color.green)
                                }
                            }
                            .shadow(radius: 1)
                            .fixedSize()
                            .alignmentGuide(.top) { dimensions in dimensions.height + 4 }
                    }
                }
        case .station:
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                .padding(4)
                .background {
                    Circle().fill(renderingMode == .accented ? Color.white.opacity(0.3) : Color.green.opacity(0.85))
                }
                .overlay(Circle().stroke(.white, lineWidth: 1))
        }
    }
}

struct NearbyE85WidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NearbyE85Entry
    var body: some View { NearbyE85WidgetView(entry: entry, family: family) }
}
