import SwiftUI
import WidgetKit
import CoreLocation
#if NEARBY_WIDGET_TESTING
@testable import EightyFiveBlends
#endif

/// The Nearby E85 widget's TimelineProvider. 85Blends 2.4.0 Pro gate — moved out of
/// NearbyE85Widget.swift (which carries `@main` and therefore can never be compiled into a test
/// bundle) into its own file so EightyFiveBlendsTests can compile it directly, exactly as it already
/// does NearbyE85Presentation/NearbyE85MapRenderer/the two AppIntents. Nothing about the Pro
/// timeline computation changed in the move — see `timeline(access:now:loadProInputs:)`.
nonisolated struct NearbyE85Provider: TimelineProvider {
    /// 85Blends 2.4.0 Pro gate — everything a PRO render needs that a non-Pro render must never
    /// touch: the station cache (behind the app's location-authorization check), the Large zoom
    /// preference, the MKMapSnapshotter render, and the pending manual-refresh flag. Produced only
    /// by `proInputs(context:)` below, and requested only by `entry(...)`/`timeline(...)` AFTER
    /// access has resolved to `.pro` — NearbyE85WidgetProGateTests injects a failing loader to
    /// prove a `.free`/`.unknown` render never asks for any of it.
    nonisolated struct ProInputs {
        let snapshot: NearbyE85Snapshot?
        let zoomLevel: NearbyE85MapZoomLevel
        let mapRender: NearbyE85MapRender?
        let pendingRefreshAt: Date?
    }

    // 85Blends 2.4.0 Pro gate — the widget gallery's placeholder/preview keeps showing the widget's
    // real layout with `example` (synthetic, not a real station or a real location) as `.pro`, so
    // the gallery previews what the widget IS rather than a lock screen; the gallery description
    // (see NearbyE85Widget.swift) states that it requires 85Blends Pro. Every real render goes
    // through the access check in getSnapshot/getTimeline instead.
    func placeholder(in context: Context) -> NearbyE85Entry {
        .init(date: .now, snapshot: Self.example, access: .pro, mapRender: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (NearbyE85Entry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { @MainActor in
            let now = Date.now
            // Access FIRST — see getTimeline's identical guard below for the full rationale.
            let access = NearbyE85WidgetAccessStore().read().status
            let entry = await Self.entry(access: access, now: now) { await proInputs(context: context) }
            completion(entry)
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NearbyE85Entry>) -> Void) {
        Task { @MainActor in
            let now = Date.now
            // 85Blends 2.4.0 Pro gate — resolved BEFORE anything else is read. A non-Pro entry
            // (`.free`, or `.unknown` when nothing authoritative has been mirrored yet — see
            // SharedNearbyE85/NearbyE85WidgetAccess.swift) never touches the station cache, the
            // location-authorization check, the zoom preference, the pending-refresh flag, or
            // MKMapSnapshotter: there is no map, station, price, ethanol, or control to render for
            // it, so none of that data is loaded, and nothing about a user's location ever reaches
            // a locked shell. `timeline(...)` only ever calls the loader below once access is `.pro`,
            // and the Pro path inside it is byte-for-byte what shipped before this gate.
            let access = NearbyE85WidgetAccessStore().read().status
            let timeline = await Self.timeline(access: access, now: now) { await proInputs(context: context) }
            completion(timeline)
        }
    }

    // MARK: - Access-gated builders (unit-tested — see NearbyE85WidgetProGateTests)

    /// getSnapshot's single entry: the locked entry for a non-Pro access, else — after loading the Pro
    /// inputs — exactly the pre-gate computation.
    @MainActor static func entry(access: NearbyE85WidgetAccessStatus, now: Date,
                                 loadProInputs: () async -> ProInputs) async -> NearbyE85Entry {
        guard access.permitsWidgetInteraction else { return lockedEntry(access: access, now: now) }
        let inputs = await loadProInputs()
        let isRefreshing = NearbyE85RefreshFeedback.isRefreshing(requestedAt: inputs.pendingRefreshAt, now: now)
        return .init(date: now, snapshot: inputs.snapshot, access: .pro, mapRender: inputs.mapRender,
                     zoomLevel: inputs.zoomLevel, isRefreshing: isRefreshing)
    }

    /// getTimeline's timeline: the locked timeline for a non-Pro access, else — after loading the Pro
    /// inputs — exactly the pre-gate stale/expiry/price-day/refresh-settle scheduling.
    @MainActor static func timeline(access: NearbyE85WidgetAccessStatus, now: Date,
                                    loadProInputs: () async -> ProInputs) async -> Timeline<NearbyE85Entry> {
        guard access.permitsWidgetInteraction else { return lockedTimeline(access: access, now: now) }
        let inputs = await loadProInputs()
        let snapshot = inputs.snapshot
        let zoomLevel = inputs.zoomLevel
        let mapRender = inputs.mapRender
        let pendingRefreshAt = inputs.pendingRefreshAt
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
                          access: .pro, mapRender: mapRender, zoomLevel: zoomLevel,
                          isRefreshing: NearbyE85RefreshFeedback.isRefreshing(requestedAt: pendingRefreshAt, now: date))
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60)))
    }

    /// The one entry a `.free`/`.unknown` render gets: no snapshot, no map, default zoom, not
    /// refreshing — there is nothing to show but the locked/verify shell.
    static func lockedEntry(access: NearbyE85WidgetAccessStatus, now: Date) -> NearbyE85Entry {
        NearbyE85Entry(date: now, snapshot: nil, access: access)
    }
    /// `.never`: a locked shell has no data that ages, and the ONLY thing that can change it is the
    /// app mirroring a new access status — which always comes with its own
    /// `WidgetCenter.reloadTimelines(ofKind:)` (see NearbyE85WidgetAccessPublisher). No periodic
    /// reload is scheduled, so a Free/unknown widget spends none of WidgetKit's budget.
    static func lockedTimeline(access: NearbyE85WidgetAccessStatus, now: Date) -> Timeline<NearbyE85Entry> {
        Timeline(entries: [lockedEntry(access: access, now: now)], policy: .never)
    }

    // MARK: - Pro-only data loading (only ever reached once access == .pro)

    /// The four reads a Pro render performs, in the same order getSnapshot/getTimeline always
    /// performed them inline before the gate — snapshot, zoom, map, pending-refresh — so nothing
    /// about their relative timing changed either.
    @MainActor private func proInputs(context: Context) async -> ProInputs {
        let snapshot = readAuthorizedSnapshot()
        // Read once per timeline, same as the snapshot itself — zoom is presentation-only,
        // never a reason to touch location or refetch stations.
        let zoomLevel = context.family == .systemLarge ? NearbyE85MapZoomStore().read() : .default
        // The map only ever needs one render per timeline: the region and pins it depicts
        // don't change across the stale/expiry entries, only the copy around them.
        let mapRender = await mapRender(for: snapshot, context: context, zoomLevel: zoomLevel)
        // 85Blends 2.4.0 widget polish — the manual refresh button's "in progress" feedback.
        // Read once, same as everything else above: this never claims new data arrived (the
        // snapshot/its timestamps are completely untouched by this), it only tracks how
        // recently the user tapped refresh so the control can show, and then honestly clear,
        // an in-progress appearance. See NearbyE85RefreshFeedback's header.
        let pendingRefreshAt = NearbyE85RefreshRequestStore().pendingRequestDate()
        return ProInputs(snapshot: snapshot, zoomLevel: zoomLevel, mapRender: mapRender, pendingRefreshAt: pendingRefreshAt)
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
