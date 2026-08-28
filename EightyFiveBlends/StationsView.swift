//
//  StationsView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import UIKit

struct StationsView: View {
    // Neutral continental-US overview — used only when no location or station data exists.
    private static let neutralUSRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 38.5, longitude: -96.0),
        span: MKCoordinateSpan(latitudeDelta: 28.0, longitudeDelta: 50.0)
    )

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FuelStation.updatedAt, order: .reverse)
    private var stations: [FuelStation]

    @State private var searchText = ""
    @State private var stationListFilter: StationListFilter = .all
    @State private var selectedRadius = "25 mi"
    @State private var sheetStation: FuelStation?
    @State private var priceUpdateContext: StationPriceUpdateContext?
    @State private var stationPendingDeletion: FuelStation?
    @State private var infoMessage: String?
    @State private var mapPosition: MapCameraPosition = .region(StationsView.neutralUSRegion)
    @State private var selectedMapStationID: PersistentIdentifier?
    // Follow-on polish — the premium map's floating Trip Planner button pushes onto this same
    // NavigationStack via .navigationDestination(isPresented:) below, reusing TripPlannerView()
    // exactly as ProFeatureGate already does for the Classic/More entry points (never a second
    // Trip Planner implementation).
    @State private var isTripPlannerPresented = false
    // PR #53 — tracks the premium map's one-time initial nearby framing (user + nearest
    // station, ~10-mile-radius minimum) so it never repeatedly snaps the camera back after
    // the user has panned/zoomed. See applyInitialPremiumNearbyFramingIfNeeded()'s own header.
    @State private var premiumNearbyFramingState: PremiumNearbyFramingState = .pending
    @Environment(StationLocationManager.self) private var locationManager
    @Environment(AutomaticPumpDetectionService.self) private var pumpDetectionService
    @Environment(RecentLiveStationCache.self) private var recentLiveStationCache
    // Stations instant-loading foundation (2.3.2, PR A) — deliberately separate from
    // recentLiveStationCache above; see StationsRecentSearchStore's header for why. Owns the
    // last successful current-location search snapshot AND the shared auto-search cooldown
    // timestamp (formerly the view-local lastNearbySearchDate below), so both survive
    // StationsView being recreated instead of resetting on every appearance.
    @Environment(StationsRecentSearchStore.self) private var stationsSearchStore
    @State private var locationDeniedAlert = false
    @State private var liveStations: [LiveFuelStation] = []
    @State private var isSearchingLive = false
    @State private var liveSearchError: String?
    // Identifies WHY a location fix is currently being awaited, so one flow (e.g. the map's
    // "locate me" button, which only wants to recenter) can never silently cancel an unrelated
    // flow's genuinely pending search — see the map locate-me button and
    // PendingLiveSearchReason's own doc comment below.
    @State private var pendingLiveSearchReason: PendingLiveSearchReason?
    // Cross-launch cache (2.3.2, PR #54) — true only while `liveStations` reflects an
    // UNVALIDATED cold-launch disk preview (StationsRecentSearchStore.SnapshotOrigin.
    // restoredFromDisk, shown before a real current-location GPS fix has confirmed it still
    // describes "here" — see hydrateFromRecentSearchCacheIfNeeded()/
    // validateProvisionalPersistedPreviewIfNeeded(against:)). Deliberately explicit, transient
    // @State — never persisted, never inferred from liveStations.isEmpty/snapshot age/map
    // position (section 63: "Explicit is safer"). Cleared the instant the preview is
    // validated by a real coordinate, replaced by a fresh network fetch, or invalidated by a
    // location mismatch or an authorization change.
    @State private var isShowingUnvalidatedPersistedStations = false
    @State private var liveSearchTask: Task<Void, Never>?
    @AppStorage(AppPreferenceKey.appExperienceMode) private var appExperienceModeRaw = AppExperienceMode.normal.rawValue
    // PR D — Pro Stations layout preference (Map vs Classic). Deliberately independent of
    // appExperienceMode: this key alone (plus Pro entitlement) decides the Stations
    // presentation now, in both Simple and Normal mode. See ProStationsLayout/AppPreferenceKey
    // in AppPreferences.swift and usesPremiumStationsMapPresentation below.
    @AppStorage(AppPreferenceKey.proStationsLayout) private var proStationsLayoutRaw = ProStationsLayout.map.rawValue
    @State private var priceInput = ""
    @State private var priceNoteInput = ""
    @State private var priceValidationMessage: String?
    @State private var isSubmittingCommunityPrice = false
    @State private var communityPriceSummaries: [String: CommunityPriceSummary] = [:]
    @State private var communityPriceSyncMessage: String?
    @State private var communityPriceTask: Task<Void, Never>?
    // Dedicated presentation state for the post-submission celebration — deliberately separate
    // from `infoMessage` (the generic error/info alert) so a successful community report can
    // never be confused with, or collide with, an unrelated info/error alert. Set only at the
    // exact point a Save & Report submission is confirmed to have succeeded remotely; see
    // `presentCommunityReportSuccess()`/`savePriceUpdate`. Identical for Nearby- and
    // Saved-Station-originated reports — this state carries no station provenance. The pure
    // present/dismiss transitions live in CommunityReportCelebrationLifecycle so they're directly
    // unit-testable; see CommunityReportCelebrationPresentationTests.swift.
    @State private var communityReportCelebration = CommunityReportCelebrationLifecycle()
    // Tracks the pending 2s auto-dismiss so a manual "Awesome" tap, a new price-update flow, or
    // this view disappearing can all cancel it cleanly with no leaked Task and no double dismiss.
    @State private var communityReportSuccessDismissTask: Task<Void, Never>?

    // Trip-planner / typed-location search
    @State private var locationSearchText = ""
    @State private var locationSearchValidationMessage: String?
    @State private var isGeocodingLocation = false
    @State private var stationSearchSource: StationSearchSource = .currentLocation
    // A new typed-location search (or this view disappearing) cancels a still-in-flight one,
    // preventing a stale geocode result from mutating state after the fact — see
    // searchStationsNearTypedLocation().
    @State private var typedLocationSearchTask: Task<Void, Never>?
    @FocusState private var isTripPlannerFieldFocused: Bool

    private let radiusOptions = ["10 mi", "25 mi", "50 mi", "100 mi"]

    /// Minimum time between automatic (tab-open-triggered) nearby searches — see
    /// shouldPerformAutomaticNearbySearch(). The manual "Find Nearby E85"/header-refresh
    /// buttons and pull-to-refresh never check this cooldown themselves (they always search
    /// immediately); they do update stationsSearchStore.lastCurrentLocationSearchAt like any
    /// other current-location search, which just means a later automatic trigger won't
    /// immediately re-fetch right behind them.
    private static let autoNearbySearchCooldown: TimeInterval = 5 * 60

    private var appVersionString: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private var appExperienceMode: AppExperienceMode {
        .resolved(from: appExperienceModeRaw)
    }

    private var proStationsLayout: ProStationsLayout {
        .resolved(from: proStationsLayoutRaw)
    }

    // PR D ("Pro Stations Preference + Favorite/Save Unification + Natural Card Paging") —
    // replaces PR B's Simple-Mode-only coupling. The premium map is now a Pro Stations LAYOUT
    // choice, independent of appExperienceMode: a Pro user sees it in BOTH Simple and Normal
    // mode when proStationsLayout == .map, and the existing Classic presentation (which still
    // branches internally on appExperienceMode exactly as before) otherwise. Free users always
    // get Classic regardless of the stored preference, which is left untouched so it returns
    // automatically if Pro is restored. Reads SubscriptionManager.shared.isProUser directly (no
    // second entitlement flag, no @State cache) — SubscriptionManager is @Observable, so a
    // purchase/downgrade or a Preferences change while this view is visible re-evaluates this
    // property and swaps presentation reactively, with no restart and no stale modal.
    // Deliberately does not touch AppExperienceNavigation.visibleTabs — tab sets for both modes
    // are unchanged; only what Stations itself renders differs.
    private var usesPremiumStationsMapPresentation: Bool {
        SubscriptionManager.shared.isProUser && proStationsLayout == .map
    }

    /// PR #50 final pre-merge gate — a premium-PRESENTATION-only "is station discovery
    /// currently in progress" signal. isSearchingLive alone only covers the network-fetch
    /// phase (set inside fetchLiveStations); it stays false for the whole location-wait phase
    /// of a pending automatic/manual nearby search (pendingLiveSearchReason != nil,
    /// requestUserLocation() called, no coordinate yet), so the premium map was previously
    /// telling the user nothing was happening at all during that window. Purely derived — no
    /// new stored state, no change to isSearchingLive's own semantics (the legacy list UI still
    /// reads it exactly as before), no change to pendingLiveSearchReason's lifecycle. PR #48
    /// already guarantees pendingLiveSearchReason clears on success, non-denied failure,
    /// denied/restricted, and view disappearance, so this naturally returns to false in every
    /// case with no separate reset needed.
    private var isPremiumStationsLoading: Bool {
        isSearchingLive || pendingLiveSearchReason != nil
    }

    // MARK: - Unified display model

    private var unifiedItems: [StationDisplayItem] {
        var items: [StationDisplayItem] = []
        var mergedNearbyIDs = Set<UUID>()

        for saved in stations {
            if let nearby = liveStations.first(where: { matchesSavedStation(saved, liveStation: $0) }) {
                mergedNearbyIDs.insert(nearby.id)
                items.append(StationDisplayItem(saved: saved, nearby: nearby))
            } else {
                items.append(StationDisplayItem(saved: saved))
            }
        }

        for nearby in liveStations where !mergedNearbyIDs.contains(nearby.id) {
            items.append(StationDisplayItem(nearby: nearby))
        }

        return items
    }

    private var filteredUnifiedItems: [StationDisplayItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = unifiedItems

        switch stationListFilter {
        case .all:
            break
        case .saved:
            items = items.filter { $0.isSaved }
        case .nearby:
            items = items.filter { $0.isNearby }
        }

        if trimmed.isEmpty == false {
            let needle = trimmed.lowercased()
            items = items.filter { item in
                item.displayName.lowercased().contains(needle) ||
                item.displayAddress.lowercased().contains(needle) ||
                item.displayCity.lowercased().contains(needle) ||
                item.displayState.lowercased().contains(needle)
            }
        }

        switch stationListFilter {
        case .nearby:
            items.sort { ($0.distanceMiles ?? .infinity) < ($1.distanceMiles ?? .infinity) }
        case .all:
            items.sort { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
                if lhs.isSaved != rhs.isSaved { return lhs.isSaved }
                if lhs.isSaved, rhs.isSaved,
                   let ls = lhs.savedStation, let rs = rhs.savedStation {
                    if ls.isFavorite != rs.isFavorite { return ls.isFavorite }
                    return ls.updatedAt > rs.updatedAt
                }
                return (lhs.distanceMiles ?? .infinity) < (rhs.distanceMiles ?? .infinity)
            }
        case .saved:
            items.sort { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
                if let ls = lhs.savedStation, let rs = rhs.savedStation {
                    return ls.updatedAt > rs.updatedAt
                }
                return false
            }
        }

        return items
    }

    private var mappableStations: [SavedStationMapItem] {
        stations.compactMap { station in
            guard let latitude = station.latitude, let longitude = station.longitude else {
                return nil
            }

            return SavedStationMapItem(
                id: station.persistentModelID,
                name: station.name,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                lastKnownE85Price: station.lastKnownE85Price,
                lastUpdated: station.lastUpdated
            )
        }
    }

    private var selectedMapStation: SavedStationMapItem? {
        guard let selectedMapStationID else { return nil }
        return mappableStations.first(where: { $0.id == selectedMapStationID })
    }

    private let stationCoordinateTolerance = 0.0005

    private var liveMapStations: [LiveFuelStation] {
        liveStations.filter { isValidCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    // MARK: - Pro premium map presentation
    //
    // Everything below is presentation-layer plumbing for ProStationsMapView. It owns NO
    // business logic of its own — every derivation reads unifiedItems/stations/liveStations
    // (the SAME shared state the existing list/old map already read) and every action resolves
    // back to the SAME existing functions (saveLiveStation, toggleFavorite, beginPriceUpdate,
    // directionsMessage) used elsewhere in this file. This is deliberate: StationsView remains
    // the sole data owner/orchestrator; the premium view never calls NREL/Supabase/SwiftData
    // itself. The existing embedded 200pt map (mapSection), its StationMapPin/LiveStationMapPin,
    // and selectedMapStationID (PersistentIdentifier?) are completely untouched by any of this.

    /// Stable selection identity for the premium map, resolved the same way for every
    /// StationDisplayItem.Content case — factored into one function so premiumStationMapItems
    /// and resolveStationDisplayItem(for:) can never disagree about how a given item maps to a
    /// PremiumStationMapSelection.
    private func premiumSelection(for item: StationDisplayItem) -> PremiumStationMapSelection {
        switch item.content {
        case .savedOnly(let saved):
            return .saved(saved.persistentModelID)
        case .nearbyOnly(let nearby):
            return .live(canonicalLiveStationKey(for: nearby))
        case .merged(let saved, let nearby):
            return .merged(saved: saved.persistentModelID, liveKey: canonicalLiveStationKey(for: nearby))
        }
    }

    /// Durable identity for a live station that survives a background NREL refresh — deliberately
    /// NOT LiveFuelStation.id (a fresh UUID generated on every decode; see that type's own
    /// header). Delegates to the same canonical key NREL-vs-saved matching and community-price
    /// keying already use, so "the same physical station" means one consistent thing everywhere
    /// in this file. CommunityStationKey.canonicalKey can only return nil when name, address,
    /// city, state, zip, AND coordinate are ALL blank — practically unreachable for a real NREL
    /// result (name is always populated) — but per PR B's requirement to never silently fall back
    /// to UUID()/array position/hashValue, a smallest-deterministic fallback is implemented
    /// locally below (normalizedText + coordinate rounding reimplemented here since
    /// CommunityStationKey's own rounding helpers are file-private to CommunityPriceEligibility.swift).
    private func canonicalLiveStationKey(for station: LiveFuelStation) -> String {
        let coordinate = isValidCoordinate(latitude: station.latitude, longitude: station.longitude)
            ? (station.latitude, station.longitude)
            : nil
        if let key = CommunityStationKey.canonicalKey(
            name: station.name,
            streetAddress: station.address,
            city: station.city,
            state: station.state,
            zip: station.zip,
            latitude: coordinate?.0,
            longitude: coordinate?.1
        ) {
            return key
        }
        let roundedLatitude = coordinate.map { ($0.0 * 1000).rounded() } ?? 0
        let roundedLongitude = coordinate.map { ($0.1 * 1000).rounded() } ?? 0
        return "fallback|\(CommunityStationKey.normalizedText(station.name))|\(roundedLatitude),\(roundedLongitude)"
    }

    /// Coordinate priority for a merged item — prefers the live coordinate (the current API
    /// search result) when valid, falling back to the saved coordinate. Never fabricates a
    /// coordinate; an item with neither simply cannot appear as a premium map annotation (it
    /// still exists for saved/list purposes elsewhere, just not on this map).
    private func premiumMapCoordinate(for item: StationDisplayItem) -> CLLocationCoordinate2D? {
        func validSaved(_ saved: FuelStation) -> CLLocationCoordinate2D? {
            guard let latitude = saved.latitude, let longitude = saved.longitude,
                  isValidCoordinate(latitude: latitude, longitude: longitude) else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        func validLive(_ live: LiveFuelStation) -> CLLocationCoordinate2D? {
            guard isValidCoordinate(latitude: live.latitude, longitude: live.longitude) else { return nil }
            return CLLocationCoordinate2D(latitude: live.latitude, longitude: live.longitude)
        }
        switch item.content {
        case .savedOnly(let saved):
            return validSaved(saved)
        case .nearbyOnly(let nearby):
            return validLive(nearby)
        case .merged(let saved, let nearby):
            return validLive(nearby) ?? validSaved(saved)
        }
    }

    /// PR #53 — the premium map's one-time initial nearby framing: user location + nearest
    /// available premium station, at least the minimumLocalRadiusMiles floor, expanding
    /// farther only if the nearest station requires it. `.pending` means no framing has
    /// happened yet this "current-location session"; `.framedWithoutStation` means the
    /// framing already ran with no station available (the ~10-mile user-only fallback) and
    /// may still upgrade exactly once if a station later arrives; `.framedWithStation` means
    /// a real station was already included and this feature never touches the camera again —
    /// user pan/zoom, Recenter, Show All, swipe-follow, and Favorites selection all remain
    /// completely unaffected and untouched by this state.
    private enum PremiumNearbyFramingState: Equatable {
        case pending
        case framedWithoutStation
        case framedWithStation
    }

    /// Minimum useful local viewport for the initial premium-map framing — a floor, never a
    /// ceiling (section 10: "Do NOT enforce a maximum 10-mile view that cuts off the
    /// station"). Not survey-grade; just a stable ~10-mile-radius visual minimum, per the
    /// task's own explicit permission to use MapKit/CoreLocation geometry rather than a
    /// hand-rolled degrees-per-mile constant for correctness across latitudes.
    private static let initialFramingMinimumRadiusMiles = 10.0
    private static let metersPerMile = 1609.34

    /// PR #53 — called from every place a fresh coordinate or a fresh nearby-fetch result
    /// could newly satisfy this one-time framing (StationsView.onAppear,
    /// .onChange(of: locationManager.latestCoordinate), performAutomaticNearbySearchIfNeeded(),
    /// and fetchLiveStations(at:limit:)'s completion) — safe to call redundantly from
    /// multiple sites since premiumNearbyFramingState makes every call after the first a
    /// cheap no-op. Applies ONLY to the premium map's ordinary current-location presentation
    /// (never Classic, never a typed-location/Trip-Planner search, which keeps its own
    /// existing centerMap(on:) camera behavior in searchStationsNearTypedLocation()
    /// untouched). Never sets selectedStationID/selectedMapStationID — the nearest station's
    /// pin is merely visible, no card opens automatically. No network, location, or cache
    /// call of its own; a pure camera-region computation from whatever premiumStationMapItems
    /// already holds at the moment it's called.
    private func applyInitialPremiumNearbyFramingIfNeeded() {
        guard usesPremiumStationsMapPresentation else { return }
        guard stationSearchSource == .currentLocation else { return }
        guard premiumNearbyFramingState != .framedWithStation else { return }
        // Mirrors recenterMap()'s own existing "latestCoordinate + isAuthorizedForUserLocation"
        // pairing — a cached coordinate from before authorization was revoked should not be
        // treated as a usable "current" location for this framing either.
        guard locationManager.isAuthorizedForUserLocation,
              let userCoordinate = locationManager.latestCoordinate?.clCoordinate else { return }

        let nearestStation = nearestPremiumStation(to: userCoordinate)
        if premiumNearbyFramingState == .framedWithoutStation, nearestStation == nil {
            // Already showed the no-station fallback; nothing new to upgrade to yet.
            return
        }

        let coordinates = [userCoordinate] + (nearestStation.map { [$0.coordinate] } ?? [])
        let region = initialFramingRegion(for: coordinates)

        withAnimation {
            mapPosition = .region(region)
        }
        premiumNearbyFramingState = nearestStation == nil ? .framedWithoutStation : .framedWithStation
    }

    /// PR #53 final pre-merge gate — the same "25 mi" -> 25.0 conversion already used verbatim
    /// at both fetchLiveStations(at:limit:) call sites (radiusValue), factored into one
    /// property so nearestPremiumStation(to:)'s saved-only eligibility check below can reuse
    /// the identical parsing rather than introducing a second one. Read-only; never mutates
    /// selectedRadius itself, and this initial-framing feature never mutates it either.
    private var selectedRadiusMiles: Double {
        Double(selectedRadius.replacingOccurrences(of: " mi", with: "")) ?? 25
    }

    /// Geographically nearest LOCALLY RELEVANT premiumStationMapItems entry to the given
    /// coordinate. "Locally relevant" (final pre-merge gate correction) means: a live-only or
    /// merged result is always eligible — both are already constrained by the current nearby
    /// search's own radius/context, so being "nearest" among them is meaningful on its own. A
    /// saved-only station, which carries no such context (it could be anywhere in the user's
    /// entire saved history), is eligible only within the selected search radius
    /// (selectedRadiusMiles) — never unbounded. Without this cap, a single old saved station
    /// hundreds of miles away could become "nearest" whenever no live results exist yet,
    /// expanding the initial camera across the state/country; capping it means such a station
    /// is correctly excluded, nearestPremiumStation(to:) returns nil, and
    /// applyInitialPremiumNearbyFramingIfNeeded() falls back to the ~10-mile user-only view
    /// (never locking premiumNearbyFramingState into .framedWithStation) until a genuinely
    /// local candidate — live, merged, or a nearby saved-only station — actually exists. This
    /// affects camera-candidate selection ONLY: premiumStationMapItems/Show All/Favorites/the
    /// map's own pins are completely unaffected, and selectedRadius itself is never changed.
    /// Deliberately independent of ProStationMapItem.distanceMiles, which is nil for every
    /// savedOnly station and can be stale/zero for a live station outside the one
    /// cache-rehydration path that recomputes it — CLLocation distance from each item's own
    /// coordinate is the only source of truth that is correct for every kind, every time.
    private func nearestPremiumStation(to userCoordinate: CLLocationCoordinate2D) -> ProStationMapItem? {
        let userLocation = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        let radiusMiles = selectedRadiusMiles

        let eligible: [(item: ProStationMapItem, distance: CLLocationDistance)] = premiumStationMapItems.compactMap { item in
            let distance = CLLocation(latitude: item.coordinate.latitude, longitude: item.coordinate.longitude)
                .distance(from: userLocation)
            switch item.kind {
            case .liveOnly, .merged:
                return (item, distance)
            case .savedOnly:
                let distanceMiles = distance / Self.metersPerMile
                return distanceMiles <= radiusMiles ? (item, distance) : nil
            }
        }
        return eligible.min(by: { $0.distance < $1.distance })?.item
    }

    /// Bounding box over 1-2 coordinates (user alone, or user + nearest station) using the
    /// exact same padding shape already established by fitAllStations()/recenterMap() (0.35x
    /// padding factor, 0.05° floor) — then enforces the ~10-mile-radius minimum span on top,
    /// so a very close station (or no station at all) never zooms in tighter than that floor,
    /// while a station that genuinely needs more room (>10 miles away) always wins via the
    /// plain max(), never getting cut off.
    private func initialFramingRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard
            let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
            let minLongitude = longitudes.min(), let maxLongitude = longitudes.max()
        else {
            return MKCoordinateRegion(center: Self.neutralUSRegion.center, span: Self.neutralUSRegion.span)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let latitudePadding = max((maxLatitude - minLatitude) * 0.35, 0.05)
        let longitudePadding = max((maxLongitude - minLongitude) * 0.35, 0.05)
        let paddedSpan = MKCoordinateSpan(
            latitudeDelta: (maxLatitude - minLatitude) + latitudePadding,
            longitudeDelta: (maxLongitude - minLongitude) + longitudePadding
        )

        let minimumSpan = minimumLocalSpan(atLatitude: center.latitude, longitude: center.longitude)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(paddedSpan.latitudeDelta, minimumSpan.latitudeDelta),
                longitudeDelta: max(paddedSpan.longitudeDelta, minimumSpan.longitudeDelta)
            )
        )
    }

    /// The ~10-mile-radius minimum viewport, expressed as a span at the given center. Uses
    /// MapKit's own meters-based region initializer (latitudinalMeters/longitudinalMeters)
    /// rather than a hand-rolled degrees-per-mile conversion, so the correction for longitude
    /// degrees representing fewer real-world miles at higher latitudes is handled by MapKit
    /// itself instead of a manually-reasoned trig approximation.
    private func minimumLocalSpan(atLatitude latitude: Double, longitude: Double) -> MKCoordinateSpan {
        let diameterMeters = Self.initialFramingMinimumRadiusMiles * 2 * Self.metersPerMile
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            latitudinalMeters: diameterMeters,
            longitudinalMeters: diameterMeters
        )
        return region.span
    }

    /// Same saved/community price hierarchy StationRowCard/LiveStationRowCard already display —
    /// a saved/local price is primary whenever it exists; community is primary only when no
    /// saved price exists; a supporting community line may appear alongside a saved primary
    /// price without ever being averaged or mislabeled as the saved price's source. NREL/live
    /// data carries no price field at all (see LiveFuelStation's field list), so a "live price"
    /// is structurally impossible here — there is nothing to invent it from.
    private func premiumPricePresentation(for item: StationDisplayItem) -> PremiumStationPricePresentation {
        let community: CommunityPriceSummary?
        switch item.content {
        case .savedOnly(let saved), .merged(let saved, _):
            community = communitySummary(for: saved)
        case .nearbyOnly(let nearby):
            community = communitySummary(for: nearby)
        }

        if let saved = item.savedStation, saved.lastKnownE85Price > 0 {
            let days = StationDataValidation.daysSince(saved.lastUpdated)
            let tier = StationDataValidation.priceFreshnessTier(hasPrice: true, daysSinceUpdate: days)
            let freshnessLabel: String
            switch tier {
            case .noPrice: freshnessLabel = "No Price"
            case .fresh: freshnessLabel = "Fresh"
            case .checkPrice: freshnessLabel = "Check Price"
            case .stale: freshnessLabel = "Stale"
            }
            var supportingText: String?
            if let community, let latestPrice = community.latestPrice, let latestReportedAt = community.latestReportedAt {
                supportingText = "Community \(latestPrice.communityPriceText)/gal · \(latestReportedAt.communityReportedText)"
            }
            return PremiumStationPricePresentation(
                primaryText: String(format: "$%.2f/gal", saved.lastKnownE85Price),
                primarySource: "Saved",
                freshnessText: freshnessLabel,
                supportingText: supportingText,
                hasNoPriceAtAll: false
            )
        }

        if let community, let latestPrice = community.latestPrice, let latestReportedAt = community.latestReportedAt {
            return PremiumStationPricePresentation(
                primaryText: "\(latestPrice.communityPriceText)/gal",
                primarySource: "Community",
                freshnessText: latestReportedAt.communityReportedText,
                supportingText: nil,
                hasNoPriceAtAll: false
            )
        }

        return PremiumStationPricePresentation(
            primaryText: nil,
            primarySource: nil,
            freshnessText: nil,
            supportingText: nil,
            hasNoPriceAtAll: true
        )
    }

    /// VoiceOver label, built conditionally so a missing price/distance never speaks as
    /// "$0.00"/"nil" junk — see PR B's accessibility requirements. Order: name, saved/favorite
    /// state, distance, price, freshness.
    private func premiumAccessibilityDescription(
        name: String,
        isSaved: Bool,
        isFavorite: Bool,
        distanceMiles: Double?,
        price: PremiumStationPricePresentation
    ) -> String {
        var parts: [String] = [name.isEmpty ? "Station" : name]
        if isFavorite {
            parts.append("Favorite")
        } else if isSaved {
            parts.append("Saved")
        }
        if let distanceMiles {
            parts.append(String(format: "%.1f miles away", distanceMiles))
        }
        if let primaryText = price.primaryText {
            parts.append("E85 \(primaryText)")
        }
        if let freshnessText = price.freshnessText {
            parts.append(freshnessText)
        }
        return parts.joined(separator: ", ")
    }

    /// The full derived item list for the premium map — built fresh from unifiedItems every
    /// time that recomputes (a new fetch, a save, a favorite toggle, a community-price arrival).
    /// No separate @State copy of station data exists anywhere in this section.
    private var premiumStationMapItems: [ProStationMapItem] {
        unifiedItems.compactMap { item in
            guard let coordinate = premiumMapCoordinate(for: item) else { return nil }
            let price = premiumPricePresentation(for: item)
            let kind: ProStationKind = item.isSaved ? (item.isNearby ? .merged : .savedOnly) : .liveOnly
            // 2.3.2 gate fix — full postal address for Share, using StationDisplayItem's own
            // per-field, saved-preferred-but-nearby-completes Share resolution (see
            // StationDisplayItem.shareAddress) rather than rebuilding from displayAddress/
            // displayCity/displayState/displayZip here, which would silently drop a merged
            // item's fuller nearby-record fields whenever the saved record has that field
            // present but empty. Presentation-only: never touches the persisted station model.
            return ProStationMapItem(
                selection: premiumSelection(for: item),
                displayName: item.displayName,
                coordinate: coordinate,
                displayAddress: item.displayAddress,
                shareAddress: item.shareAddress,
                distanceMiles: item.distanceMiles,
                price: price,
                isSaved: item.isSaved,
                isFavorite: item.isFavorite,
                kind: kind,
                accessibilityDescription: premiumAccessibilityDescription(
                    name: item.displayName,
                    isSaved: item.isSaved,
                    isFavorite: item.isFavorite,
                    distanceMiles: item.distanceMiles,
                    price: price
                )
            )
        }
    }

    private func resolveStationDisplayItem(for selection: PremiumStationMapSelection) -> StationDisplayItem? {
        unifiedItems.first { premiumSelection(for: $0) == selection }
    }

    /// Directions — reuses the exact existing per-source helper (and, for a merged station, the
    /// same saved-station variant the current app already uses for merged rows outside the
    /// Nearby filter — see unifiedStationCard(for:)), never a new routing path.
    private func premiumDirectionsMessage(for selection: PremiumStationMapSelection) -> String? {
        guard let item = resolveStationDisplayItem(for: selection) else { return nil }
        switch item.content {
        case .savedOnly(let saved), .merged(let saved, _):
            return directionsMessage(for: saved)
        case .nearbyOnly(let nearby):
            return directionsMessage(for: nearby)
        }
    }

    /// PR D — the single unified user-facing Favorite action for the premium map (section
    /// 23-27). A live-only station is saved AND favorited in one call — saveLiveStation(_:
    /// markFavorite:) sets isFavorite on the newly-created FuelStation at construction time, so
    /// there is no second lookup/search step and no window where the station exists but isn't
    /// yet favorite. The resulting selection identity migration (.live(key) -> .merged(id,
    /// key)) is handled entirely by ProStationsMapView's existing selectedItem
    /// live->merged fallback — unchanged by this PR, since it keys purely on the shared live
    /// key, not on which action triggered the identity change. A saved/merged station simply
    /// flips its existing isFavorite via toggleFavorite(_:), unchanged from before this PR.
    /// There is no separate "Save" path left anywhere on the premium map.
    private func premiumFavorite(for selection: PremiumStationMapSelection) {
        guard let item = resolveStationDisplayItem(for: selection) else { return }
        switch item.content {
        case .savedOnly(let saved), .merged(let saved, _):
            toggleFavorite(saved)
        case .nearbyOnly(let nearby):
            saveLiveStation(nearby, markFavorite: true)
        }
    }

    /// Report/Update Price — reuses the existing beginPriceUpdate(for:) overloads verbatim,
    /// which already drive the shared $priceUpdateContext sheet attached to stationsContent
    /// above; the premium map never presents a second price editor.
    private func premiumReportPrice(for selection: PremiumStationMapSelection) {
        guard let item = resolveStationDisplayItem(for: selection) else { return }
        switch item.content {
        case .savedOnly(let saved), .merged(let saved, _):
            beginPriceUpdate(for: saved)
        case .nearbyOnly(let nearby):
            beginPriceUpdate(for: nearby)
        }
    }

    /// PR C ("Simple Pro Stations — Interaction / Responsiveness Polish") — immediate-feedback
    /// recenter for the premium map. Root cause of the reported "Recenter feels slow": the old
    /// wiring called locationManager.requestUserLocation() directly, which ALWAYS waits for a
    /// brand-new GPS callback before the camera moves at all — even when a perfectly usable
    /// latestCoordinate already exists from moments ago. Fixes this by using the known
    /// coordinate for an IMMEDIATE visual anchor when one exists, then only requesting a fresh
    /// fix (silently, in the background) if StationsLocationFreshness — read here, never
    /// redefined — says the known one is old enough to be worth correcting. When a fresh fix
    /// does arrive, the existing, unmodified `.onChange(of: locationManager.latestCoordinate)`
    /// handler above already re-centers unconditionally, so no extra plumbing is needed for
    /// "map updates again when a fresh fix arrives." Never touches pendingLiveSearchReason —
    /// same precedent as the old map's own "locate me" button — so this can never fire an
    /// unrelated station re-search. No StationLocationManager change, no second CLLocationManager,
    /// no polling.
    private func premiumRecenterOnUser() {
        AppHaptics.selection()
        if let coordinate = locationManager.latestCoordinate {
            centerMap(on: coordinate.clCoordinate)
            let isFresh = StationsLocationFreshness.isCoordinateRecentEnough(
                fixTimestamp: locationManager.latestFixTimestamp,
                now: .now
            )
            if isFresh == false {
                locationManager.requestUserLocation()
            }
        } else {
            locationManager.requestUserLocation()
        }
    }

    private var premiumStationsMapView: some View {
        ProStationsMapView(
            items: premiumStationMapItems,
            isLoadingStations: isPremiumStationsLoading,
            liveSearchError: liveSearchError,
            isTypedLocationSearch: { if case .typedLocation = stationSearchSource { return true }; return false }(),
            typedLocationDisplayName: { if case .typedLocation(let name) = stationSearchSource { return name }; return nil }(),
            radiusOptions: radiusOptions,
            // Final pre-merge gate finding — the premium map was missing the current-location
            // marker the old embedded map already shows (mapSection's own
            // "if locationManager.isAuthorizedForUserLocation { UserAnnotation() }"). Computed
            // the identical way; the premium view receives only this Bool, never
            // locationManager itself.
            showsUserLocation: locationManager.isAuthorizedForUserLocation,
            mapPosition: $mapPosition,
            selectedRadius: $selectedRadius,
            locationSearchText: $locationSearchText,
            isGeocodingLocation: isGeocodingLocation,
            locationSearchValidationMessage: locationSearchValidationMessage,
            onSubmitLocationSearch: searchStationsNearTypedLocation,
            onClearLocationSearch: clearTrip,
            onRecenterUser: premiumRecenterOnUser,
            // PR C — Show All is now a premium-only fitAllStations() computed directly from
            // this view's own `items` (see ProStationsMapView) rather than reusing the
            // legacy recenterMap(), which does legacy-only work (mutating selectedMapStationID,
            // an old-map-only concept) irrelevant here. recenterMap() itself is untouched and
            // still backs the old embedded map's own "Show All" button exactly as before.
            onRefresh: searchNearbyStations,
            onDirections: { premiumDirectionsMessage(for: $0) },
            // PR D — Save is gone as a separate premium-map action; Favorite now covers every
            // kind (live-only saves+favorites atomically, saved/merged toggles) — see
            // premiumFavorite(for:) above.
            onFavorite: { premiumFavorite(for: $0) },
            onReportPrice: { premiumReportPrice(for: $0) },
            onOpenTripPlanner: openTripPlannerFromPremiumMap
        )
    }

    /// Follow-on polish — the premium map's floating Trip Planner button only signals intent
    /// (ProStationsMapView presents nothing itself); this sets the same isTripPlannerPresented
    /// flag the stationsContent NavigationStack's own .navigationDestination(isPresented:)
    /// reads, pushing TripPlannerView() exactly as ProFeatureGate already does elsewhere — no
    /// second Trip Planner implementation, no new presentation mechanism.
    private func openTripPlannerFromPremiumMap() {
        AppHaptics.selection()
        isTripPlannerPresented = true
    }

    var body: some View {
        stationsContent
    }

    private var stationsContent: some View {
        NavigationStack {
            // GeometryReader pins the ScrollView and its content to the viewport
            // width and clips overflow so the entire page can never translate
            // horizontally — no two-finger / long-press drag can shift the screen.
            GeometryReader { proxy in
                // PR D — a Pro user gets the map-first premium presentation whenever their
                // stored Stations layout preference is .map, in BOTH Simple and Normal mode;
                // every other combination (any Free user, or a Pro user who chose Classic)
                // renders the exact same ScrollView content as before, byte-for-byte unchanged
                // below. This `if/else` is the only structural change to this GeometryReader —
                // see usesPremiumStationsMapPresentation's own header.
                // 85Blends 2.3.2 — entitlement-presentation fix: while this process's first
                // RevenueCat CustomerInfo answer hasn't arrived yet, "not Pro" is unknown, not
                // Free. Rendering the `else` (Classic/Free) branch below in that window is
                // exactly the bug this checks first — a neutral, entitlement-agnostic loading
                // shell instead, with NO Free-plan messaging, NO Pro-only controls, and NO ad
                // placement (see stationsEntitlementResolvingView's own header). This is purely a
                // presentation gate: .onAppear/.onChange below (hydration, GPS prewarm,
                // automatic nearby search, community pricing) are attached to this view's outer
                // NavigationStack, not nested inside this if/else, so none of that PR #54/#53
                // pipeline work is delayed by this branch existing.
                if SubscriptionManager.shared.isInitialEntitlementResolutionPending {
                    stationsEntitlementResolvingView
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else if usesPremiumStationsMapPresentation {
                    premiumStationsMapView
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 16) {
                            headerSection
                            // Trip Planner / Station Price Alerts entry points are Normal Mode
                            // feature navigation — core station search, map, favorites, directions,
                            // and community pricing below remain fully functional in both modes.
                            if appExperienceMode == .normal {
                                proFeaturesSection
                                comingSoonSection
                            }
                            mapSection
                            findNearbyButton
                            radiusSelector
                            locationSearchCard
                            activeTripBanner
                            searchCard
                            filterChipsRow
                            unifiedStationsSection
                        }
                        .padding(16)
                        .frame(width: proxy.size.width, alignment: .leading)
                    }
                    .scrollIndicators(.visible, axes: .vertical)
                    // Pull-to-refresh — forces an immediate nearby search regardless of the
                    // auto-search cooldown below (see performPullToRefresh()).
                    .refreshable {
                        await performPullToRefresh()
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .background(AppTheme.Colors.charcoal)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .keyboardDoneToolbar()
            .dismissKeyboardOnTap()
            // Follow-on polish — the premium map's floating Trip Planner button pushes here,
            // onto this same NavigationStack. TripPlannerView() takes no arguments and sets its
            // own navigationTitle/back button, matching exactly how ProFeatureGate's
            // NavigationLink already presents it from proFeaturesSection/MoreView — this is a
            // second entry point to the identical destination, never a second implementation.
            .navigationDestination(isPresented: $isTripPlannerPresented) {
                TripPlannerView()
            }
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .onAppear {
            // Stations instant-loading foundation (2.3.2, PR A) — hydrate liveStations from a
            // compatible recent-session snapshot BEFORE recenterMap()/refreshCommunityPricePreviews()
            // run, so the very first map fit and community-price fetch already account for it
            // instead of only catching up after a second pass. See
            // hydrateFromRecentSearchCacheIfNeeded()'s own header.
            hydrateFromRecentSearchCacheIfNeeded()
            // PR #53 — recenterMap()'s fit-all-saved-stations bounding box can zoom the
            // premium map out across the state/country around a single far-away saved
            // station (section 7's explicit "far saved station must not distort initial
            // view"); the premium map gets its own user+nearest-station framing instead.
            // Classic keeps recenterMap() exactly as before.
            if usesPremiumStationsMapPresentation {
                applyInitialPremiumNearbyFramingIfNeeded()
            } else {
                recenterMap()
            }
            refreshCommunityPricePreviews()
            // UX improvement — auto-populate the Nearby E85 feed on tab open instead of
            // requiring a manual "Find Nearby E85" tap every time. See
            // performAutomaticNearbySearchIfNeeded()'s own header for the cooldown/denied-
            // permission handling that keeps this from spamming requests or interrupting the
            // user with an unprompted alert. This is also the stale-while-refresh step for any
            // cache hydration just above — its own cooldown check (now backed by
            // stationsSearchStore.lastCurrentLocationSearchAt) decides whether a quiet
            // background refresh is actually warranted right now.
            performAutomaticNearbySearchIfNeeded()
        }
        .onDisappear {
            liveSearchTask?.cancel()
            communityPriceTask?.cancel()
            communityReportSuccessDismissTask?.cancel()
            typedLocationSearchTask?.cancel()
            isSearchingLive = false
            pendingLiveSearchReason = nil
            // Mirrors isSearchingLive's own reset above — without this, cancelling a
            // still-in-flight typed-location geocode here leaves isGeocodingLocation stuck
            // true forever (the task's own cancellation-guarded defer intentionally skips
            // resetting it, precisely so it can't clobber a NEWER task's spinner), permanently
            // disabling the Trip Planner Search button for the rest of the session.
            isGeocodingLocation = false
        }
        .onChange(of: mappableStations) { _, _ in
            // PR B adversarial audit finding — mappableStations changes on ANY saved-station
            // mutation SavedStationMapItem's Equatable compares (name/coordinate/price/
            // lastUpdated), including a bare favorite toggle (which bumps updatedAt). The
            // premium map manages its own camera via user pan/zoom plus explicit Recenter/Show
            // All controls (see PR B section 46 — "should not recenter on every render"), so
            // auto-recentering here would unexpectedly rezoom/jump the full-screen premium map
            // out from under a Pro user who just tapped Favorite. The OLD embedded map (Free
            // users, or a Pro user who chose Classic) keeps this exact recenter-on-change
            // behavior, unchanged.
            guard usesPremiumStationsMapPresentation == false else { return }
            recenterMap()
        }
        .onChange(of: usesPremiumStationsMapPresentation) { _, _ in
            // PR B adversarial audit finding — selectedMapStationID only has meaning for the
            // OLD embedded map's own tap-to-select UI (selectedMapStationCard); recenterMap()
            // (shared by both presentations' "Show All"/fetch-completion paths) can set it as a
            // side effect. Resetting it on every premium/legacy transition prevents a stale
            // auto-selection picked up while one presentation was active from surfacing as an
            // unexpected selectedMapStationCard when switching back to the other (e.g. a Pro
            // subscription lapsing, or a Preferences change between Map and Classic, while this
            // view stays mounted) — see PR B section 43's "no stale modal" requirement. The
            // premium view's own local state (selectedStationID, Favorites panel) needs no
            // equivalent reset here — SwiftUI already tears it down when this if/else branch
            // swaps away from it and creates it fresh (default @State) on the way back.
            selectedMapStationID = nil
            // PR #53 — a fresh entry into the premium presentation (Classic -> Map, or Pro
            // regained while this view stays mounted) deserves its own fresh initial framing,
            // per section 14's explicit reset trigger. Immediately re-applies (mirroring
            // clearTrip()'s identical reset-then-reapply pattern below) rather than only
            // arming the flag for some later trigger — otherwise, if a coordinate and premium
            // items are already known at the moment this transition happens (e.g. Pro just
            // regained via a purchase sheet, with no new location update or fetch about to
            // fire on its own), the map would keep showing whatever stale camera the OTHER
            // presentation last left it at until some unrelated trigger happened to fire.
            premiumNearbyFramingState = .pending
            applyInitialPremiumNearbyFramingIfNeeded()
        }
        .onChange(of: searchText) { _, _ in
            refreshCommunityPricePreviews()
        }
        .onChange(of: stationListFilter) { _, _ in
            refreshCommunityPricePreviews()
        }
        .onChange(of: locationManager.latestCoordinate) { _, coordinate in
            guard let coordinate else { return }
            // Cross-launch cache (2.3.2, PR #54, section 28) — CRITICAL ordering: resolve any
            // provisional disk-restored preview against this real coordinate before any other
            // camera/fetch logic below runs.
            validateProvisionalPersistedPreviewIfNeeded(against: coordinate)
            // PR #53 — an ordinary location update must not let the premium map's
            // established camera get overwritten by a tight, user-only recenter every time a
            // fresh fix arrives; the one-time initial framing (or its no-station-yet ->
            // has-station upgrade) is the only thing this triggers for the premium map now.
            // Classic keeps centerMap(on:) exactly as before.
            if usesPremiumStationsMapPresentation {
                applyInitialPremiumNearbyFramingIfNeeded()
            } else {
                centerMap(on: coordinate.clCoordinate)
            }
            if pendingLiveSearchReason != nil {
                fetchLiveStations(at: coordinate.clCoordinate)
            }
            refreshPumpDetectionMonitoredStations(reason: "Location updated")
        }
        .onChange(of: locationManager.authorizationStatus) { _, status in
            handleAuthorizationStatusChange(status)
            refreshPumpDetectionMonitoredStations(reason: "Location authorization changed")
        }
        .onChange(of: locationManager.locationFailureRevision) { _, _ in
            handlePendingLocationFailureIfNeeded()
        }
        .onChange(of: stations) { _, _ in
            refreshPumpDetectionMonitoredStations(reason: "Saved stations changed")
        }
        .sheet(item: $sheetStation) { station in
            AddEditStationView(station: station) { draft in
                updateStation(station, from: draft)
            }
        }
        .sheet(item: $priceUpdateContext) { context in
            StationPriceUpdateSheet(
                context: context,
                priceInput: $priceInput,
                noteInput: $priceNoteInput,
                validationMessage: $priceValidationMessage,
                isSubmittingCommunityPrice: isSubmittingCommunityPrice,
                saveLocalAction: { savePriceUpdate(for: context, reportToCommunity: false) },
                saveAndReportAction: { savePriceUpdate(for: context, reportToCommunity: true) },
                cancelAction: dismissPriceUpdateSheet
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(isSubmittingCommunityPrice)
        }
        .alert("Location Access Denied", isPresented: $locationDeniedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Location access is turned off. Enable it in Settings → Privacy → Location Services to find E85 stations near you.")
        }
        .alert("Stations", isPresented: infoAlertBinding) {
            Button("OK", role: .cancel) {
                infoMessage = nil
            }
        } message: {
            Text(infoMessage ?? "")
        }
        // Background content is inert/hidden to VoiceOver while the delete confirmation below
        // is active — see DestructiveConfirmationOverlay's own .isModal trait.
        .accessibilityHidden(stationPendingDeletion != nil)
        .overlay {
            if stationPendingDeletion != nil {
                DestructiveConfirmationOverlay(
                    title: "Delete Station?",
                    message: "This saved station will be removed from your local list.",
                    destructiveActionTitle: "Delete",
                    cancelAction: { stationPendingDeletion = nil },
                    destructiveAction: confirmDeletion
                )
            }
        }
        .overlay {
            // Presentation-only: never touches Community Price persistence, local price-save
            // behavior, or refresh semantics — those already happened before this is shown. Lives
            // above the sheet's presenting content, not inside the sheet itself, since the price
            // update sheet is already dismissed (see savePriceUpdate) by the time this can show.
            if communityReportCelebration.isPresented {
                CommunityReportSuccessOverlay {
                    dismissCommunityReportSuccess()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: communityReportCelebration.isPresented)
    }

    // Automatic Pump Detection's toggle/status/privacy UI now lives in
    // AutomaticPumpDetectionPreferenceCard, reached via More → Preferences. Stations keeps only
    // the production hooks below (refreshPumpDetectionMonitoredStations and its three
    // .onChange call sites in the NavigationStack modifiers above) — those keep background
    // monitoring synchronized with this screen's saved-station/location data and are not UI.

    // 85Blends Pro entry points. Free users see locked preview cards (tapping opens the
    // paywall); Pro users get the live feature shells. Basic station search, favorites, and
    // saved stations below remain fully free.
    private var proFeaturesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // "Smarter E85 route planning." (was "Smarter planning and price tracking.") —
            // price tracking/alerts isn't available yet, so this section only describes what
            // Trip Planner (the one feature actually in it now) delivers today.
            SectionHeader(title: "85Blends Pro", subtitle: "Smarter E85 route planning.")

            ProFeatureGate(
                icon: "map.fill",
                title: "Trip Planner",
                description: "Plan E85 routes with intelligent fuel stops and range estimates."
            ) {
                TripPlannerView()
            }
        }
    }

    // 2.3.0 UI polish pass: split out of proFeaturesSection above — Station Price Alerts is a
    // placeholder shell today (see StationAlertsView). .comingSoon availability means no "PRO"
    // badge and no "Unlock 85Blends Pro" CTA (see ProFeatureGate.Availability), and it's no
    // longer visually grouped under the "85Blends Pro" header as if it were current, paid value.
    private var comingSoonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Coming Soon", subtitle: "Features planned for a future update.")

            ProFeatureGate(
                icon: "bell.badge.fill",
                title: "Station Price Alerts",
                description: "Get notified about E85 price changes. Arrives in an upcoming Pro update.",
                availability: .comingSoon
            ) {
                StationAlertsView()
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                stationHeaderIcon

                VStack(alignment: .leading, spacing: 4) {
                    Text("E85 Stations")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text("Saved stations stay local. Nearby live E85 search is available on demand.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                refreshButton
            }

        }
    }

    /// 85Blends 2.3.2 — the ONLY thing rendered while
    /// SubscriptionManager.shared.isInitialEntitlementResolutionPending is true (see
    /// stationsContent's own header on the if/else this belongs to). Deliberately neutral: no
    /// "Unlock 85Blends Pro"/locked Trip Planner (would misrepresent an unresolved entitlement as
    /// Free — proFeaturesSection is never reached from this branch), no premium-only controls
    /// (would misrepresent it as Pro — premiumStationsMapView is never reached either), and no
    /// NativeAdView (an ad must never be requested merely because isProUser currently defaults to
    /// false while entitlement is still unknown). Reuses stationHeaderIcon verbatim — plain
    /// branding, no entitlement logic of its own. Normally on screen for only a few frames; none
    /// of the station-cache/GPS/NREL/community-price pipeline is gated on this view existing —
    /// see this branch's own comment in stationsContent.
    private var stationsEntitlementResolvingView: some View {
        VStack(spacing: 16) {
            Spacer()
            stationHeaderIcon
            Text("E85 Stations")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            ProgressView()
                .tint(AppTheme.Colors.primaryGreen)
            Text("Loading Stations…")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Colors.charcoal)
    }

    private var stationHeaderIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Colors.softGreenBackground.opacity(0.72))

            Image(systemName: "map.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(AppTheme.Colors.primaryGreen)
        }
        .frame(width: 58, height: 58)
    }

    private var refreshButton: some View {
        Button {
            searchNearbyStations()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.headline.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(width: 44, height: 44)
                .background(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var searchCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField("Filter stations", text: $searchText)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.Colors.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(StationListFilter.allCases, id: \.rawValue) { filter in
                    filterChip(filter)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterChip(_ filter: StationListFilter) -> some View {
        let isSelected = stationListFilter == filter
        return Button {
            stationListFilter = filter
            AppHaptics.selection()
        } label: {
            Text(filter.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(isSelected ? AppTheme.Colors.primaryGreen.opacity(0.22) : AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.borderColor, lineWidth: 1)
                )
                .scaleEffect(isSelected ? 1.03 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.76), value: stationListFilter)
    }

    @ViewBuilder
    private var unifiedStationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: sectionTitle, subtitle: sectionSubtitle)

            if stations.count >= SubscriptionManager.freeSavedStationLimit, !SubscriptionManager.shared.isPro {
                ProLimitBannerView(message: "Pro supports more saved stations.")
            }

            if let communityPriceSyncMessage {
                communitySyncMessageRow(communityPriceSyncMessage)
            }

            if let liveSearchError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.stationYellow)

                    Text(liveSearchError)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .padding(.horizontal, 2)
            }

            // UX fix: previously `isSearchingLive` fully replaced this section with just
            // liveSearchLoadingCard, hiding any already-loaded saved stations for the whole
            // duration of a search. Now that a search can also start automatically on tab
            // open (see performAutomaticNearbySearchIfNeeded()), that would mean saved
            // stations disappearing every single time the tab is opened — so the existing
            // list now stays visible, with the loading card appended below it instead of
            // replacing it. Only the true empty case (nothing saved or nearby yet) still
            // shows the loading card alone.
            if filteredUnifiedItems.isEmpty {
                if isSearchingLive {
                    liveSearchLoadingCard
                } else {
                    emptyStateForCurrentFilter
                }
            } else {
                stationRowsWithNativeAd

                if isSearchingLive {
                    liveSearchLoadingCard
                }
            }
        }
    }

    // AdMob Phase 2 — 85Blends Stations Native placement, rendered as its own stable row
    // between the first 3 station cards and the rest — never nested inside either ForEach, so
    // its SwiftUI identity never depends on which station happens to occupy any particular
    // position.
    //
    // FIX (validation audit): the original version emitted NativeAdView from inside a single
    // enumerated ForEach's per-item closure (id: \.element.id), so the ad's identity was
    // inherited from whichever station happened to sit at index 2. A filter toggle, a live
    // search refresh, or a favorite/sort update could put a DIFFERENT station at that index,
    // which SwiftUI reads as "new element, new closure invocation" — tearing down and
    // recreating NativeAdLoader (and firing a fresh ad request) on every such reorder. Splitting
    // into two ForEach blocks around one independently-identified NativeAdView removes that
    // dependency entirely: leading/trailing station rows can reorder, refresh, or change count
    // freely without ever touching the ad's identity. "Do not show if fewer than 4 stations
    // exist" is preserved via the items.count check below. Free users only; Pro users never see
    // showsNativeAd evaluate true, since isProUser is checked before NativeAdView is ever
    // constructed.
    @ViewBuilder
    private var stationRowsWithNativeAd: some View {
        let items = filteredUnifiedItems
        let leadingStationCount = 3 // cards rendered before the ad — "after the third station card"
        let showsNativeAd = SubscriptionManager.shared.isProUser == false
            && items.count > leadingStationCount // at least a 4th card to follow the ad

        if showsNativeAd {
            let leadingItems = Array(items.prefix(leadingStationCount))
            let trailingItems = Array(items.dropFirst(leadingStationCount))

            ForEach(leadingItems) { item in
                unifiedStationCard(for: item)
            }

            // Explicit, fixed identity — independent of every station's own id, so nothing
            // about the lists above/below this line (reordering, refreshing, growing, shrinking)
            // can ever cause this specific view to be torn down and recreated.
            NativeAdView(placement: .stations)
                .id("stations-native-ad-slot")

            ForEach(trailingItems) { item in
                unifiedStationCard(for: item)
            }
        } else {
            ForEach(items) { item in
                unifiedStationCard(for: item)
            }
        }
    }

    private var sectionTitle: String {
        switch stationListFilter {
        case .all: return "Stations"
        case .saved: return "Saved Stations"
        case .nearby: return "Nearby E85"
        }
    }

    private var sectionSubtitle: String {
        switch stationListFilter {
        case .all:
            var parts: [String] = []
            if stations.count > 0 { parts.append("\(stations.count) saved") }
            if liveStations.count > 0 { parts.append("\(liveStations.count) nearby") }
            return parts.isEmpty ? "Find and save E85 stations." : parts.joined(separator: " · ")
        case .saved:
            return "Favorites pinned first, then recently updated."
        case .nearby:
            if liveStations.isEmpty {
                // Loading-state polish: a search (automatic or manual) may already be in
                // flight the first time this filter is visible — "Tap Find Nearby E85" would
                // be stale/confusing in that moment.
                if isSearchingLive {
                    return "Searching nearby E85 stations…"
                }
                return "Tap Find Nearby E85 or search an area above."
            }
            return "\(liveStations.count) results near \(stationSearchSource.displayName) within \(selectedRadius)."
        }
    }

    @ViewBuilder
    private func unifiedStationCard(for item: StationDisplayItem) -> some View {
        switch item.content {
        case .savedOnly(let saved):
            StationRowCard(
                station: saved,
                communitySummary: communitySummary(for: saved),
                directionsAction: { directionsMessage(for: saved) },
                updatePriceAction: { beginPriceUpdate(for: saved) },
                favoriteAction: { toggleFavorite(saved) },
                editAction: { sheetStation = saved },
                deleteAction: { stationPendingDeletion = saved },
                // No live counterpart to borrow a missing field from — Share derives the
                // address purely from `saved`, unchanged from this feature's original behavior.
                shareAddressOverride: nil
            )
        case .nearbyOnly(let live):
            LiveStationRowCard(
                station: live,
                isSaved: false,
                communitySummary: communitySummary(for: live),
                directionsAction: { directionsMessage(for: live) },
                reportPriceAction: { beginPriceUpdate(for: live) },
                // PR D — the Classic nearby-station action is now Favorite, matching the
                // premium map: one tap saves the station AND marks it favorite.
                saveAction: { saveLiveStation(live, markFavorite: true) }
            )
        case .merged(let saved, let live):
            if stationListFilter == .nearby {
                LiveStationRowCard(
                    station: live,
                    isSaved: true,
                    communitySummary: communitySummary(for: saved),
                    directionsAction: { directionsMessage(for: live) },
                    reportPriceAction: { beginPriceUpdate(for: saved) },
                    saveAction: { }
                )
            } else {
                StationRowCard(
                    station: saved,
                    communitySummary: communitySummary(for: saved),
                    directionsAction: { directionsMessage(for: saved) },
                    updatePriceAction: { beginPriceUpdate(for: saved) },
                    favoriteAction: { toggleFavorite(saved) },
                    editAction: { sheetStation = saved },
                    deleteAction: { stationPendingDeletion = saved },
                    // 2.3.2 gate fix — a merged item: pass the per-field-resolved Share
                    // address (item.shareAddress) so a saved record missing e.g. city/ZIP still
                    // shares the fuller address the matching live record has, rather than the
                    // truncated one `saved` alone would produce.
                    shareAddressOverride: item.shareAddress
                )
            }
        }
    }

    @ViewBuilder
    private var emptyStateForCurrentFilter: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stationListFilter {
        case .all:
            if trimmed.isEmpty == false {
                searchNoResultsCard
            } else if stations.isEmpty {
                allEmptyStateCard
            }
        case .saved:
            if trimmed.isEmpty == false {
                searchNoResultsCard
            } else {
                allEmptyStateCard
            }
        case .nearby:
            if trimmed.isEmpty == false {
                searchNoResultsCard
            } else if liveSearchError == nil {
                nearbyPromptCard
            }
        }
    }

    private var allEmptyStateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title2)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.Colors.stationYellow.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("No Saved Stations")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Use Find Nearby E85 or Trip Planner to search for stations. Saved stations stay local on this device.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var nearbyPromptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.Colors.primaryGreen.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("No nearby results yet.")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Tap Find Nearby E85 to search near your current location, or enter a city/state/ZIP in Trip Planner to plan ahead.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var searchNoResultsCard: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("No stations match your search.")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    if trimmed.isEmpty == false {
                        Text("No results for \"\(trimmed)\".")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var radiusSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(radiusOptions, id: \.self) { radius in
                    Button {
                        AppHaptics.selection()
                        selectedRadius = radius
                    } label: {
                        Text(radius)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selectedRadius == radius ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(selectedRadius == radius ? AppTheme.Colors.primaryGreen.opacity(0.22) : AppTheme.Colors.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(selectedRadius == radius ? AppTheme.Colors.primaryGreen : AppTheme.Colors.borderColor, lineWidth: 1)
                            )
                            .scaleEffect(selectedRadius == radius ? 1.03 : 1)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.28, dampingFraction: 0.76), value: selectedRadius)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "map.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.primaryGreen)

                Text("Station Map")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Spacer()

                if mappableStations.isEmpty == false || liveMapStations.isEmpty == false {
                    Button {
                        recenterMap()
                        AppHaptics.selection()
                    } label: {
                        Label("Show All", systemImage: "scope")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AppTheme.Colors.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            ZStack(alignment: .bottomLeading) {
                Map(position: $mapPosition, interactionModes: .all) {
                    if locationManager.isAuthorizedForUserLocation {
                        UserAnnotation()
                    }

                    ForEach(mappableStations) { station in
                        Annotation(station.name, coordinate: station.coordinate, anchor: .bottom) {
                            Button {
                                selectedMapStationID = station.id
                                AppHaptics.selection()
                            } label: {
                                StationMapPin(isSelected: selectedMapStationID == station.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ForEach(liveMapStations) { station in
                        Annotation(station.name, coordinate: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude), anchor: .bottom) {
                            LiveStationMapPin()
                        }
                    }
                }
                .mapStyle(.standard)

                if mappableStations.isEmpty, liveMapStations.isEmpty {
                    Text("Enable location or search nearby E85 to center the map near you.")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(10)
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    // Deliberately does NOT touch pendingLiveSearchReason — this button only
                    // wants to recenter the map (via the unconditional centerMap(on:) in the
                    // .onChange(of: locationManager.latestCoordinate) handler above), never to
                    // silently cancel an unrelated automatic/manual search that may already be
                    // genuinely awaiting this exact same coordinate fix.
                    locationManager.requestUserLocation()
                    AppHaptics.selection()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                        .frame(width: 32, height: 32)
                        .background(AppTheme.Colors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .padding(8)
            }

            if let selectedMapStation {
                selectedMapStationCard(selectedMapStation)
            }

            if locationManager.authorizationDenied {
                Text("Location access is off. Enable it in Settings to center the map near you.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var locationSearchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "map.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.primaryGreen)

                Text("Trip Planner")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                Text("· Plan E85 stops before you leave.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)

                    TextField("Search city, state, or ZIP", text: $locationSearchText)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($isTripPlannerFieldFocused)
                        .onSubmit { searchStationsNearTypedLocation() }

                    if locationSearchText.isEmpty == false {
                        Button {
                            locationSearchText = ""
                            locationSearchValidationMessage = nil
                            isTripPlannerFieldFocused = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppTheme.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            locationSearchValidationMessage != nil
                                ? AppTheme.Colors.warningRed.opacity(0.6)
                                : AppTheme.Colors.borderColor,
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    isTripPlannerFieldFocused = false
                    searchStationsNearTypedLocation()
                } label: {
                    Group {
                        if isGeocodingLocation {
                            ProgressView()
                                .tint(AppTheme.Colors.textPrimary)
                                .frame(width: 20, height: 20)
                        } else {
                            Text("Search")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(AppTheme.Colors.primaryGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isGeocodingLocation || isSearchingLive)
            }

            if let msg = locationSearchValidationMessage {
                Text(msg)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.warningRed)
                    .padding(.horizontal, 2)
            }
        }
        .padding(14)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var activeTripBanner: some View {
        if case .typedLocation(let name) = stationSearchSource {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.primaryGreen)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Searching Near")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)

                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    clearTrip()
                } label: {
                    Text("Clear Trip")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AppTheme.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.primaryGreen.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.Colors.primaryGreen.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func clearTrip() {
        liveSearchTask?.cancel()
        typedLocationSearchTask?.cancel()
        liveStations = []
        liveSearchError = nil
        isSearchingLive = false
        pendingLiveSearchReason = nil
        // See the identical fix/comment in .onDisappear -- cancelling typedLocationSearchTask
        // here without this would leave isGeocodingLocation stuck true if a typed-location
        // geocode was still in flight when Clear Trip was tapped.
        isGeocodingLocation = false
        stationSearchSource = .currentLocation
        stationListFilter = .all
        AppHaptics.selection()
        // PR #53 — returning to current-location mode after an explicit typed-location
        // search deserves a fresh initial framing (section 14); liveStations was just
        // cleared above, so this immediately reapplies the ~10-mile user-only fallback view
        // rather than leaving the old typed-location camera in place.
        premiumNearbyFramingState = .pending
        applyInitialPremiumNearbyFramingIfNeeded()
    }

    private func searchStationsNearTypedLocation() {
        let trimmed = locationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            locationSearchValidationMessage = "Enter a city, state, or ZIP code to search."
            return
        }

        // A new typed-location search always supersedes a still-in-flight one — mirrors
        // fetchLiveStations()'s own cancel-then-check pattern below, so a stale geocode result
        // can never mutate state after being superseded or after this view disappears.
        typedLocationSearchTask?.cancel()

        locationSearchValidationMessage = nil
        isGeocodingLocation = true
        liveSearchError = nil
        AppHaptics.selection()

        typedLocationSearchTask = Task { @MainActor in
            defer {
                // Runs on every exit from this closure (fall-through, or any early `return`
                // below) — guaranteeing the task handle is always cleared on a genuine
                // completion. Skipped when cancelled, so a superseded task's cleanup can never
                // stop a NEWER task's still-in-progress spinner or clear the newer task's own
                // handle out from under it.
                if Task.isCancelled == false {
                    isGeocodingLocation = false
                    typedLocationSearchTask = nil
                }
            }
            do {
                let placemarks = try await CLGeocoder().geocodeAddressString(trimmed)
                guard Task.isCancelled == false else { return }
                guard let placemark = placemarks.first, let location = placemark.location else {
                    liveSearchError = "Couldn't find that location. Try a city/state or ZIP code."
                    return
                }
                let coordinate = location.coordinate
                guard isValidCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
                    liveSearchError = "The location returned invalid coordinates. Try a different search."
                    return
                }
                let parts = [placemark.locality, placemark.administrativeArea]
                    .compactMap { $0 }
                    .filter { $0.isEmpty == false }
                let displayName = parts.isEmpty ? trimmed : parts.joined(separator: ", ")
                stationSearchSource = .typedLocation(name: displayName)
                stationListFilter = .nearby
                centerMap(on: coordinate)
                // Deliberately typed-location, not current-location — fetchLiveStations() below
                // only records into stationsSearchStore (the current-location nearby-search
                // cache) when stationSearchSource == .currentLocation, so this can never poison
                // that cache with a typed-location result. See stationsSearchStore's own header.
                fetchLiveStations(at: coordinate, limit: 50)
            } catch let clError as CLError {
                guard Task.isCancelled == false else { return }
                switch clError.code {
                case .geocodeFoundNoResult:
                    liveSearchError = "We couldn't find \"\(trimmed)\". Try a city, state, or ZIP code."
                case .network:
                    liveSearchError = "Location search failed. Check your connection and try again."
                default:
                    liveSearchError = "We couldn't find that location. Try a city, state, or ZIP code."
                }
            } catch {
                guard Task.isCancelled == false else { return }
                liveSearchError = "We couldn't find that location. Try a city, state, or ZIP code."
            }
        }
    }

    private var findNearbyButton: some View {
        Button {
            searchNearbyStations()
        } label: {
            HStack(spacing: 8) {
                if isSearchingLive {
                    ProgressView()
                        .tint(AppTheme.Colors.textPrimary)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                Text(isSearchingLive ? "Searching…" : "Find Nearby E85")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(AppTheme.Colors.primaryGreen)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSearchingLive)
    }

    private var liveSearchLoadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.Colors.primaryGreen)

            VStack(alignment: .leading, spacing: 4) {
                Text("Searching nearby E85 stations")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("Using your current location and the \(selectedRadius) radius.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func communitySyncMessageRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.3.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.stationYellow)

            Text(message)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func selectedMapStationCard(_ station: SavedStationMapItem) -> some View {
        let community = selectedMapStationCommunityPrice(for: station)

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name.isEmpty ? "Unnamed Station" : station.name)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                if station.lastKnownE85Price > 0 {
                    Text("Last E85 \(station.lastKnownE85Price.currencyText)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)

                    if let community {
                        Text("Community \(community.price.currencyText) · \(community.daysAgoText)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                } else if let community {
                    Text("Community E85 \(community.price.currencyText)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)

                    Text("Reported \(community.daysAgoText)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } else {
                    Text("No E85 price saved yet")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            Spacer()

            Text(station.lastUpdated.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .padding(14)
        .background(AppTheme.Colors.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func selectedMapStationCommunityPrice(for mapItem: SavedStationMapItem) -> (price: Double, daysAgoText: String)? {
        guard let fuelStation = stations.first(where: { $0.persistentModelID == mapItem.id }),
              let summary = communitySummary(for: fuelStation),
              let latestPrice = summary.latestPrice,
              let latestReportedAt = summary.latestReportedAt else {
            return nil
        }
        let days = Calendar.current.dateComponents([.day], from: latestReportedAt, to: .now).day ?? 0
        let daysText = days == 0 ? "today" : days == 1 ? "1 day ago" : "\(days) days ago"
        return (price: latestPrice, daysAgoText: daysText)
    }

    private var infoAlertBinding: Binding<Bool> {
        Binding(
            get: { infoMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    infoMessage = nil
                }
            }
        )
    }

    private func updateStation(_ station: FuelStation, from draft: StationDraft) {
        if draft.lastKnownE85Price != 0, StationDataValidation.isValidPrice(draft.lastKnownE85Price) == false {
            infoMessage = "Enter a valid E85 price greater than $0 (or leave it at $0 if unknown)."
            return
        }

        if let latitude = draft.latitude, let longitude = draft.longitude,
           StationDataValidation.isValidCoordinate(latitude: latitude, longitude: longitude) == false {
            infoMessage = "Enter a valid latitude (-90 to 90) and longitude (-180 to 180)."
            return
        }

        station.name = draft.name
        station.address = draft.address
        station.city = draft.city
        station.state = draft.state
        station.zipCode = draft.zipCode
        station.latitude = draft.latitude
        station.longitude = draft.longitude
        station.lastKnownE85Price = draft.lastKnownE85Price
        station.notes = draft.notes
        station.isFavorite = draft.isFavorite
        station.lastUpdated = .now
        station.updatedAt = .now
        do {
            try modelContext.save()
            AppHaptics.success()
        } catch {
            #if DEBUG
            print("[85Blends] StationsView: station update save failed:", error)
            #endif
            infoMessage = "Couldn't save changes. Please try again."
        }
        refreshCommunityPricePreviews()
    }

    private func toggleFavorite(_ station: FuelStation) {
        station.isFavorite.toggle()
        station.updatedAt = .now
        do {
            try modelContext.save()
            AppHaptics.selection()
        } catch {
            #if DEBUG
            print("[85Blends] StationsView: favorite toggle save failed:", error)
            #endif
            infoMessage = "Couldn't save changes. Please try again."
        }
        refreshCommunityPricePreviews()
    }

    private func confirmDeletion() {
        guard let stationPendingDeletion else { return }
        modelContext.delete(stationPendingDeletion)
        do {
            try modelContext.save()
            AppHaptics.warning()
        } catch {
            #if DEBUG
            print("[85Blends] StationsView: station deletion save failed:", error)
            #endif
            infoMessage = "Couldn't save changes. Please try again."
        }
        self.stationPendingDeletion = nil
        refreshCommunityPricePreviews()
    }

    private func recenterMap() {
        // Union of saved station pins + live nearby pins.
        let allCoordinates: [CLLocationCoordinate2D] =
            mappableStations.map(\.coordinate) +
            liveMapStations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        guard allCoordinates.isEmpty == false else {
            selectedMapStationID = nil
            // Fallback: user location → neutral US overview.
            if let userCoord = locationManager.latestCoordinate?.clCoordinate,
               locationManager.isAuthorizedForUserLocation {
                centerMap(on: userCoord)
            } else {
                mapPosition = .region(StationsView.neutralUSRegion)
            }
            return
        }

        if allCoordinates.count == 1 {
            mapPosition = .region(MKCoordinateRegion(
                center: allCoordinates[0],
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            ))
            if mappableStations.count == 1 {
                selectedMapStationID = mappableStations.first?.id
            }
            return
        }

        let latitudes = allCoordinates.map(\.latitude)
        let longitudes = allCoordinates.map(\.longitude)

        guard
            let minLatitude = latitudes.min(),
            let maxLatitude = latitudes.max(),
            let minLongitude = longitudes.min(),
            let maxLongitude = longitudes.max()
        else { return }

        let latitudePadding = max((maxLatitude - minLatitude) * 0.35, 0.05)
        let longitudePadding = max((maxLongitude - minLongitude) * 0.35, 0.05)

        mapPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: (maxLatitude - minLatitude) + latitudePadding,
                longitudeDelta: (maxLongitude - minLongitude) + longitudePadding
            )
        ))
    }

    private func searchNearbyStations() {
        guard isSearchingLive == false else { return }
        liveSearchError = nil
        // PR #53 — only reset the initial-framing state when this call is actually resuming
        // current-location mode from an active typed-location search (section 14); an
        // ordinary manual refresh that was already in current-location mode must not reset
        // it, or every tap of this button (also the premium map's own header refresh) would
        // re-snap the camera, violating the "no repeated snapping" requirement.
        if case .typedLocation = stationSearchSource {
            premiumNearbyFramingState = .pending
        }
        stationSearchSource = .currentLocation

        if let coordinate = locationManager.latestCoordinate {
            let userCoordinate = coordinate.clCoordinate
            guard isValidCoordinate(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude) else {
                liveStations = []
                liveSearchError = "Current location is unavailable. Try again in a moment."
                return
            }

            centerMap(on: userCoordinate)
            fetchLiveStations(at: userCoordinate)
            refreshPumpDetectionMonitoredStations(reason: "Find Nearby E85 tapped")
        } else if locationManager.authorizationDenied {
            pendingLiveSearchReason = nil
            locationDeniedAlert = true
        } else {
            pendingLiveSearchReason = .manualNearby
            locationManager.requestUserLocation()
        }
    }

    /// Whether the tab-open auto-trigger (see performAutomaticNearbySearchIfNeeded()) should
    /// perform a nearby search right now. False whenever an explicit typed-location Trip
    /// Planner search is active (that's deliberate user intent this trigger must never
    /// override), a search is already in flight or pending, or the last current-location
    /// search happened within `autoNearbySearchCooldown`.
    private func shouldPerformAutomaticNearbySearch() -> Bool {
        guard stationSearchSource == .currentLocation else { return false }
        guard isSearchingLive == false, pendingLiveSearchReason == nil else { return false }
        // Backed by the shared, session-scoped store (not view-local @State) so this cooldown
        // survives Stations view-state churn — see StationsRecentSearchStore.
        if let lastSearchAt = stationsSearchStore.lastCurrentLocationSearchAt,
           Date.now.timeIntervalSince(lastSearchAt) < Self.autoNearbySearchCooldown {
            return false
        }
        return true
    }

    /// UX improvement — automatically populates the Nearby E85 feed when the Stations tab
    /// becomes active, instead of requiring a manual "Find Nearby E85" tap every time. Mirrors
    /// searchNearbyStations()'s own location-availability branching (already-available
    /// coordinate vs. request-then-wait-for-the-.onChange-handler vs. denied), with the
    /// differences an automatic, non-user-initiated trigger needs:
    ///   1. Denied/restricted authorization silently no-ops instead of presenting
    ///      locationDeniedAlert — an alert popping up on every tab open, with no tap to
    ///      explain it, is exactly the kind of disruptive behavior this feature must avoid.
    ///      The existing "Find Nearby E85" button (and its alert, when tapped) is unchanged.
    ///   2. Gated by shouldPerformAutomaticNearbySearch()'s cooldown, so switching tabs
    ///      repeatedly reuses the existing results instead of re-fetching every time.
    ///   3. 2.3.2 release-prep fix — not-yet-determined authorization ALSO silently no-ops,
    ///      exactly like denied/restricted, rather than requesting user location. Only
    ///      `locationManager.isAuthorizedForUserLocation` (i.e. already `.authorizedWhenInUse`/
    ///      `.authorizedAlways`) may request a fresh fix from this automatic trigger — mirroring
    ///      CalculatorView.requestPumpModeLocationIfNeeded()'s existing guard for the identical
    ///      reason. Stations became the default launch tab in 2.3.2 (PR #55), so this function
    ///      now fires unconditionally on first appearance after onboarding/every cold launch,
    ///      not just when a user chose to tap into Stations — an automatic, non-tap-initiated
    ///      trigger must never itself produce the OS location-permission dialog. The explicit
    ///      "Find Nearby E85" button (searchNearbyStations(), above) is a real user action and
    ///      is unchanged: it still requests location — and therefore still prompts — regardless
    ///      of authorization status, including `.notDetermined`.
    private func performAutomaticNearbySearchIfNeeded() {
        guard shouldPerformAutomaticNearbySearch() else { return }

        if let coordinate = locationManager.latestCoordinate {
            let userCoordinate = coordinate.clCoordinate
            guard isValidCoordinate(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude) else {
                return
            }
            // PR #53 — same premium/Classic split as the latestCoordinate onChange above.
            if usesPremiumStationsMapPresentation {
                applyInitialPremiumNearbyFramingIfNeeded()
            } else {
                centerMap(on: userCoordinate)
            }
            fetchLiveStations(at: userCoordinate)
            refreshPumpDetectionMonitoredStations(reason: "Stations tab opened")
        } else if locationManager.isAuthorizedForUserLocation {
            pendingLiveSearchReason = .automaticNearby
            locationManager.requestUserLocation()
        }
        // Denied/restricted, or not yet determined: intentionally silent — see header comment
        // above. A not-yet-determined user must take an explicit action (e.g. "Find Nearby
        // E85") before this automatic tab-open trigger may prompt for location.
    }

    /// Stations instant-loading foundation (2.3.2, PR A) — hydrates `liveStations` synchronously
    /// from the shared, session-scoped StationsRecentSearchStore the moment this view appears,
    /// so a compatible recent nearby-search snapshot renders immediately instead of waiting for
    /// a fresh Core Location fix + network round trip. Only ever populates an EMPTY
    /// `liveStations` — never overwrites already-loaded in-memory results from earlier in this
    /// same view's lifetime, so this can only improve a cold/first appearance, never regress an
    /// already-populated one.
    ///
    /// Purely a display hydration: it never marks the automatic-search cooldown itself (only a
    /// real fetchLiveStations() call does that, via
    /// stationsSearchStore.recordCurrentLocationSearchAttempt(at:)), so
    /// performAutomaticNearbySearchIfNeeded() immediately after this call still runs its own
    /// unchanged cooldown/authorization logic and decides, independently, whether a quiet
    /// background refresh is actually warranted right now — that existing gated auto-trigger IS
    /// this feature's "stale-while-refresh" refresh step, not a second mechanism.
    private func hydrateFromRecentSearchCacheIfNeeded() {
        guard stationSearchSource == .currentLocation else { return }
        guard liveStations.isEmpty else { return }

        let radiusValue = selectedRadiusMiles
        let coordinate = locationManager.latestCoordinate

        switch stationsSearchStore.compatibleSnapshot(near: coordinate, radiusMiles: radiusValue, now: .now) {
        case .fresh(let snapshot):
            // `.fresh` is ONLY ever returned when a real coordinate was already supplied and
            // matched within radius (compatibleSnapshot's own no-coordinate branch below always
            // returns `.staleButUsable`, never `.fresh`) — already GPS-validated, disk-restored
            // or not. Existing PR A/#48 session-cache behavior — completely unchanged (section 20).
            liveStations = recomputedDistances(for: snapshot.stations, from: coordinate)
            return
        case .staleButUsable(let snapshot):
            // Gate-fix (adversarial audit finding) — compatibleSnapshot's own no-coordinate
            // branch returns `.staleButUsable` for ANY snapshot <=30 minutes old with no way to
            // tell "this process's own brief background gap" (PR A/#48's original, accepted
            // case — the process never stopped) apart from "this snapshot was restored from
            // disk after a full relaunch, possibly in a materially different place, minutes
            // ago" — only snapshotOrigin can. Trusting the latter outright here would let a
            // wrong-city preview slip past the persisted-preview tier's own GPS validation
            // entirely (isShowingUnvalidatedPersistedStations would never be set, so
            // validateProvisionalPersistedPreviewIfNeeded would later no-op even once real GPS
            // proved it wrong). A same-session snapshot (.currentSession) keeps the exact
            // existing PR A/#48 behavior, byte-identical; only a disk-restored snapshot with no
            // coordinate yet is redirected to the persisted-preview tier below instead —
            // compatibleSnapshot itself remains completely untouched either way (section 20).
            guard coordinate == nil, stationsSearchStore.snapshotOrigin == .restoredFromDisk else {
                liveStations = recomputedDistances(for: snapshot.stations, from: coordinate)
                return
            }
        case .incompatible, .none:
            break
        }

        // Cross-launch cache (2.3.2, PR #54, section 23) — no session-compatible snapshot was
        // available (most commonly: this IS a cold launch, and the restored disk snapshot is
        // older than compatibleSnapshot's own 30-minute session ceiling, though still within
        // the separate, more permissive persistentPreviewCeiling). Falls through to the
        // SEPARATE persisted-preview policy rather than ever widening compatibleSnapshot
        // itself. Section 26 — never show a persisted current-location preview once location
        // authorization is not currently granted, even though the file itself may still exist.
        guard locationManager.isAuthorizedForUserLocation else { return }

        switch stationsSearchStore.persistedPreviewCompatibility(near: coordinate, radiusMiles: radiusValue) {
        case .validated(let snapshot):
            // A coordinate was already known (e.g. the app-foreground prewarm) AND it matches
            // the restored snapshot's search center — hydrate immediately, already validated,
            // exactly like a normal session-compatible hit (section 24). The subsequent
            // applyInitialPremiumNearbyFramingIfNeeded()/recenterMap() call in .onAppear
            // already has both a real coordinate and populated station data at this point, so
            // no separate camera handling is needed here.
            liveStations = recomputedDistances(for: snapshot.stations, from: coordinate)
            isShowingUnvalidatedPersistedStations = false
        case .provisional(let snapshot):
            // The key cold-launch case (section 25): no coordinate yet to validate against.
            // Hydrate as PROVISIONAL — distances are shown using the persisted (uncorrected)
            // values, exactly as compatibleSnapshot's own no-coordinate branch already does for
            // the session cache; there is nothing better to compute against yet.
            liveStations = snapshot.stations
            isShowingUnvalidatedPersistedStations = true
            applyProvisionalPersistedPreviewFramingIfNeeded(center: snapshot.center.clCoordinate)
        case .incompatibleLocation:
            // A coordinate was already known and proves the restored snapshot belongs to a
            // materially different area (section 24) — never display it, and there is no
            // benefit to re-discovering the same known-wrong snapshot again this process
            // (section 30).
            stationsSearchStore.discardRestoredSnapshot()
        case .unavailable:
            break
        }
    }

    /// Cross-launch cache (2.3.2, PR #54, sections 33-34) — camera-PREVIEW-ONLY anchor for the
    /// moment between a provisional disk-restored preview appearing and a real GPS fix
    /// arriving, so the premium map's initial camera doesn't linger on the North America
    /// neutral region while nothing else is known yet. The persisted snapshot's search center
    /// is used SOLELY as a temporary anchor for PR #53's own bounding-box helpers — it is NEVER
    /// treated as a real location fix (never assigned to locationManager.latestCoordinate,
    /// never used for Pump Mode/refreshPumpDetectionMonitoredStations). Classic needs no
    /// equivalent: recenterMap() already fits a bounding box around whatever
    /// mappableStations/liveMapStations exist regardless of user coordinate, so the
    /// provisional stations hydrated just above are already included the moment it next runs
    /// (section 35).
    ///
    /// Critically (section 34), this deliberately leaves premiumNearbyFramingState == .pending
    /// — never .framedWithStation — so applyInitialPremiumNearbyFramingIfNeeded() still runs
    /// its own real, GPS-driven framing (or upgrade) exactly once when a genuine coordinate
    /// arrives; this call is never a substitute for that one, only a placeholder until then.
    private func applyProvisionalPersistedPreviewFramingIfNeeded(center: CLLocationCoordinate2D) {
        guard usesPremiumStationsMapPresentation else { return }
        guard premiumNearbyFramingState == .pending else { return }

        let nearestStation = nearestPremiumStation(to: center)
        let coordinates = [center] + (nearestStation.map { [$0.coordinate] } ?? [])
        let region = initialFramingRegion(for: coordinates)
        withAnimation {
            mapPosition = .region(region)
        }
        // premiumNearbyFramingState deliberately left untouched at .pending — see header above.
    }

    /// Cross-launch cache (2.3.2, PR #54, section 28) — resolves a provisional disk-restored
    /// preview against a REAL coordinate the moment one arrives. Called from
    /// .onChange(of: locationManager.latestCoordinate) BEFORE that handler's own premium
    /// framing/centerMap/fetch logic (the ordering the task calls out as CRITICAL), so a
    /// provisional preview is always resolved before anything downstream relies on it. A
    /// complete no-op whenever no provisional preview is currently onscreen — this never
    /// touches an ordinary already-live, already-validated, or typed-location `liveStations`.
    private func validateProvisionalPersistedPreviewIfNeeded(against coordinate: StationCoordinate) {
        guard isShowingUnvalidatedPersistedStations else { return }
        guard stationSearchSource == .currentLocation else { return }

        switch stationsSearchStore.persistedPreviewCompatibility(near: coordinate, radiusMiles: selectedRadiusMiles) {
        case .validated:
            // CASE A (section 28) — compatible: keep the provisional stations, just recompute
            // their distances from the now-known real coordinate, and clear the provisional
            // flag. The caller's own subsequent applyInitialPremiumNearbyFramingIfNeeded()/
            // centerMap(on:) then runs normally, with premiumNearbyFramingState still .pending
            // (see applyProvisionalPersistedPreviewFramingIfNeeded's header), so this is the
            // one real, GPS-driven PR #53 initial frame for this session.
            liveStations = recomputedDistances(for: liveStations, from: coordinate)
            isShowingUnvalidatedPersistedStations = false
        case .provisional, .incompatibleLocation, .unavailable:
            // CASE B (section 28) — a real coordinate was just supplied, so `.provisional`
            // itself is unreachable here in practice; grouped with the genuine mismatch/expiry
            // cases and handled identically and conservatively: clear ONLY the provisional
            // `liveStations` (never saved stations/favorites — section 29), clear the
            // provisional flag, discard the mismatched/expired restored snapshot from memory +
            // disk (section 30), and reset the premium map's one-time framing state so the
            // real current-location frame the caller runs immediately after this is never
            // mistaken for a redundant repeat (section 48's Phoenix -> Los Angeles case).
            liveStations = []
            isShowingUnvalidatedPersistedStations = false
            stationsSearchStore.discardRestoredSnapshot()
            premiumNearbyFramingState = .pending
        }
    }

    /// A cached snapshot can be reused after the user has moved (within the compatibility
    /// drift tolerance enforced by StationsRecentSearchStore.compatibleSnapshot), but every
    /// station's `distanceMiles` was computed by the NREL API relative to the OLD search
    /// center, not the user's current position — displaying it verbatim could understate or
    /// overstate a station's real distance by up to that same drift amount (and, since the
    /// nearby list sorts by this field, could even show the wrong station as "closest").
    /// Recomputing it here — straight-line distance from the current coordinate, matching the
    /// same meters-per-mile conversion StationsRecentSearchStore already uses — keeps both the
    /// displayed figures and the sort order accurate to the user's real position instead of
    /// silently showing a stale number with no staleness indication. Falls back to the cached
    /// (uncorrected) values only when no current coordinate is available at all — there is
    /// nothing better to compute against in that case.
    private func recomputedDistances(for stations: [LiveFuelStation], from coordinate: StationCoordinate?) -> [LiveFuelStation] {
        guard let coordinate else { return stations }
        let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return stations.map { station in
            guard isValidCoordinate(latitude: station.latitude, longitude: station.longitude) else {
                return station
            }
            let stationLocation = CLLocation(latitude: station.latitude, longitude: station.longitude)
            let recomputedMiles = userLocation.distance(from: stationLocation) / 1609.34
            return LiveFuelStation(
                name: station.name,
                address: station.address,
                city: station.city,
                state: station.state,
                zip: station.zip,
                latitude: station.latitude,
                longitude: station.longitude,
                distanceMiles: recomputedMiles,
                phone: station.phone,
                accessHours: station.accessHours,
                dateLastConfirmed: station.dateLastConfirmed,
                fuelTypeCode: station.fuelTypeCode
            )
        }
    }

    /// Pull-to-refresh — see the `.refreshable` modifier in `stationsContent`.
    /// searchNearbyStations() already always searches immediately regardless of
    /// stationsSearchStore.lastCurrentLocationSearchAt (only
    /// shouldPerformAutomaticNearbySearch() ever consults that cooldown), so this needs no
    /// separate bypass to satisfy "pull-to-refresh always forces a refresh."
    private func performPullToRefresh() async {
        searchNearbyStations()
        // .refreshable's own spinner only needs to bridge the moment until the existing
        // liveSearchLoadingCard takes over as the ongoing indicator — kept short so the two
        // never visibly stack into "repeated spinners."
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    /// Feeds the current saved-station list into Automatic Pump Detection's monitor
    /// refresh — the service itself decides (via movement/authorization gates) whether a
    /// real rebuild is warranted, so this is safe to call from every location update.
    private func refreshPumpDetectionMonitoredStations(reason: String) {
        let snapshots = stations.map {
            SavedStationSnapshot(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, address: $0.address)
        }
        pumpDetectionService.refreshMonitoredStations(savedStations: snapshots, reason: reason)
    }

    private func centerMap(on coordinate: CLLocationCoordinate2D) {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
        withAnimation {
            mapPosition = .region(region)
        }
    }

    private func handleAuthorizationStatusChange(_ status: CLAuthorizationStatus) {
        guard status == .denied || status == .restricted else { return }

        pendingLiveSearchReason = nil
        locationDeniedAlert = true

        // Cross-launch cache (2.3.2, PR #54, section 42) — a provisional disk-restored preview
        // must not keep presenting as "nearby"/"current" once location authorization is no
        // longer granted, even though it was never GPS-validated or invalidated by a location
        // mismatch. Saved stations/favorites are completely untouched — only the provisional
        // current-location `liveStations`. Also discards the restored snapshot from disk:
        // once authorization is denied there is no near-term path back to validating it, and
        // section 42 itself prefers deleting it outright for privacy/simplicity.
        if isShowingUnvalidatedPersistedStations {
            liveStations = []
            isShowingUnvalidatedPersistedStations = false
            stationsSearchStore.discardRestoredSnapshot()
        }

        if locationManager.latestCoordinate == nil, mappableStations.isEmpty, liveStations.isEmpty {
            mapPosition = .region(StationsView.neutralUSRegion)
        }
    }

    /// PR #48 blocker fix — closes out a pending nearby-search wait when the `requestLocation()`
    /// it was waiting on fails instead of succeeding. Before this, only the success path
    /// (`.onChange(of: locationManager.latestCoordinate)` above) ever consumed
    /// `pendingLiveSearchReason`; a failure like `.locationUnknown` (no `.onChange`-visible
    /// mutation on `StationLocationManager` at all under the old code) left it set forever —
    /// permanently blocking `shouldPerformAutomaticNearbySearch()` for the rest of the session
    /// once triggered by an automatic tab-open search, since that gate requires
    /// `pendingLiveSearchReason == nil`. Driven by `locationFailureRevision`, not
    /// `lastLocationFailureCode` alone, so two consecutive identical failures (e.g.
    /// `.locationUnknown` while parked in a garage) are each independently observable — see
    /// that property's own header on `StationLocationManager`.
    ///
    /// No-op when nothing is pending (a failure from Pump Mode's or the app-foreground
    /// prewarm's own `requestLocation()` call — the same underlying `CLLocationManager`,
    /// see `StationLocationManager`'s header — must not touch Stations' state). When
    /// something IS pending, consumes it exactly once (mirrors the success path's own
    /// single-consumption via `fetchLiveStations()`'s `pendingLiveSearchReason = nil`) and
    /// never touches `liveStations`, `mappableStations`, saved stations, community-price
    /// data, `isSearchingLive` (never true here — mutually exclusive with a pending reason;
    /// only `fetchLiveStations()` sets it, and it clears `pendingLiveSearchReason` first),
    /// `StationsRecentSearchStore` (no cooldown/timestamp write — a failure recorded no
    /// results and must not poison a future compatible-snapshot check or suppress a real
    /// retry), or `recentLiveStationCache`. Never auto-retries `requestUserLocation()`.
    ///
    /// A `.denied`/`.restricted` failure already flips `authorizationStatus`, which fires the
    /// separate `.onChange(of: locationManager.authorizationStatus)` above into
    /// `handleAuthorizationStatusChange()` — that path already clears
    /// `pendingLiveSearchReason` and presents `locationDeniedAlert`. Deferring to it here
    /// (instead of alerting again) avoids a duplicate alert regardless of which `onChange`
    /// SwiftUI happens to dispatch first, since `locationManager.authorizationDenied` already
    /// reflects the final state by the time either fires (both properties are mutated
    /// synchronously within the same `didFailWithError` call, before either `onChange` runs).
    private func handlePendingLocationFailureIfNeeded() {
        guard let reason = pendingLiveSearchReason else { return }
        pendingLiveSearchReason = nil

        guard locationManager.authorizationDenied == false else { return }

        switch reason {
        case .automaticNearby:
            // Silent — matches performAutomaticNearbySearchIfNeeded()'s own denied-authorization
            // silence above; an unprompted alert on a background tab-open trigger the user never
            // asked for is exactly the disruptive behavior that function's header already rules out.
            break
        case .manualNearby:
            // Reuses the exact wording searchNearbyStations()/fetchLiveStations() already show for
            // an unavailable current location, rather than introducing a new message or modal.
            liveSearchError = "Current location is unavailable. Try again in a moment."
        }
    }

    private func fetchLiveStations(at coordinate: CLLocationCoordinate2D, limit: Int = 20) {
        liveSearchTask?.cancel()

        guard isValidCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            liveStations = []
            liveSearchError = "Current location is unavailable. Try again in a moment."
            pendingLiveSearchReason = nil
            isSearchingLive = false
            return
        }

        pendingLiveSearchReason = nil
        isSearchingLive = true
        liveSearchError = nil

        // Auto-search cooldown stamp — only for current-location searches (manual tap, header
        // refresh, pull-to-refresh, or the automatic tab-open trigger all funnel through here
        // with stationSearchSource == .currentLocation). An explicit Trip Planner search
        // targets a different place entirely and must never suppress a later current-location
        // auto-search — see shouldPerformAutomaticNearbySearch(). Stamped at request start (not
        // on success) so a failing/offline search still suppresses immediate auto-retry spam —
        // matches the exact prior timing, just relocated into the shared, session-scoped store
        // so this cooldown survives Stations view-state churn — see StationsRecentSearchStore.
        let isCurrentLocationSearch = stationSearchSource == .currentLocation
        if isCurrentLocationSearch {
            stationsSearchStore.recordCurrentLocationSearchAttempt(at: .now)
        }

        let radiusValue = Double(selectedRadius.replacingOccurrences(of: " mi", with: "")) ?? 25
        let service = NLRStationService()

        liveSearchTask = Task { @MainActor in
            do {
                let results = try await service.fetchNearbyE85Stations(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    radius: radiusValue,
                    limit: limit
                )
                guard Task.isCancelled == false else { return }
                liveStations = results
                // Cross-launch cache (2.3.2, PR #54, section 39) — a real, fresh network result
                // always fully supersedes any provisional disk-restored preview; explicit here
                // as a safety net even though every reachable path already resolves this flag
                // before a fetch can start (see validateProvisionalPersistedPreviewIfNeeded).
                isShowingUnvalidatedPersistedStations = false
                if results.isEmpty {
                    liveSearchError = "No E85 stations found within \(selectedRadius) of \(stationSearchSource.displayName). Try selecting a larger radius above."
                }
                // Shares this completed search with manually opened Pump Mode, so a
                // station the user just found (but hasn't saved) can still be recognized
                // if they're standing at it — see RecentLiveStationCache/PumpStationContextResolver.
                // Replaces (rather than merges with) any previous search's results, and
                // is not persisted — see RecentLiveStationCache's own documentation.
                recentLiveStationCache.replace(with: results, fetchedAt: Date())
                // Stations instant-loading foundation (2.3.2, PR A) — a SEPARATE, Stations-only
                // cache from the Pump-Mode-owned RecentLiveStationCache write above; additive,
                // never a replacement for it. Only for current-location searches, mirroring the
                // cooldown-stamp guard above — a typed-location search must never poison this
                // cache. See StationsRecentSearchStore's own header.
                if isCurrentLocationSearch {
                    stationsSearchStore.recordCurrentLocationSearchResult(
                        stations: results,
                        center: StationCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
                        radiusMiles: radiusValue,
                        fetchedAt: Date()
                    )
                }
                refreshCommunityPricePreviews()
            } catch {
                guard Task.isCancelled == false else { return }
                if case NRELServiceError.missingAPIKey = error {
                    liveSearchError = "Live station search is not available right now. Saved stations still work offline."
                } else if let urlError = error as? URLError,
                          urlError.code == .timedOut || urlError.code == .notConnectedToInternet {
                    liveSearchError = "Live station search is temporarily unavailable. Saved stations still work offline."
                } else {
                    liveSearchError = "Live station search failed. Saved stations still work offline."
                }
                refreshCommunityPricePreviews()
            }
            // PR #53 — after either outcome, give the premium map's one-time initial nearby
            // framing a chance to run/upgrade now that liveStations reflects this fetch's
            // actual result (empty or not). A no-op via its own internal guards for Classic, a
            // typed-location search, or a framing that already included a station.
            applyInitialPremiumNearbyFramingIfNeeded()
            isSearchingLive = false
            liveSearchTask = nil
        }
    }

    private func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude) && (latitude != 0 || longitude != 0)
    }

    /// PR #51 final gate — every current call site is a unified Favorite flow (both pass
    /// `markFavorite: true`; grepped and confirmed no other call site exists), so `markFavorite`
    /// has no default — a future caller must state its intent explicitly rather than silently
    /// creating a non-favorite station from what is now exclusively a Favorite-labeled action.
    /// `isFavorite: markFavorite` is set directly in FuelStation's own initializer, so the
    /// persisted station is favorite from the moment it's inserted — no second lookup/toggle
    /// call, no window where the station exists but isn't yet favorite.
    ///
    /// The final pre-merge gate's one required product fix: this function used to end with
    /// `beginPriceUpdate(for: saved)`, automatically opening the price-update sheet on every
    /// successful save — inherited from the old, separate "Save" workflow. Now that the
    /// user-facing action is explicitly Favorite, an automatic price prompt is no longer
    /// appropriate: Favorite and Report/Update Price are independent intentions, and a user who
    /// wants to report a price can already tap the card's own explicit Report/Update button
    /// (premiumReportPrice/beginPriceUpdate, untouched). Removed entirely — not made
    /// conditional — since both remaining call sites are Favorite flows with no legitimate
    /// save-then-prompt case left anywhere in this codebase.
    private func saveLiveStation(_ station: LiveFuelStation, markFavorite: Bool) {
        if isLiveStationSaved(station) {
            infoMessage = "This station is already saved."
            AppHaptics.selection()
            return
        }

        let saved = FuelStation(
            name: station.name,
            address: station.address,
            city: station.city,
            state: station.state,
            zipCode: station.zip,
            latitude: station.latitude == 0 ? nil : station.latitude,
            longitude: station.longitude == 0 ? nil : station.longitude,
            isFavorite: markFavorite
        )
        modelContext.insert(saved)
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("[85Blends] StationsView: live station save failed:", error)
            #endif
            infoMessage = "Couldn't save station. Please try again."
            return
        }
        AppHaptics.success()
        refreshCommunityPricePreviews()
    }

    private func isLiveStationSaved(_ station: LiveFuelStation) -> Bool {
        stations.contains { savedStation in
            matchesSavedStation(savedStation, liveStation: station)
        }
    }

    private func matchesSavedStation(_ savedStation: FuelStation, liveStation: LiveFuelStation) -> Bool {
        let savedName = normalizedStationText(savedStation.name)
        let savedAddress = normalizedStationText(savedStation.address)
        let liveName = normalizedStationText(liveStation.name)
        let liveAddress = normalizedStationText(liveStation.address)

        if savedName.isEmpty == false,
           savedAddress.isEmpty == false,
           savedName == liveName,
           savedAddress == liveAddress {
            return true
        }

        guard
            let savedLatitude = savedStation.latitude,
            let savedLongitude = savedStation.longitude,
            isValidCoordinate(latitude: savedLatitude, longitude: savedLongitude),
            isValidCoordinate(latitude: liveStation.latitude, longitude: liveStation.longitude)
        else {
            return false
        }

        return abs(savedLatitude - liveStation.latitude) <= stationCoordinateTolerance &&
            abs(savedLongitude - liveStation.longitude) <= stationCoordinateTolerance
    }

    private func normalizedStationText(_ value: String) -> String {
        CommunityStationKey.normalizedText(value)
    }

    private func normalizedStationKey(for station: FuelStation) -> String? {
        normalizedStationKey(
            name: station.name,
            streetAddress: station.address,
            city: station.city,
            state: station.state,
            zip: station.zipCode,
            latitude: station.latitude,
            longitude: station.longitude
        )
    }

    private func normalizedStationKey(for station: LiveFuelStation) -> String? {
        // Zero here means "no coordinate" (LiveFuelStation.init(from:) defaults to 0/0 when NREL
        // supplies none) — mirrors StationPriceUpdateContext.live(_:)'s existing 0→nil
        // normalization so canonicalKey never mistakes NREL's missing-coordinate sentinel for a
        // real Null Island location.
        normalizedStationKey(
            name: station.name,
            streetAddress: station.address,
            city: station.city,
            state: station.state,
            zip: station.zip,
            latitude: station.latitude == 0 ? nil : station.latitude,
            longitude: station.longitude == 0 ? nil : station.longitude
        )
    }

    /// Every Community Pricing read AND write path in this view funnels through here — see
    /// CommunityStationKey.canonicalKey's own doc comment (CommunityPriceEligibility.swift) for
    /// the full address-vs-coordinate identity rule this now applies uniformly.
    private func normalizedStationKey(
        name: String,
        streetAddress: String,
        city: String,
        state: String,
        zip: String,
        latitude: Double?,
        longitude: Double?
    ) -> String? {
        CommunityStationKey.canonicalKey(
            name: name,
            streetAddress: streetAddress,
            city: city,
            state: state,
            zip: zip,
            latitude: latitude,
            longitude: longitude
        )
    }

    private func communitySummary(for station: FuelStation) -> CommunityPriceSummary? {
        guard let key = normalizedStationKey(for: station) else { return nil }
        return communityPriceSummaries[key]
    }

    private func communitySummary(for station: LiveFuelStation) -> CommunityPriceSummary? {
        guard let key = normalizedStationKey(for: station) else { return nil }
        return communityPriceSummaries[key]
    }

    private func refreshCommunityPricePreviews() {
        communityPriceTask?.cancel()

        let keys = Set(
            stations.compactMap(normalizedStationKey(for:)) +
            liveStations.compactMap(normalizedStationKey(for:))
        )

        guard keys.isEmpty == false else {
            communityPriceSummaries = [:]
            communityPriceSyncMessage = nil
            return
        }

        communityPriceTask = Task {
            do {
                let service = try CommunityPriceService()
                let summaries = try await fetchCommunitySummaries(keys: keys, service: service)
                guard Task.isCancelled == false else { return }
                await MainActor.run {
                    communityPriceSummaries = summaries
                    communityPriceSyncMessage = nil
                }
            } catch {
                guard Task.isCancelled == false else { return }
                await MainActor.run {
                    communityPriceSummaries = [:]
                    if let serviceError = error as? CommunityPriceServiceError,
                       case .notConfigured = serviceError {
                        communityPriceSyncMessage = "Community prices are not available right now."
                    } else {
                        communityPriceSyncMessage = "Community prices are temporarily unavailable. Local prices are still shown."
                    }
                }
            }
        }
    }

    private func fetchCommunitySummaries(
        keys: Set<String>,
        service: CommunityPriceService
    ) async throws -> [String: CommunityPriceSummary] {
        try await withThrowingTaskGroup(of: (String, CommunityPriceSummary?).self) { group in
            for key in keys {
                group.addTask {
                    let summary = try await service.fetchLatestPrice(forNormalizedStationKey: key)
                    return (key, summary)
                }
            }

            var summaries: [String: CommunityPriceSummary] = [:]
            for try await (key, summary) in group {
                if let summary {
                    summaries[key] = summary
                }
            }
            return summaries
        }
    }

    private func directionsMessage(for station: FuelStation) -> String? {
        let message = MapsRoutingHelper.openDirections(
            to: MapsRoutingDestination(
                name: station.name,
                streetAddress: station.address,
                city: station.city,
                state: station.state,
                zip: station.zipCode,
                latitude: station.latitude,
                longitude: station.longitude
            )
        )

        if message == nil {
            AppHaptics.selection()
        }

        return message
    }

    private func directionsMessage(for station: LiveFuelStation) -> String? {
        let message = MapsRoutingHelper.openDirections(
            to: MapsRoutingDestination(
                name: station.name,
                streetAddress: station.address,
                city: station.city,
                state: station.state,
                zip: station.zip,
                latitude: station.latitude == 0 ? nil : station.latitude,
                longitude: station.longitude == 0 ? nil : station.longitude
            )
        )

        if message == nil {
            AppHaptics.selection()
        }

        return message
    }

    private func beginPriceUpdate(for station: FuelStation) {
        // A celebration from a previous report shouldn't linger into an unrelated new operation.
        dismissCommunityReportSuccess()
        priceInput = station.lastKnownE85Price > 0 ? String(format: "%.2f", station.lastKnownE85Price) : ""
        priceNoteInput = station.notes
        priceValidationMessage = nil
        priceUpdateContext = .saved(station)
    }

    private func beginPriceUpdate(for station: LiveFuelStation) {
        // Same as the saved-station overload above — Nearby and Saved share identical handling.
        dismissCommunityReportSuccess()
        priceInput = ""
        priceNoteInput = ""
        priceValidationMessage = nil
        priceUpdateContext = .live(station)
    }

    private func dismissPriceUpdateSheet() {
        isSubmittingCommunityPrice = false
        priceUpdateContext = nil
        priceInput = ""
        priceNoteInput = ""
        priceValidationMessage = nil
    }

    /// The one and only call site for showing the celebration — invoked exactly where
    /// `savePriceUpdate` has already confirmed the remote community submission succeeded, never
    /// earlier in that async operation. Fires the success haptic immediately before presenting,
    /// matching the required "haptic → overlay presents" sequence.
    private func presentCommunityReportSuccess() {
        communityReportSuccessDismissTask?.cancel()
        AppHaptics.success()
        communityReportCelebration.present()
        communityReportSuccessDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard Task.isCancelled == false else { return }
            dismissCommunityReportSuccess()
        }
    }

    /// Cleanly cancels any pending auto-dismiss — called on manual "Awesome" tap, on auto-dismiss
    /// itself, when this view disappears, and when a new price-update flow begins — so the
    /// celebration can never double-dismiss or survive into an unrelated station operation.
    private func dismissCommunityReportSuccess() {
        communityReportSuccessDismissTask?.cancel()
        communityReportSuccessDismissTask = nil
        communityReportCelebration.dismiss()
    }

    private func savePriceUpdate(for context: StationPriceUpdateContext, reportToCommunity: Bool) {
        if reportToCommunity, isSubmittingCommunityPrice {
            return
        }

        let trimmedPrice = priceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedPrice = Double(trimmedPrice), parsedPrice > 0 else {
            priceValidationMessage = "Enter a valid E85 price to continue."
            return
        }

        let roundedLocalPrice = roundedPrice(parsedPrice)
        let trimmedNote = priceNoteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = upsertLocalStation(for: context, price: roundedLocalPrice, note: trimmedNote)
        do {
            try modelContext.save()
            // Save Locally gets its one success haptic right here. Save & Report defers success
            // feedback entirely to presentCommunityReportSuccess() below, which fires the single
            // haptic only once the remote community submission is confirmed to have succeeded —
            // see CommunityReportCelebrationDecision.shouldFireLocalSaveHaptic's doc comment.
            if CommunityReportCelebrationDecision.shouldFireLocalSaveHaptic(reportToCommunity: reportToCommunity) {
                AppHaptics.success()
            }
        } catch {
            #if DEBUG
            print("[85Blends] StationsView: price update save failed:", error)
            #endif
            infoMessage = "Couldn't save changes. Please try again."
        }
        refreshCommunityPricePreviews()

        guard reportToCommunity, context.canReportToCommunity else {
            if reportToCommunity {
                infoMessage = "Price saved locally. This station doesn't have enough location information to report to the community yet."
            }
            dismissPriceUpdateSheet()
            return
        }

        isSubmittingCommunityPrice = true

        Task {
            // nil only on the success path — the community submission is confirmed to have
            // succeeded (both requests below completed without throwing) at the point this stays
            // nil. Everything downstream of the do/catch branches on exactly this, so the
            // celebration can only ever be triggered by a genuine, already-confirmed success.
            var failureMessage: String?

            do {
                let service = try CommunityPriceService()
                let normalizedKey = normalizedStationKey(for: context)
                let communityStation = try await service.upsertCommunityStation(
                    normalizedStationKey: normalizedKey,
                    name: context.stationName,
                    streetAddress: context.optionalAddress,
                    city: context.optionalCity,
                    state: context.optionalState,
                    zip: context.optionalZipCode,
                    latitude: context.latitude,
                    longitude: context.longitude
                )

                _ = try await service.submitPriceReport(
                    normalizedStationKey: normalizedKey,
                    stationID: communityStation.id,
                    price: roundedLocalPrice,
                    reportedAt: .now,
                    notes: trimmedNote.isEmpty ? nil : trimmedNote,
                    appVersion: appVersionString
                )
            } catch {
#if DEBUG
                print("Community price report failed:", error)
#endif
                if let serviceError = error as? CommunityPriceServiceError,
                   case .notConfigured = serviceError {
                    failureMessage = "Price saved locally. Community reporting is not available right now."
                } else {
                    failureMessage = "Price saved locally. Community report could not be submitted — please try again later."
                }
            }

            await MainActor.run {
                refreshCommunityPricePreviews()
                dismissPriceUpdateSheet()
                let shouldCelebrate = CommunityReportCelebrationDecision.shouldCelebrate(
                    reportToCommunity: reportToCommunity,
                    submissionSucceeded: failureMessage == nil
                )
                if shouldCelebrate {
                    presentCommunityReportSuccess()
                } else if let failureMessage {
                    infoMessage = failureMessage
                }
            }
        }
    }

    private func roundedPrice(_ price: Double) -> Double {
        (price * 100).rounded() / 100
    }

    private func upsertLocalStation(
        for context: StationPriceUpdateContext,
        price: Double,
        note: String
    ) -> FuelStation {
        let station: FuelStation

        if let existingStation = context.station {
            station = existingStation
        } else if let matchedSavedStation = matchingSavedStation(for: context) {
            station = matchedSavedStation
        } else {
            let createdStation = FuelStation(
                name: context.stationName,
                address: context.address,
                city: context.city,
                state: context.state,
                zipCode: context.zipCode,
                latitude: context.latitude,
                longitude: context.longitude
            )
            modelContext.insert(createdStation)
            station = createdStation
        }

        station.name = context.stationName
        station.address = context.address
        station.city = context.city
        station.state = context.state
        station.zipCode = context.zipCode
        station.latitude = context.latitude
        station.longitude = context.longitude
        station.lastKnownE85Price = price
        station.lastUpdated = .now
        station.updatedAt = .now
        station.notes = note
        return station
    }

    private func matchingSavedStation(for context: StationPriceUpdateContext) -> FuelStation? {
        stations.first { savedStation in
            if normalizedStationText(savedStation.name) == normalizedStationText(context.stationName),
               normalizedStationText(savedStation.address) == normalizedStationText(context.address),
               normalizedStationText(savedStation.city) == normalizedStationText(context.city),
               normalizedStationText(savedStation.state) == normalizedStationText(context.state),
               normalizedStationText(savedStation.zipCode) == normalizedStationText(context.zipCode) {
                return true
            }

            guard
                let savedLatitude = savedStation.latitude,
                let savedLongitude = savedStation.longitude,
                let contextLatitude = context.latitude,
                let contextLongitude = context.longitude
            else {
                return false
            }

            return abs(savedLatitude - contextLatitude) <= stationCoordinateTolerance &&
                abs(savedLongitude - contextLongitude) <= stationCoordinateTolerance
        }
    }

    private func normalizedStationKey(for context: StationPriceUpdateContext) -> String {
        normalizedStationKey(
            name: context.stationName,
            streetAddress: context.address,
            city: context.city,
            state: context.state,
            zip: context.zipCode,
            latitude: context.latitude,
            longitude: context.longitude
        ) ?? normalizedStationText(context.stationName)
    }
}

#Preview {
    StationsView()
        .modelContainer(for: FuelStation.self, inMemory: true)
        .environment(StationLocationManager())
}

/// Identifies WHY a location fix is currently being awaited, so one flow can never silently
/// cancel or resume in place of another — see the map's "locate me" button (which deliberately
/// does NOT set this — it only wants to recenter) and every read/write site's own comment.
/// Deliberately small (no `.mapRecentering` case, no larger state machine) — derived only from
/// the searches that actually exist today; pull-to-refresh shares `.manualNearby` since it
/// literally calls the same `searchNearbyStations()` function.
private enum PendingLiveSearchReason: Equatable {
    case automaticNearby
    case manualNearby
}

private enum StationSearchSource: Equatable {
    case currentLocation
    case typedLocation(name: String)

    var displayName: String {
        switch self {
        case .currentLocation: return "your location"
        case .typedLocation(let name): return name
        }
    }
}

private enum StationListFilter: String, CaseIterable {
    case all = "All"
    case saved = "Saved"
    case nearby = "Nearby"

    var title: String { rawValue }
}

/// 85Blends 2.3.2 — centralized station-share formatting, used identically by the Pro Stations
/// map's selected-station card (ProStationsMapView.swift) and Classic's StationRowCard/
/// LiveStationRowCard below, so all three presentation paths produce byte-identical share text
/// from the same station data — never three competing string-builders. Deliberately internal
/// (not private): ProStationsMapView.swift is a separate file in the same module/target and
/// calls this directly, with no project.pbxproj change needed. Pure and stateless: every
/// function takes plain values and returns a plain String — no network call, no station-model
/// mutation, no SwiftUI/@State dependency, so it can never fail and never has a navigation/data
/// side effect regardless of which of the three call sites invokes it.
enum StationShareContent {
    /// 85Blends' live App Store listing — fixed, developer-owned text; never generated,
    /// geocoded, or looked up. Distinct from SubscriptionManager.monthlyID (the in-app
    /// subscription's StoreKit product identifier) — this is the App Store LISTING url used for
    /// referral, an unrelated concern.
    static let appStoreURLString = "https://apps.apple.com/us/app/85blends/id6762037468"

    /// One clean US-style postal address line: "<street>, <city>, <state> <zip>" — never the
    /// Classic cards' own bullet-separated on-screen style ("<street> • <city>, <state> •
    /// <zip>"), which reads fine on screen but is awkward to select/copy/paste into a
    /// navigation app. Omits any empty component and never produces a stray leading/trailing/
    /// doubled comma or a double space, for every combination of present/absent components (see
    /// this feature's own static payload tests). Each component is trimmed of leading/trailing
    /// whitespace before use; the underlying station model itself is never mutated — this is
    /// formatting only, computed fresh from whatever the caller already has in hand.
    static func fullAddress(street: String, city: String, state: String, zip: String) -> String {
        let street = street.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let zip = zip.trimmingCharacters(in: .whitespacesAndNewlines)

        // "<city>, <state> <zip>" is built as one unit first (standard US postal punctuation —
        // a comma between city and state, a space, never a comma, before the ZIP), gracefully
        // degrading through every partial combination, before being joined to the street.
        let cityStateZip: String
        if city.isEmpty == false, state.isEmpty == false {
            cityStateZip = zip.isEmpty ? "\(city), \(state)" : "\(city), \(state) \(zip)"
        } else if city.isEmpty == false {
            cityStateZip = zip.isEmpty ? city : "\(city) \(zip)"
        } else if state.isEmpty == false {
            cityStateZip = zip.isEmpty ? state : "\(state) \(zip)"
        } else {
            cityStateZip = zip
        }

        return [street, cityStateZip]
            .filter { $0.isEmpty == false }
            .joined(separator: ", ")
    }

    /// 2.3.2 gate fix — Share-specific, per-field resolution for a merged saved+live station:
    /// "prefer a non-empty saved value, otherwise fall back to a non-empty nearby value."
    /// `saved`/`nearby` describe the same physical station, so borrowing a missing field from
    /// one to complete the other invents nothing. A whitespace-only saved value (e.g. `"   "`)
    /// is treated the same as an absent one so it cannot silently suppress a valid nearby
    /// fallback — this is the exact gap StationDisplayItem's plain `saved ?? nearby ?? ""`
    /// display* properties have, since `??` only falls through on `nil`, never on
    /// present-but-empty. Deliberately NOT used for those display* properties themselves — this
    /// is Share-only; on-screen presentation intentionally keeps preferring the saved record
    /// wholesale. Pure; never mutates either station.
    static func preferredValue(saved: String?, nearby: String?) -> String {
        let trimmedSaved = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedSaved.isEmpty == false {
            return trimmedSaved
        }
        return nearby?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The full deterministic share payload: station name, full postal address (omitted
    /// entirely — never a blank line — when `address` is empty), and the fixed 85Blends App
    /// Store referral footer. `address` is expected already-formatted, typically via
    /// fullAddress(street:city:state:zip:) above. Deliberately excludes price, distance, and
    /// Saved/Favorite state — all user-relative or time-sensitive — and deliberately excludes
    /// any map/coordinate URL: the plain-text postal address is the universal, navigation-app-
    /// agnostic location representation; the recipient chooses whichever app (Apple Maps,
    /// Google Maps, Waze, or otherwise) they prefer. Never force-unwraps anything; this function
    /// cannot fail.
    static func text(name: String, address: String) -> String {
        var lines = [name]
        if address.isEmpty == false {
            lines.append(address)
        }
        lines.append("")
        lines.append("Get 85Blends on the App Store:")
        lines.append(appStoreURLString)
        return lines.joined(separator: "\n")
    }
}

private struct StationDisplayItem: Identifiable {
    enum Content {
        case savedOnly(FuelStation)
        case nearbyOnly(LiveFuelStation)
        case merged(saved: FuelStation, nearby: LiveFuelStation)
    }

    let content: Content

    init(saved: FuelStation, nearby: LiveFuelStation? = nil) {
        if let nearby {
            content = .merged(saved: saved, nearby: nearby)
        } else {
            content = .savedOnly(saved)
        }
    }

    init(nearby: LiveFuelStation) {
        content = .nearbyOnly(nearby)
    }

    var id: String {
        switch content {
        case .savedOnly(let s): return "s_\(s.persistentModelID.hashValue)"
        case .nearbyOnly(let n): return "n_\(n.id.uuidString)"
        case .merged(let s, _): return "s_\(s.persistentModelID.hashValue)"
        }
    }

    var savedStation: FuelStation? {
        switch content {
        case .savedOnly(let s): return s
        case .merged(let s, _): return s
        case .nearbyOnly: return nil
        }
    }

    var nearbyStation: LiveFuelStation? {
        switch content {
        case .nearbyOnly(let n): return n
        case .merged(_, let n): return n
        case .savedOnly: return nil
        }
    }

    var isSaved: Bool { savedStation != nil }
    var isFavorite: Bool { savedStation?.isFavorite ?? false }
    var isNearby: Bool { nearbyStation != nil }

    var distanceMiles: Double? {
        guard let n = nearbyStation, n.distanceMiles > 0 else { return nil }
        return n.distanceMiles
    }

    var displayName: String { savedStation?.name ?? nearbyStation?.name ?? "" }
    var displayAddress: String { savedStation?.address ?? nearbyStation?.address ?? "" }
    var displayCity: String { savedStation?.city ?? nearbyStation?.city ?? "" }
    var displayState: String { savedStation?.state ?? nearbyStation?.state ?? "" }
    /// Added for Share (2.3.2) — same saved-preferred-over-nearby precedent every other
    /// display* property above already uses; FuelStation.zipCode and LiveFuelStation.zip are
    /// the same postal-code concept under different field names (see each model's own
    /// declaration). Not previously needed because no on-screen UI showed the ZIP on its own.
    var displayZip: String { savedStation?.zipCode ?? nearbyStation?.zip ?? "" }

    /// 2.3.2 gate fix — the canonical Share address for this item, resolved PER FIELD rather
    /// than reusing displayAddress/displayCity/displayState/displayZip above wholesale.
    /// Those display* properties are pre-existing ON-SCREEN presentation semantics that
    /// intentionally prefer the saved record in full whenever one exists — correct for display,
    /// but wrong for Share: a saved record with only a street and no city/ZIP would otherwise
    /// suppress a matching nearby (live) record's fuller address, even though both describe the
    /// same physical station and Share is meant to send the fullest truthful address available.
    /// StationShareContent.preferredValue(saved:nearby:) resolves each of street/city/state/zip
    /// independently — a non-empty (post-trim) saved value wins, an empty or whitespace-only one
    /// falls back to nearby, and both empty means that field is simply omitted, never invented.
    /// For a savedOnly or nearbyOnly item this is equivalent to the pre-existing behavior (only
    /// one side has any data to prefer). Presentation-only; never mutates either station.
    var shareAddress: String {
        StationShareContent.fullAddress(
            street: StationShareContent.preferredValue(saved: savedStation?.address, nearby: nearbyStation?.address),
            city: StationShareContent.preferredValue(saved: savedStation?.city, nearby: nearbyStation?.city),
            state: StationShareContent.preferredValue(saved: savedStation?.state, nearby: nearbyStation?.state),
            zip: StationShareContent.preferredValue(saved: savedStation?.zipCode, nearby: nearbyStation?.zip)
        )
    }
}

private struct StationRowCard: View {
    let station: FuelStation
    let communitySummary: CommunityPriceSummary?
    let directionsAction: () -> String?
    let updatePriceAction: () -> Void
    let favoriteAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void
    /// 2.3.2 gate fix — a pre-resolved Share address for a merged saved+live station (see
    /// StationDisplayItem.shareAddress), letting Share use the fuller of the two records
    /// field-by-field instead of `station` (the saved record) alone. `nil` for a true
    /// saved-only station, where there is no live counterpart to borrow a missing field from —
    /// `shareAddress` below then falls back to deriving the address purely from `station`,
    /// unchanged from this feature's original implementation. Presentation-only; never written
    /// back onto FuelStation.
    let shareAddressOverride: String?
    @State private var directionsMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.Colors.softGreenBackground)

                    Image(systemName: "fuelpump.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(station.name.isEmpty ? "Unnamed Station" : station.name)
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Spacer(minLength: 0)

                        Button(action: favoriteAction) {
                            Image(systemName: station.isFavorite ? "star.fill" : "star")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(station.isFavorite ? AppTheme.Colors.stationYellow : AppTheme.Colors.textMuted)
                                .frame(width: 30, height: 30)
                                .background(AppTheme.Colors.cardBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(station.isFavorite ? AppTheme.Colors.stationYellow.opacity(0.55) : AppTheme.Colors.borderColor, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Text(locationLine)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)

                    priceFreshnessBadge

                    Text(priceStatusText)
                        .font(.caption.weight(priceStale ? .semibold : .medium))
                        .foregroundStyle(priceStatusColor)
                }

                if station.lastKnownE85Price > 0 {
                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        Text("YOUR SAVED E85")
                            .font(.caption2.weight(.bold))
                            .tracking(1.0)
                            .foregroundStyle(AppTheme.Colors.textMuted)

                        Text(station.lastKnownE85Price.currencyText)
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.primaryGreen)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AppTheme.Colors.primaryGreen.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if station.lastKnownE85Price > 0 {
                    Text(priceFreshnessText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(priceStatusColor)
                } else {
                    Text("No E85 price saved yet")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                if station.notes.isEmpty == false {
                    Text(station.notes)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                communityPricePreview
            }

            HStack {
                Text(station.isFavorite ? "Favorite" : "Saved")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(station.isFavorite ? AppTheme.Colors.stationYellow : AppTheme.Colors.textSecondary)

                Spacer()

                Text("Last updated \(station.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        directionsMessage = directionsAction()
                    } label: {
                        Label("Directions", systemImage: "location.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppTheme.Colors.primaryGreen.opacity(0.20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(AppTheme.Colors.primaryGreen, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityLabel("Get directions to \(station.name)")

                    Button(action: updatePriceAction) {
                        Label("Update Price", systemImage: "tag.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.charcoal)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppTheme.Colors.stationYellow)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityLabel("Update E85 price for \(station.name)")
                }

                HStack(spacing: 8) {
                    // 2.3.2 — Share is available to every user (Free and Pro alike), never
                    // gated behind ProFeatureGate/SubscriptionManager/RevenueCat; sharing a
                    // station's location is core, not a Pro feature. Self-contained — builds
                    // its payload directly from `station` (already in hand), so no new
                    // required initializer parameter/call-site change was needed here. Native
                    // ShareLink only; no action closure exists to call, so this cannot mutate
                    // Favorite/Saved/price/selection/SwiftData or start any network call —
                    // dismissing the sheet leaves this card exactly as it was. 44x44 (this
                    // control only) — Edit/Delete below keep their existing, untouched 42x42
                    // targets.
                    ShareLink(item: StationShareContent.text(name: station.name, address: shareAddress)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .frame(width: 44, height: 44)
                            .background(AppTheme.Colors.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityLabel("Share \(station.name)")

                    Button(action: editAction) {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .frame(width: 42, height: 42)
                            .background(AppTheme.Colors.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityLabel("Edit \(station.name)")

                    Button(action: deleteAction) {
                        Image(systemName: "trash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.warningRed)
                            .frame(width: 42, height: 42)
                            .background(AppTheme.Colors.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityLabel("Delete \(station.name)")

                    Spacer()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(station.isFavorite ? AppTheme.Colors.stationYellow.opacity(0.45) : AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .alert("Directions Unavailable", isPresented: directionsAlertBinding) {
            Button("OK", role: .cancel) {
                directionsMessage = nil
            }
        } message: {
            Text(directionsMessage ?? "")
        }
    }

    private var locationLine: String {
        let cityState = [station.city, station.state]
            .filter { $0.isEmpty == false }
            .joined(separator: ", ")

        return [station.address, cityState, station.zipCode]
            .filter { $0.isEmpty == false }
            .joined(separator: " • ")
    }

    /// 2.3.2 — the full postal address used for Share, in the plain-text/comma-separated form
    /// meant to be copied elsewhere — deliberately NOT locationLine above, which is this same
    /// data in the on-screen bullet ("•") style meant to be read, not pasted into a navigation
    /// app. 2.3.2 gate fix — prefers `shareAddressOverride` (a merged item's fuller,
    /// per-field-resolved address) when one was supplied; falls back to deriving the address
    /// purely from `station` (the saved record) when it's nil, exactly as before this fix — the
    /// correct, and only possible, behavior for a true saved-only station.
    private var shareAddress: String {
        shareAddressOverride ?? StationShareContent.fullAddress(street: station.address, city: station.city, state: station.state, zip: station.zipCode)
    }

    private var daysSincePriceUpdate: Int {
        StationDataValidation.daysSince(station.lastUpdated)
    }

    private var priceFreshnessText: String {
        if Calendar.current.isDateInToday(station.lastUpdated) {
            return "Updated today"
        }

        let days = max(daysSincePriceUpdate, 0)
        let baseText = "Updated \(days) day\(days == 1 ? "" : "s") ago"
        return days > 14 ? "\(baseText) • Price may be stale" : baseText
    }

    private var priceStatusText: String {
        station.lastKnownE85Price > 0 ? "Local E85 price available" : "No E85 price saved yet"
    }

    private var priceStale: Bool {
        station.lastKnownE85Price > 0 && daysSincePriceUpdate > 14
    }

    private var priceStatusColor: Color {
        priceStale ? AppTheme.Colors.stationYellow : (station.lastKnownE85Price > 0 ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textMuted)
    }

    private var priceFreshnessBadgeLabel: String {
        guard station.lastKnownE85Price > 0 else { return "No Price" }

        if daysSincePriceUpdate <= 7 {
            return "Fresh"
        }

        if daysSincePriceUpdate <= 14 {
            return "Check Price"
        }

        return "Stale"
    }

    private var priceFreshnessBadgeColor: Color {
        guard station.lastKnownE85Price > 0 else { return AppTheme.Colors.textMuted }

        if daysSincePriceUpdate <= 7 {
            return AppTheme.Colors.primaryGreen
        }

        if daysSincePriceUpdate <= 14 {
            return AppTheme.Colors.stationYellow
        }

        return AppTheme.Colors.warningRed
    }

    private var priceFreshnessBadge: some View {
        Text(priceFreshnessBadgeLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.Colors.charcoal)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(priceFreshnessBadgeColor)
            .clipShape(Capsule())
    }

    private var directionsAlertBinding: Binding<Bool> {
        Binding(
            get: { directionsMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    directionsMessage = nil
                }
            }
        )
    }

    @ViewBuilder
    private var communityPricePreview: some View {
        if let communitySummary,
           let latestPrice = communitySummary.latestPrice,
           let latestReportedAt = communitySummary.latestReportedAt {
            VStack(alignment: .leading, spacing: 4) {
                Text("Community E85")
                    .font(.caption2.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(AppTheme.Colors.stationYellow)

                HStack(spacing: 8) {
                    Text("\(latestPrice.communityPriceText)/gal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)

                    Text(latestReportedAt.communityReportedText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }

                if latestReportedAt.communityPriceIsStale {
                    Text("Community price may be stale")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                }
            }
            .padding(.top, 2)
        } else if station.lastKnownE85Price <= 0 {
            Text("No community price yet")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textMuted)
                .padding(.top, 2)
        }
    }
}

private struct SavedStationMapItem: Identifiable, Equatable {
    let id: PersistentIdentifier
    let name: String
    let coordinate: CLLocationCoordinate2D
    let lastKnownE85Price: Double
    let lastUpdated: Date

    static func == (lhs: SavedStationMapItem, rhs: SavedStationMapItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.lastKnownE85Price == rhs.lastKnownE85Price &&
        lhs.lastUpdated == rhs.lastUpdated
    }
}

private struct StationMapPin: View {
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.cardBackground)
                    .frame(width: isSelected ? 34 : 30, height: isSelected ? 34 : 30)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.borderColor, lineWidth: 1.5)
                    )

                Image(systemName: "fuelpump.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? AppTheme.Colors.charcoal : AppTheme.Colors.primaryGreen)
            }

            Triangle()
                .fill(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.cardBackground)
                .frame(width: 12, height: 8)
                .overlay(
                    Triangle()
                        .stroke(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.borderColor, lineWidth: 1)
                )
                .offset(y: -1)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 10, y: 6)
        .scaleEffect(isSelected ? 1.06 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isSelected)
    }
}

private struct LiveStationMapPin: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.stationYellow)
                    .frame(width: 28, height: 28)

                Image(systemName: "fuelpump.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.charcoal)
            }

            Triangle()
                .fill(AppTheme.Colors.stationYellow)
                .frame(width: 10, height: 7)
                .offset(y: -1)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 8, y: 4)
    }
}

private struct LiveStationRowCard: View {
    let station: LiveFuelStation
    let isSaved: Bool
    let communitySummary: CommunityPriceSummary?
    let directionsAction: () -> String?
    let reportPriceAction: () -> Void
    let saveAction: () -> Void
    @State private var directionsMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.Colors.stationYellow.opacity(0.15))

                    Image(systemName: "fuelpump.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text(locationLine)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Spacer()

                if station.distanceMiles > 0 {
                    Text(String(format: "%.1f mi", station.distanceMiles))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppTheme.Colors.primaryGreen.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            if station.accessHours.isEmpty == false {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                    Text(station.accessHours)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .lineLimit(2)
                }
            }

            communityPricePreview

            HStack(spacing: 8) {
                stationActionButton(
                    title: "Directions",
                    systemImage: "location.fill",
                    foreground: AppTheme.Colors.textPrimary,
                    background: AppTheme.Colors.cardBackground,
                    borderColor: AppTheme.Colors.borderColor,
                    action: { directionsMessage = directionsAction() }
                )
                .accessibilityLabel("Get directions to \(station.name)")

                stationActionButton(
                    title: "Report Price",
                    systemImage: "tag.fill",
                    foreground: AppTheme.Colors.charcoal,
                    background: AppTheme.Colors.stationYellow,
                    borderColor: nil,
                    action: reportPriceAction
                )
                .accessibilityLabel("Report E85 price for \(station.name)")

                // PR D — unified Favorite wording/icon (saves + favorites in one tap). The
                // disabled "Saved" state for an already-merged station shown under the Nearby
                // filter (isSaved: true, saveAction: {}) is left as informational status copy
                // only — see section 30 — not a competing action.
                stationActionButton(
                    title: isSaved ? "Saved" : "Favorite",
                    systemImage: isSaved ? "checkmark.circle.fill" : "star",
                    foreground: isSaved ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary,
                    background: isSaved ? AppTheme.Colors.cardBackground : AppTheme.Colors.primaryGreen.opacity(0.20),
                    borderColor: isSaved ? AppTheme.Colors.borderColor : AppTheme.Colors.primaryGreen,
                    action: saveAction
                )
                .disabled(isSaved)
                .accessibilityLabel(isSaved ? "\(station.name) already saved" : "Favorite \(station.name)")
            }

            // 2.3.2 — Share as a compact secondary utility row rather than a fourth full-width
            // action (section 16): the three primary actions above stay exactly as wide/as they
            // were. Available to every user (Free and Pro), regardless of isSaved/price/
            // Favorite — never gated. Self-contained — builds its payload directly from
            // `station` (already in hand), so no new required initializer parameter was needed.
            // Native ShareLink only; no action closure exists to call, so this cannot mutate
            // Favorite/Saved/price/selection/SwiftData or start any network call — dismissing
            // the sheet leaves this card exactly as it was.
            HStack {
                ShareLink(item: StationShareContent.text(name: station.name, address: shareAddress)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityLabel("Share \(station.name)")

                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.stationYellow.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .alert("Directions Unavailable", isPresented: directionsAlertBinding) {
            Button("OK", role: .cancel) {
                directionsMessage = nil
            }
        } message: {
            Text(directionsMessage ?? "")
        }
    }

    // Compact card-action button — 2.3.0 UI polish pass: the three actions below previously
    // read as three full-size primary CTAs competing with the station info above them. Same
    // behavior/labels/colors, just sized and spaced like card actions rather than pills:
    // explicit 44pt minimum tap height, a smaller explicit icon size, tighter padding, and no
    // lineLimit/truncation on the label — at large Dynamic Type or narrow widths, the label
    // wraps to a second line instead of clipping "Report Price"/"Save Station" into ambiguity.
    private func stationActionButton(
        title: String,
        systemImage: String,
        foreground: Color,
        background: Color,
        borderColor: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .background(background)
            .overlay {
                if let borderColor {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var locationLine: String {
        let cityState = [station.city, station.state]
            .filter { $0.isEmpty == false }
            .joined(separator: ", ")

        return [station.address, cityState, station.zip]
            .filter { $0.isEmpty == false }
            .joined(separator: " • ")
    }

    /// 2.3.2 — the full postal address used for Share, in the plain-text/comma-separated form
    /// meant to be copied elsewhere — deliberately NOT locationLine above, which is this same
    /// data in the on-screen bullet ("•") style meant to be read, not pasted into a navigation
    /// app.
    private var shareAddress: String {
        StationShareContent.fullAddress(street: station.address, city: station.city, state: station.state, zip: station.zip)
    }

    private var directionsAlertBinding: Binding<Bool> {
        Binding(
            get: { directionsMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    directionsMessage = nil
                }
            }
        )
    }

    @ViewBuilder
    private var communityPricePreview: some View {
        if let communitySummary,
           let latestPrice = communitySummary.latestPrice,
           let latestReportedAt = communitySummary.latestReportedAt {
            VStack(alignment: .leading, spacing: 4) {
                Text("Community E85")
                    .font(.caption2.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(AppTheme.Colors.stationYellow)

                HStack(spacing: 8) {
                    Text("\(latestPrice.communityPriceText)/gal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)

                    Text(latestReportedAt.communityReportedText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }

                if latestReportedAt.communityPriceIsStale {
                    Text("Community price may be stale")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                }
            }
        } else {
            Text("No community price yet")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }
}

private struct StationPriceUpdateContext: Identifiable {
    let id = UUID()
    let station: FuelStation?
    let stationName: String
    let address: String
    let city: String
    let state: String
    let zipCode: String
    let latitude: Double?
    let longitude: Double?

    static func saved(_ station: FuelStation) -> StationPriceUpdateContext {
        StationPriceUpdateContext(
            station: station,
            stationName: station.name,
            address: station.address,
            city: station.city,
            state: station.state,
            zipCode: station.zipCode,
            latitude: station.latitude,
            longitude: station.longitude
        )
    }

    static func live(_ station: LiveFuelStation) -> StationPriceUpdateContext {
        StationPriceUpdateContext(
            station: nil,
            stationName: station.name,
            address: station.address,
            city: station.city,
            state: station.state,
            zipCode: station.zip,
            latitude: station.latitude == 0 ? nil : station.latitude,
            longitude: station.longitude == 0 ? nil : station.longitude
        )
    }

    /// Whether this station carries enough identifying information to safely report an E85
    /// price to the community feed. A DATA-sufficiency check, not a provenance check — a saved
    /// station is exactly as reportable as a freshly-discovered one whenever it can be
    /// identified, matching the same rule that already determines whether this station can
    /// display an existing community price. See `CommunityPriceEligibility`.
    var canReportToCommunity: Bool {
        CommunityPriceEligibility.canReport(
            name: stationName,
            streetAddress: address,
            city: city,
            state: state,
            zip: zipCode,
            latitude: latitude,
            longitude: longitude
        )
    }

    var optionalAddress: String? {
        address.isEmpty ? nil : address
    }

    var optionalCity: String? {
        city.isEmpty ? nil : city
    }

    var optionalState: String? {
        state.isEmpty ? nil : state
    }

    var optionalZipCode: String? {
        zipCode.isEmpty ? nil : zipCode
    }
}

private struct StationPriceUpdateSheet: View {
    let context: StationPriceUpdateContext
    @Binding var priceInput: String
    @Binding var noteInput: String
    @Binding var validationMessage: String?
    let isSubmittingCommunityPrice: Bool
    let saveLocalAction: () -> Void
    let saveAndReportAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.stationName.isEmpty ? "Station" : context.stationName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text("Save a local user-reported E85 price preview for this station, or report it to the community price feed.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("E85 Price")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary)

                            TextField("E85 Price", text: $priceInput)
                                .keyboardType(.decimalPad)
                                .font(.headline)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(AppTheme.Colors.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(validationMessage == nil ? AppTheme.Colors.border : AppTheme.Colors.warningRed, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Note")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary)

                            TextField("Optional local note", text: $noteInput, axis: .vertical)
                                .lineLimit(2...4)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(AppTheme.Colors.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        if let validationMessage {
                            Text(validationMessage)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color(red: 0.98, green: 0.54, blue: 0.54))
                        }

                        VStack(spacing: 10) {
                            Button(action: saveLocalAction) {
                                Text("Save Locally")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(AppTheme.Colors.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(isSubmittingCommunityPrice)

                            if context.canReportToCommunity {
                                Button(action: saveAndReportAction) {
                                    HStack(spacing: 8) {
                                        if isSubmittingCommunityPrice {
                                            ProgressView()
                                                .tint(AppTheme.Colors.textPrimary)
                                        }
                                        Text(isSubmittingCommunityPrice ? "Reporting…" : "Save & Report")
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(AppTheme.Colors.primaryGreen)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(isSubmittingCommunityPrice)
                            } else {
                                Text("This station doesn't have enough location information for community reporting yet.")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.Colors.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationTitle("Update Price")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancelAction)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .disabled(isSubmittingCommunityPrice)
                }
            }
        }
        .keyboardDoneToolbar()
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private extension Double {
    var currencyText: String {
        String(format: "$%.2f", self)
    }

    var communityPriceText: String {
        String(format: "$%.2f", self)
    }
}

private extension Date {
    var communityReportedText: String {
        if Calendar.current.isDateInToday(self) {
            return "Reported today"
        }

        if Calendar.current.isDateInYesterday(self) {
            return "Reported yesterday"
        }

        let days = StationDataValidation.daysSince(self)
        return "Reported \(days) day\(days == 1 ? "" : "s") ago"
    }

    var communityPriceIsStale: Bool {
        StationDataValidation.isStale(daysSince: StationDataValidation.daysSince(self))
    }
}
