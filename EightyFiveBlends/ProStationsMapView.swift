//
//  ProStationsMapView.swift
//  EightyFiveBlends
//
//  Originally PR B — "85Blends 2.3.2 — Simple Mode + Pro Premium Stations Map." Renamed and
//  regated in PR D ("Pro Stations Preference + Favorite/Save Unification + Natural Card
//  Paging") — this is a map-first premium presentation for the Stations tab, shown for a Pro
//  user whenever their stored Stations layout preference is .map (see
//  StationsView.usesPremiumStationsMapPresentation), in BOTH Simple and Normal app-experience
//  mode. It is no longer tied to Simple Mode. Any Free user, or a Pro user who chose Classic,
//  keeps the existing list-first StationsView content exactly as before.
//
//  This file is presentation-only. It owns local UI state (which pin is selected, a transient
//  directions-error alert) and nothing else — no NREL/Supabase/SwiftData calls, no cache/TTL
//  logic, no location authorization, no entitlement calculation, no ad logic. StationsView
//  remains the sole data owner/orchestrator: every item here is derived fresh from its
//  unifiedItems, and every action closure resolves back to StationsView's own existing
//  saveLiveStation/toggleFavorite/beginPriceUpdate/directionsMessage functions.
//

import SwiftUI
import MapKit
import SwiftData
import CoreLocation

// MARK: - Selection identity

/// Stable, durable identity for a station pin/card on the premium map. Deliberately NOT
/// LiveFuelStation.id (a fresh UUID regenerated on every NREL decode — see that type's own
/// header comment) so a selection survives a background refresh of the same physical station.
/// Saved identity reuses SwiftData's own PersistentIdentifier; live identity uses a canonical,
/// name/address/coordinate-derived key (see StationsView.canonicalLiveStationKey(for:)) that
/// stays the same across repeated fetches of the same physical station.
enum PremiumStationMapSelection: Hashable {
    case saved(PersistentIdentifier)
    case live(String)
    case merged(saved: PersistentIdentifier, liveKey: String)
}

/// Presentation-only classification driving pin styling and which actions apply — mirrors the
/// existing StationDisplayItem.Content cases, never a second station model. Explicit Equatable
/// conformance (final pre-merge gate finding) — a plain no-payload enum does NOT get `==`/`!=`
/// synthesized for free without stating the protocol, and this type is compared with both
/// operators below (ProStationMapPin's badge logic, selectedStationCard's action-matrix
/// branch) — a harmless, presentation-only conformance.
enum ProStationKind: Equatable {
    case savedOnly
    case liveOnly
    case merged
}

/// Already-resolved price copy for one station, matching the app's one existing price hierarchy
/// (a saved/local price is primary whenever it exists; community is primary only when no saved
/// price exists) — the premium view itself never re-derives this, it just renders it.
struct PremiumStationPricePresentation {
    let primaryText: String?
    let primarySource: String?
    let freshnessText: String?
    let supportingText: String?
    let hasNoPriceAtAll: Bool
}

/// One premium map pin/card's worth of display data — derived fresh from StationsView's own
/// unifiedItems every time that recomputes. Never persisted, never independently stored.
struct ProStationMapItem: Identifiable {
    let selection: PremiumStationMapSelection
    var id: PremiumStationMapSelection { selection }
    let displayName: String
    let coordinate: CLLocationCoordinate2D
    let displayAddress: String
    let distanceMiles: Double?
    let price: PremiumStationPricePresentation
    let isSaved: Bool
    let isFavorite: Bool
    let kind: ProStationKind
    let accessibilityDescription: String
}

// MARK: - Pin

/// A new pin type for the premium map — independent of the existing StationMapPin /
/// LiveStationMapPin, which stay completely untouched (they still back the old embedded map for
/// Simple Free / Normal Free / Normal Pro).
struct ProStationMapPin: View {
    let kind: ProStationKind
    let isFavorite: Bool
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fillColor: Color {
        switch kind {
        case .savedOnly, .merged: return AppTheme.Colors.primaryGreen
        case .liveOnly: return AppTheme.Colors.stationYellow
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
                .frame(width: isSelected ? 34 : 26, height: isSelected ? 34 : 26)
                .overlay(
                    Circle().stroke(AppTheme.Colors.oledBackground, lineWidth: isSelected ? 3 : 2)
                )
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)

            Image(systemName: "fuelpump.fill")
                .font(.system(size: isSelected ? 14 : 11, weight: .bold))
                .foregroundStyle(.white)

            // Non-color kind differentiation (adversarial audit finding AK) — fill color alone
            // (green vs. yellow) was the only cue distinguishing a saved-but-unfavorited pin
            // from a live-only pin. A favorite always gets the star; a saved/merged station
            // that isn't favorited gets a distinct bookmark badge instead; live-only gets
            // neither, so all three kinds now have a shape/icon cue independent of color.
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .padding(2)
                    .background(Circle().fill(AppTheme.Colors.oledBackground))
                    .offset(x: 12, y: -12)
            } else if kind != .liveOnly {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(2)
                    .background(Circle().fill(AppTheme.Colors.oledBackground))
                    .offset(x: 12, y: -12)
            }
        }
        // 44x44pt minimum tap target regardless of the smaller visual pin — see PR B's
        // accessibility hit-target requirement.
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.65), value: isSelected)
    }
}

// MARK: - Main premium view

struct ProStationsMapView: View {
    // Derived display data (StationsView owns the real state; this is a read-only snapshot).
    let items: [ProStationMapItem]
    /// Station discovery is "in progress" whenever a network fetch is running OR a pending
    /// nearby-search is still waiting on a location fix
    /// (StationsView.isPremiumStationsLoading = isSearchingLive || pendingLiveSearchReason !=
    /// nil). Deliberately a single combined signal rather than exposing isSearchingLive AND a
    /// second Boolean: nothing in this premium view needs to distinguish "waiting for GPS" from
    /// "waiting for the network," and this file's own copy ("Searching for nearby E85…",
    /// "Updating stations…") never claims otherwise. PendingLiveSearchReason itself is never
    /// exposed here — only "is something happening," never why.
    let isLoadingStations: Bool
    let liveSearchError: String?
    let isTypedLocationSearch: Bool
    let typedLocationDisplayName: String?
    let radiusOptions: [String]
    /// Whether to draw the user's current-location marker (UserAnnotation) on the map. Plumbed
    /// in as a plain Bool — never StationLocationManager itself — so this presentation-only view
    /// stays fully independent of location authorization/lifecycle; StationsView computes it the
    /// same way the existing embedded map does (locationManager.isAuthorizedForUserLocation).
    let showsUserLocation: Bool

    // Shared state — same source of truth as the existing embedded map/search, never a second
    // independent copy (see PR B section 45/69/70).
    @Binding var mapPosition: MapCameraPosition
    @Binding var selectedRadius: String
    @Binding var locationSearchText: String
    let isGeocodingLocation: Bool
    let locationSearchValidationMessage: String?

    // Actions — every one of these resolves back into an existing StationsView function; this
    // view never calls NREL/Supabase/SwiftData/CoreLocation authorization itself.
    let onSubmitLocationSearch: () -> Void
    let onClearLocationSearch: () -> Void
    let onRecenterUser: () -> Void
    let onRefresh: () -> Void
    let onDirections: (PremiumStationMapSelection) -> String?
    // PR D — Save is gone as a separate action; Favorite now covers every kind (live-only
    // saves+favorites atomically, saved/merged toggles) — see the action row below and
    // StationsView.premiumFavorite(for:).
    let onFavorite: (PremiumStationMapSelection) -> Void
    let onReportPrice: (PremiumStationMapSelection) -> Void
    // Follow-on polish — additive convenience access to the existing Trip Planner experience
    // while using the premium map. This view never presents Trip Planner itself (it has no
    // NavigationLink/sheet/destination of its own) — it only signals intent; StationsView owns
    // the actual navigation trigger, same as every other action above.
    let onOpenTripPlanner: () -> Void

    @State private var selectedStationID: PremiumStationMapSelection?
    @State private var directionsErrorMessage: String?
    /// PR C — Favorites floating panel presentation. Local, transient, never persisted (see
    /// section 26). Favorites content itself is never a second data model — see favoriteItems
    /// below, which derives from `items` on every access, same as everything else in this view.
    @State private var isFavoritesPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFieldFocused: Bool

    /// Resolves the current selection against the CURRENT items list on every access — so a
    /// station that disappears after a refresh naturally closes the card (nil), and a live-only
    /// selection that becomes merged after Save (PR B section 40/42) naturally migrates to the
    /// merged item sharing the same live key, rather than needing a separate invalidation pass.
    private var selectedItem: ProStationMapItem? {
        guard let selectedStationID else { return nil }
        if let exact = items.first(where: { $0.selection == selectedStationID }) {
            return exact
        }
        if case .live(let key) = selectedStationID {
            return items.first {
                if case .merged(_, let liveKey) = $0.selection { return liveKey == key }
                return false
            }
        }
        return nil
    }

    /// PR C — favorite stations, derived fresh from `items` on every access (section 27): no
    /// secondary @State array, no reload button. Only a saved/merged item can ever be favorite
    /// (favoriteItems inherits this from item.isFavorite, which itself only ever reflects a
    /// saved FuelStation's isFavorite — see StationsView.premiumStationMapItems).
    private var favoriteItems: [ProStationMapItem] {
        items.filter(\.isFavorite)
    }

    /// PR C — deterministic browse order for swipe/accessibility station stepping (section 29):
    /// known-distance items first (nearest to farthest), then nil-distance items, tie-broken by
    /// case-insensitive display name, then (final pre-merge gate fix, section 22) a stable
    /// per-selection string key as the last resort. Never array/hash/UUID/SwiftData internal
    /// order.
    private var browsableItems: [ProStationMapItem] {
        items.sorted { lhs, rhs in
            if let orderedByDistance = distanceOrdering(lhs, rhs) { return orderedByDistance }
            let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            // Two DIFFERENT physical stations sharing both an identical distance and an
            // identical case-insensitive display name is an extreme edge case, but
            // Array.sorted's behavior for a comparator that returns false in both directions
            // for a given pair is otherwise unspecified across repeated calls - this final,
            // stable tie-break (never hashValue/UUID/memory identity, just each selection's own
            // deterministic string form) guarantees browsableItems is the exact same order
            // every time it's recomputed for the same underlying stations.
            return stableTieBreakKey(lhs.selection) < stableTieBreakKey(rhs.selection)
        }
    }

    /// Returns a definitive "lhs belongs before rhs" answer when distance alone decides it (one
    /// or both known and unequal), or nil when distance is a tie (both nil, or both equal) and
    /// the caller should fall through to the name/stable-key tie-break.
    private func distanceOrdering(_ lhs: ProStationMapItem, _ rhs: ProStationMapItem) -> Bool? {
        switch (lhs.distanceMiles, rhs.distanceMiles) {
        case let (leftDistance?, rightDistance?):
            return leftDistance == rightDistance ? nil : leftDistance < rightDistance
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return nil
        }
    }

    private func stableTieBreakKey(_ selection: PremiumStationMapSelection) -> String {
        switch selection {
        case .saved(let id):
            return "saved|" + String(describing: id)
        case .live(let key):
            return "live|" + key
        case .merged(let id, let key):
            return "merged|" + String(describing: id) + "|" + key
        }
    }

    /// The selected item's position in browsableItems, or nil if nothing is selected/resolvable.
    private var currentBrowseIndex: Int? {
        guard let selectedItem else { return nil }
        return browsableItems.firstIndex(where: { $0.selection == selectedItem.selection })
    }

    /// PR C — centralized index stepping for both swipe and the accessibility Next/Previous
    /// actions (section 38), so the two can never disagree about wraparound math. Continuous
    /// wraparound (section 30); a single station (or none) is a safe no-op — `count > 1` is
    /// proven before any modulo (section 59/31), so there is no divide-by-zero or
    /// integer-underflow risk. Never fires network/geocoding — a pure selection change plus a
    /// haptic and (follow-on polish) a camera move.
    ///
    /// Follow-on polish — swiping/stepping now also moves the map camera to the newly-selected
    /// station via followMapToStation(_:), so the background map never feels disconnected from
    /// the floating card. This is the SOLE choke point for both swipe (swipeGesture) and both
    /// VoiceOver Next/Previous accessibility actions, so neither path can ever disagree about
    /// whether the camera follows. No other selection path (pin tap, Favorites-panel selection,
    /// a Save/Favorite live->merged migration, or a background refresh) calls this function, so
    /// none of those are affected — matching the "only deliberate swipe/step selection changes
    /// should move the map" requirement and avoiding any repeat of the earlier "favorite toggle
    /// recenters unexpectedly" regression (StationsView's unrelated .onChange(of:
    /// mappableStations) guard).
    private func stepStation(by delta: Int) {
        let order = browsableItems
        guard order.count > 1, let currentIndex = currentBrowseIndex else { return }
        let count = order.count
        let newIndex = ((currentIndex + delta) % count + count) % count
        let newItem = order[newIndex]
        AppHaptics.selection()
        selectedStationID = newItem.selection
        followMapToStation(newItem)
    }

    /// Follow-on polish — a pure camera move to the given station: no search, no location
    /// request, no radius change, no cache mutation. Reuses the exact fixed fallback span
    /// (0.08°/0.08°) already used by selectFavorite(_:)/fitAllStations() for a single station,
    /// but prefers the map's OWN current span when it's available (a prior selection/recenter/
    /// user pinch-zoom already leaves MapCameraPosition able to report one) so stepping between
    /// stations approximately preserves the user's own zoom level instead of always resetting
    /// to the fixed default.
    private func followMapToStation(_ item: ProStationMapItem) {
        let span = currentRegionSpan ?? Self.defaultSelectionSpan
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            mapPosition = .region(MKCoordinateRegion(center: biasedUpward(item.coordinate, span: span), span: span))
        }
    }

    /// Final pre-merge gate compiler-risk fix — MapCameraPosition is not a pattern-matchable
    /// enum (`.region(_:)` is a static factory method, not a case), so it must be read back
    /// through its own supported `region: MKCoordinateRegion?` property rather than
    /// `if case .region(let region) = mapPosition`. If MapCameraPosition can currently provide a
    /// region, reuse its span; otherwise fall back to the caller's own standard selection span.
    private var currentRegionSpan: MKCoordinateSpan? {
        mapPosition.region?.span
    }

    /// Same fixed span already used by selectFavorite(_:)/fitAllStations()'s single-station
    /// case — the safe, consistent fallback when the current span can't be read back.
    private static let defaultSelectionSpan = MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)

    /// Shifts the camera center slightly south (never touching displayed coordinates/pins
    /// themselves) so the selected station renders a bit above the map's vertical midpoint,
    /// reducing visual crowding from the bottom floating card. A small, fixed fraction of the
    /// current span — no screen-space geometry, no new architecture.
    private func biasedUpward(_ coordinate: CLLocationCoordinate2D, span: MKCoordinateSpan) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: coordinate.latitude - span.latitudeDelta * 0.15,
            longitude: coordinate.longitude
        )
    }

    private func selectNextStation() {
        stepStation(by: 1)
    }

    private func selectPreviousStation() {
        stepStation(by: -1)
    }

    /// PR D — explicit post-TestFlight product correction: swipe LEFT (negative horizontal
    /// translation) = NEXT, swipe RIGHT (positive) = PREVIOUS — the conventional/natural paging
    /// direction, replacing PR C's deliberately-reversed mapping. Only the physical
    /// direction-to-function mapping changes here; browse order, wraparound, the 60pt/1.25x
    /// threshold, and the VoiceOver "Next Station"/"Previous Station" action names are all
    /// unchanged (they still call selectNextStation()/selectPreviousStation() respectively,
    /// regardless of which swipe direction triggers them). Requires a real, mostly-horizontal
    /// gesture (60pt minimum, and horizontal motion at least 1.25x vertical) so button taps,
    /// small hand movement, and vertical scroll noise can never be misread as a swipe.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) >= 60, abs(horizontal) > abs(vertical) * 1.25 else { return }
                if horizontal < 0 {
                    selectNextStation()
                } else {
                    selectPreviousStation()
                }
            }
    }

    /// PR C — opens/closes the Favorites panel with immediate haptic feedback (section 18/47).
    /// Opening clears any open station card (section 26 — only one bottom floating surface at a
    /// time); closing leaves selection alone since selecting a favorite (selectFavorite(_:))
    /// already closes the panel itself.
    private func toggleFavoritesPanel() {
        AppHaptics.selection()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            if isFavoritesPresented {
                isFavoritesPresented = false
            } else {
                selectedStationID = nil
                isFavoritesPresented = true
            }
        }
    }

    /// PR C — selecting a favorite (section 24-25): closes the panel, selects the station,
    /// highlights its pin (via the existing selectedItem-driven isSelected computation), and
    /// centers the map with the same moderate span used elsewhere in this file — no NLR search,
    /// no geocoder, no location request, purely presentation.
    private func selectFavorite(_ item: ProStationMapItem) {
        AppHaptics.selection()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            isFavoritesPresented = false
        }
        selectedStationID = item.selection
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            mapPosition = .region(MKCoordinateRegion(
                center: item.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            ))
        }
    }

    /// PR C — premium-only "fit all stations" (section 15-16), replacing the Show All button's
    /// old reuse of the legacy recenterMap(). Computes directly from `items` (already owned by
    /// this view) in O(n), avoiding recenterMap()'s legacy-only side effect (mutating
    /// selectedMapStationID, a concept this view has no use for) and its redundant
    /// recomputation of mappableStations/liveMapStations from scratch. Mirrors recenterMap()'s
    /// own padding formula (35% of span, floored at 0.05°) for a consistent feel. Presentation
    /// only: no network, no selection change, no saved-data mutation, no search-source change.
    /// recenterMap() itself is untouched and still backs the old embedded map's own Show All.
    private func fitAllStations() {
        AppHaptics.selection()
        let coordinates = items.map(\.coordinate)
        guard coordinates.isEmpty == false else { return }

        if coordinates.count == 1 {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                mapPosition = .region(MKCoordinateRegion(
                    center: coordinates[0],
                    span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
                ))
            }
            return
        }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard
            let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
            let minLongitude = longitudes.min(), let maxLongitude = longitudes.max()
        else { return }

        let latitudePadding = max((maxLatitude - minLatitude) * 0.35, 0.05)
        let longitudePadding = max((maxLongitude - minLongitude) * 0.35, 0.05)

        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
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
    }

    var body: some View {
        ZStack {
            mapLayer

            VStack(spacing: 0) {
                headerBar
                Spacer()
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    mapControls
                }
            }

            // PR C section 26/45 — Favorites panel and the selected-station card are mutually
            // exclusive bottom floating surfaces; toggleFavoritesPanel()/selectFavorite(_:)
            // already keep the two @State values from both being "on" at once, but this gate
            // makes that guarantee structural rather than relying purely on call-site discipline.
            if isFavoritesPresented {
                VStack {
                    Spacer()
                    favoritesPanel
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else if let selectedItem {
                VStack {
                    Spacer()
                    selectedStationCard(selectedItem)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(AppTheme.Colors.oledBackground)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: selectedItem?.id)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isFavoritesPresented)
        // Final pre-merge gate fix (section 26/27) — if the selected station is no longer
        // resolvable AT ALL (selectedItem already tried both the exact match and the
        // live->merged migration fallback and found neither), clear selectedStationID so a
        // LATER, unrelated reappearance of the same physical station in a future refresh can't
        // silently pop its old card back up without a new user tap ("stale resurrection"). Keyed
        // on the stable PremiumStationMapSelection identities only (never the full,
        // coordinate-containing items), so this fires only when the actual set of stations
        // changes, not on every render. Because selectedItem's own existing fallback runs
        // first and this only clears when THAT already failed, a genuine live->merged
        // migration (section 27) is never disturbed - it resolves via the fallback and this
        // onChange sees selectedItem != nil, so it does nothing.
        .onChange(of: items.map(\.selection)) { _, _ in
            if selectedStationID != nil, selectedItem == nil {
                selectedStationID = nil
            }
        }
        .alert("Directions Unavailable", isPresented: Binding(
            get: { directionsErrorMessage != nil },
            set: { isPresented in if isPresented == false { directionsErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { directionsErrorMessage = nil }
        } message: {
            Text(directionsErrorMessage ?? "")
        }
    }

    // MARK: Map

    @ViewBuilder
    private var mapLayer: some View {
        Map(position: $mapPosition, interactionModes: .all) {
            if showsUserLocation {
                UserAnnotation()
            }

            ForEach(items) { item in
                Annotation(item.displayName, coordinate: item.coordinate, anchor: .bottom) {
                    Button {
                        AppHaptics.selection()
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
                            // A direct pin tap always means "show this station's card" — close
                            // Favorites if it happened to be open (section 26/45 mutual exclusion).
                            isFavoritesPresented = false
                            selectedStationID = (selectedItem?.id == item.selection) ? nil : item.selection
                        }
                    } label: {
                        ProStationMapPin(
                            kind: item.kind,
                            isFavorite: item.isFavorite,
                            isSelected: selectedItem?.id == item.selection
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.accessibilityDescription)
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
        .mapStyle(.standard)
        // Full-bleed map fill — everything else in this view (header, controls, card) is a
        // sibling in the outer ZStack WITHOUT its own ignoresSafeArea, so it stays correctly
        // inset above the tab bar/home indicator (see PR B section 79) with no hardcoded value.
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            if items.isEmpty {
                emptyOrLoadingOverlay
            }
        }
    }

    @ViewBuilder
    private var emptyOrLoadingOverlay: some View {
        VStack(spacing: 10) {
            // Final pre-merge gate fix (section 3/7) — this must show the Searching state
            // while a pending automatic/manual nearby search is still waiting on a location
            // fix, not only once the network fetch itself has started (isLoadingStations
            // covers both; the old isSearchingLive-only check left this false, and the "No E85
            // stations loaded yet." + Find Nearby button, misleadingly, while GPS was resolving).
            if isLoadingStations {
                ProgressView()
                Text("Searching for nearby E85…")
            } else {
                Image(systemName: "fuelpump")
                    .font(.system(size: 32))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                Text("No E85 stations loaded yet.")
                Button("Find Nearby E85", action: onRefresh)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.Colors.primaryGreen)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(AppTheme.Colors.textSecondary)
        .multilineTextAlignment(.center)
        .padding(20)
        // See headerBar's own comment on this same audit finding (AN).
        .background(AppTheme.Colors.elevatedCardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(40)
    }

    // MARK: Header / search / radius

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "fuelpump.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.Colors.primaryGreen)

                VStack(alignment: .leading, spacing: 1) {
                    Text("E85 Stations")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(isTypedLocationSearch ? "Live E85 near your search" : "Live E85 near you")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: onRefresh) {
                    Image(systemName: isLoadingStations ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                // Final pre-merge gate fix (section 9) — disabling on isLoadingStations (not
                // just isSearchingLive) prevents a repeated tap during the location-wait
                // sub-phase of a manual refresh from calling searchNearbyStations() again,
                // which would otherwise re-set pendingLiveSearchReason and call
                // locationManager.requestUserLocation() a second time — wasteful and can
                // restart/delay the in-flight one-shot fix rather than speed it up. This only
                // changes the PREMIUM refresh button's disabled state; searchNearbyStations()
                // and the legacy header refresh button are untouched.
                .disabled(isLoadingStations)
                .accessibilityLabel("Refresh nearby stations")
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppTheme.Colors.textMuted)
                    TextField("Search city, state, or ZIP", text: $locationSearchText)
                        .focused($isSearchFieldFocused)
                        .submitLabel(.search)
                        .onSubmit(onSubmitLocationSearch)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .disableAutocorrection(true)

                    if isGeocodingLocation {
                        ProgressView().controlSize(.small)
                    } else if locationSearchText.isEmpty == false {
                        Button {
                            locationSearchText = ""
                            isSearchFieldFocused = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppTheme.Colors.textMuted)
                        }
                        .accessibilityLabel("Clear search text")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppTheme.Colors.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                radiusMenu
            }

            if isTypedLocationSearch, let typedLocationDisplayName {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                    Text("Searching near \(typedLocationDisplayName)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Spacer()
                    Button("Clear", action: onClearLocationSearch)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                }
            }

            if let locationSearchValidationMessage {
                Text(locationSearchValidationMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.warningRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let liveSearchError {
                Text(liveSearchError)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // PR C section 9-10 — a warm refresh (existing pins already visible) previously
            // showed NO loading feedback at all in the premium map: emptyOrLoadingOverlay only
            // ever appears when items.isEmpty. This small, non-blocking pill fills that gap
            // without dimming/covering the map or introducing a second, competing loading
            // indicator - it disappears the instant loading ends since it reads
            // isLoadingStations directly (final pre-merge gate fix - this now also covers the
            // location-wait sub-phase of a pending nearby search, not just the network fetch
            // itself, per section 8: the same copy covers both without exposing which phase).
            if isLoadingStations, items.isEmpty == false {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating stations…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.Colors.cardBackground, in: Capsule())
            }
        }
        .padding(12)
        // Adversarial audit finding AN — secondary/muted text was sitting directly on bare
        // .ultraThinMaterial with no opaque token underneath, a light-mode contrast risk over a
        // bright standard-style map. Backed with the same AppTheme.Colors.elevatedCardBackground
        // token already used by the selected-station card below, matching this file's own
        // established pattern instead of a translucent system material.
        .background(AppTheme.Colors.elevatedCardBackground)
    }

    private var radiusMenu: some View {
        Menu {
            ForEach(radiusOptions, id: \.self) { option in
                Button {
                    selectedRadius = option
                } label: {
                    if option == selectedRadius {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedRadius)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppTheme.Colors.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityLabel("Search radius, currently \(selectedRadius)")
    }

    // MARK: Map controls

    private var mapControls: some View {
        VStack(spacing: 10) {
            mapControlButton(systemImage: "location.fill", label: "Center on my location", action: onRecenterUser)
            mapControlButton(systemImage: "map", label: "Show all stations", action: fitAllStations)
            mapControlButton(
                systemImage: "star.fill",
                label: "Favorite stations",
                badge: favoriteItems.count,
                action: toggleFavoritesPanel
            )
            // Follow-on polish — additive Trip Planner access while using the premium map.
            // "map.fill" matches the icon already used for Trip Planner everywhere else in the
            // app (StationsView.proFeaturesSection / MoreView.proPreviewSection's
            // ProFeatureGate), and reads as visually distinct from Show All's outline "map".
            mapControlButton(systemImage: "map.fill", label: "Trip Planner", action: onOpenTripPlanner)
        }
        .padding(.trailing, 12)
        .padding(.top, 8)
    }

    /// Map control button — 48x48 (up from the original 44x44 minimum, section 17) with an
    /// explicit .buttonStyle(.plain)/.contentShape(Circle()) so the full circle is reliably
    /// hit-testable above the Map underneath it, and an optional small count badge (section 20,
    /// used by the Favorites control; nil/0 renders no badge).
    private func mapControlButton(systemImage: String, label: String, badge: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())

                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(AppTheme.Colors.primaryGreen, in: Circle())
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(badgeAccessibilityLabel(label, badge: badge))
    }

    private func badgeAccessibilityLabel(_ label: String, badge: Int?) -> String {
        guard let badge, badge > 0 else { return label }
        return "\(label), \(badge) favorite\(badge == 1 ? "" : "s")"
    }

    // MARK: Favorites panel

    /// PR C — floating in-map Favorites panel (section 21-23): an overlay card, never a
    /// full-screen destination, never a new tab, never a modal navigation push. Content derives
    /// entirely from favoriteItems (section 27) — favoriting/unfavoriting elsewhere updates this
    /// list on the next render with no reload button.
    @ViewBuilder
    private var favoritesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Favorite Stations")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Spacer()
                Button {
                    toggleFavoritesPanel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
                .accessibilityLabel("Close favorites")
            }
            .padding(16)

            Divider().overlay(AppTheme.Colors.borderColor)

            if favoriteItems.isEmpty {
                // Final pre-merge gate finding (section 19) — a saved FuelStation's
                // latitude/longitude are optional, so a favorited station can exist without a
                // valid coordinate; premiumMapCoordinate(for:) already excludes such a station
                // from `items` entirely (it can never appear as a map annotation), which means
                // favoriteItems (filtered from `items`) can never include it either. Wording
                // deliberately says "on the map"/"mappable" rather than an unqualified "no
                // favorites at all" so this stays accurate whether the user truly has zero
                // favorites or has some that just aren't mappable — no new plumbing to
                // distinguish the two cases, per this being a wording fix, not a new feature.
                VStack(spacing: 4) {
                    Text("No mappable favorite stations yet.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("Favorite a saved station with a valid location to find it here.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                // Capped height (section 22) so a long favorites list scrolls internally
                // instead of consuming the whole screen.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(favoriteItems) { item in
                            Button {
                                selectFavorite(item)
                            } label: {
                                favoriteRow(item)
                            }
                            .buttonStyle(.plain)

                            if item.id != favoriteItems.last?.id {
                                Divider().overlay(AppTheme.Colors.borderColor).padding(.leading, 16)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .background(AppTheme.Colors.elevatedCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.Colors.borderColor, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private func favoriteRow(_ item: ProStationMapItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "star.fill")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.stationYellow)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                if let distanceMiles = item.distanceMiles {
                    Text(String(format: "%.1f mi", distanceMiles))
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            Spacer()

            if let primaryText = item.price.primaryText {
                Text(primaryText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Selected station card

    @ViewBuilder
    private func selectedStationCard(_ item: ProStationMapItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // PR C section 28-34: swipe browsing lives ONLY on this details block, never on the
            // action-button row below — attaching a drag gesture to a parent containing the
            // Directions/Save/Favorite/Report buttons risked exactly the "buttons stop firing"
            // failure mode section 32 explicitly forbids keeping; this block and the button row
            // are disjoint siblings, so the gesture can never intercept a button tap.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        if item.displayAddress.isEmpty == false {
                            Text(item.displayAddress)
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                    Spacer()
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            selectedStationID = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                    }
                    .accessibilityLabel("Close station details")
                }

                HStack(spacing: 12) {
                    if let distanceMiles = item.distanceMiles {
                        Label(String(format: "%.1f mi", distanceMiles), systemImage: "location.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    if item.isSaved {
                        Label("Saved", systemImage: "bookmark.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.primaryGreen)
                    }
                    if item.isFavorite {
                        Label("Favorite", systemImage: "star.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.stationYellow)
                    }
                }
                .labelStyle(.titleAndIcon)

                priceSection(item.price)

                if browsableItems.count > 1 {
                    pageIndicator
                }
            }
            .contentShape(Rectangle())
            .gesture(swipeGesture)
            .accessibilityAction(named: Text("Next Station")) { selectNextStation() }
            .accessibilityAction(named: Text("Previous Station")) { selectPreviousStation() }

            Divider().overlay(AppTheme.Colors.borderColor)

            HStack(spacing: 10) {
                actionButton(title: "Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill", stationName: item.displayName) {
                    if let message = onDirections(item.selection) {
                        directionsErrorMessage = message
                    }
                }
                // PR D — Favorite is the single unified action for every kind: a live-only
                // station is saved AND favorited in one tap (see
                // StationsView.premiumFavorite(for:)); a saved/merged station simply toggles.
                actionButton(title: item.isFavorite ? "Favorited" : "Favorite", systemImage: item.isFavorite ? "star.fill" : "star", stationName: item.displayName) {
                    onFavorite(item.selection)
                }
                actionButton(title: item.isSaved ? "Update" : "Report", systemImage: "dollarsign.circle", stationName: item.displayName) {
                    onReportPrice(item.selection)
                }
            }
        }
        .padding(16)
        .background(AppTheme.Colors.elevatedCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.Colors.borderColor, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    /// PR C section 35-36 — a compact "N of M" indicator plus a subtle chevron affordance,
    /// teaching users the card can be browsed without adding large Previous/Next buttons.
    /// Omitted entirely when there's only one browsable station (guarded by the call site).
    @ViewBuilder
    private var pageIndicator: some View {
        if let index = currentBrowseIndex {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").accessibilityHidden(true)
                Text("\(index + 1) of \(browsableItems.count)")
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(AppTheme.Colors.textMuted)
        }
    }

    @ViewBuilder
    private func priceSection(_ price: PremiumStationPricePresentation) -> some View {
        if let primaryText = price.primaryText {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(primaryText)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                    if let primarySource = price.primarySource {
                        Text(primarySource)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.Colors.cardBackground, in: Capsule())
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                if let freshnessText = price.freshnessText {
                    Text(freshnessText)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
                if let supportingText = price.supportingText {
                    Text(supportingText)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
            }
        } else {
            // primaryText and hasNoPriceAtAll are always set together in
            // StationsView.premiumPricePresentation(for:) — this branch only ever runs when
            // hasNoPriceAtAll is true, so a single fixed string is correct here.
            Text("No E85 price yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    private func actionButton(title: String, systemImage: String, stationName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.body.weight(.semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(AppTheme.Colors.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .accessibilityLabel("\(title) for \(stationName)")
    }
}
