//
//  SimpleProStationsMapView.swift
//  EightyFiveBlends
//
//  PR B — "85Blends 2.3.2 — Simple Mode + Pro Premium Stations Map." A map-first premium
//  presentation for the Stations tab, shown ONLY when appExperienceMode == .simple AND
//  SubscriptionManager.shared.isProUser (see StationsView.usesPremiumSimpleStationsPresentation).
//  Simple Free, Normal Free, and Normal Pro are all unaffected — they keep the existing
//  list-first StationsView content exactly as it was before this file existed.
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
/// existing StationDisplayItem.Content cases, never a second station model.
enum SimpleProStationKind {
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
struct SimpleProStationMapItem: Identifiable {
    let selection: PremiumStationMapSelection
    var id: PremiumStationMapSelection { selection }
    let displayName: String
    let coordinate: CLLocationCoordinate2D
    let displayAddress: String
    let distanceMiles: Double?
    let price: PremiumStationPricePresentation
    let isSaved: Bool
    let isFavorite: Bool
    let kind: SimpleProStationKind
    let accessibilityDescription: String
}

// MARK: - Pin

/// A new pin type for the premium map — independent of the existing StationMapPin /
/// LiveStationMapPin, which stay completely untouched (they still back the old embedded map for
/// Simple Free / Normal Free / Normal Pro).
struct SimpleProStationMapPin: View {
    let kind: SimpleProStationKind
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

struct SimpleProStationsMapView: View {
    // Derived display data (StationsView owns the real state; this is a read-only snapshot).
    let items: [SimpleProStationMapItem]
    let isSearchingLive: Bool
    let liveSearchError: String?
    let isTypedLocationSearch: Bool
    let typedLocationDisplayName: String?
    let radiusOptions: [String]

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
    let onShowAll: () -> Void
    let onRefresh: () -> Void
    let onDirections: (PremiumStationMapSelection) -> String?
    let onSave: (PremiumStationMapSelection) -> Void
    let onFavorite: (PremiumStationMapSelection) -> Void
    let onReportPrice: (PremiumStationMapSelection) -> Void

    @State private var selectedStationID: PremiumStationMapSelection?
    @State private var directionsErrorMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFieldFocused: Bool

    /// Resolves the current selection against the CURRENT items list on every access — so a
    /// station that disappears after a refresh naturally closes the card (nil), and a live-only
    /// selection that becomes merged after Save (PR B section 40/42) naturally migrates to the
    /// merged item sharing the same live key, rather than needing a separate invalidation pass.
    private var selectedItem: SimpleProStationMapItem? {
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

            if let selectedItem {
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
            ForEach(items) { item in
                Annotation(item.displayName, coordinate: item.coordinate, anchor: .bottom) {
                    Button {
                        AppHaptics.selection()
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedStationID = (selectedItem?.id == item.selection) ? nil : item.selection
                        }
                    } label: {
                        SimpleProStationMapPin(
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
            if isSearchingLive {
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
                    Image(systemName: isSearchingLive ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(isSearchingLive)
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
            mapControlButton(systemImage: "map", label: "Show all stations", action: onShowAll)
        }
        .padding(.trailing, 12)
        .padding(.top, 8)
    }

    private func mapControlButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Selected station card

    @ViewBuilder
    private func selectedStationCard(_ item: SimpleProStationMapItem) -> some View {
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

            Divider().overlay(AppTheme.Colors.borderColor)

            HStack(spacing: 10) {
                actionButton(title: "Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill", stationName: item.displayName) {
                    if let message = onDirections(item.selection) {
                        directionsErrorMessage = message
                    }
                }
                if item.kind == .liveOnly {
                    actionButton(title: "Save", systemImage: "bookmark", stationName: item.displayName) {
                        onSave(item.selection)
                    }
                } else {
                    actionButton(title: item.isFavorite ? "Favorited" : "Favorite", systemImage: item.isFavorite ? "star.fill" : "star", stationName: item.displayName) {
                        onFavorite(item.selection)
                    }
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
