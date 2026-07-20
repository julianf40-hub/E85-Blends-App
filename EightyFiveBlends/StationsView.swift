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
    @Environment(StationLocationManager.self) private var locationManager
    @State private var locationDeniedAlert = false
    @State private var liveStations: [LiveFuelStation] = []
    @State private var isSearchingLive = false
    @State private var liveSearchError: String?
    @State private var pendingLiveSearch = false
    @State private var liveSearchTask: Task<Void, Never>?
    @State private var priceInput = ""
    @State private var priceNoteInput = ""
    @State private var priceValidationMessage: String?
    @State private var isSubmittingCommunityPrice = false
    @State private var communityPriceSummaries: [String: CommunityPriceSummary] = [:]
    @State private var communityPriceSyncMessage: String?
    @State private var communityPriceTask: Task<Void, Never>?

    // Trip-planner / typed-location search
    @State private var locationSearchText = ""
    @State private var locationSearchValidationMessage: String?
    @State private var isGeocodingLocation = false
    @State private var stationSearchSource: StationSearchSource = .currentLocation
    @FocusState private var isTripPlannerFieldFocused: Bool

    private let radiusOptions = ["10 mi", "25 mi", "50 mi", "100 mi"]

    private var appVersionString: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
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

    var body: some View {
        stationsContent
    }

    private var stationsContent: some View {
        NavigationStack {
            // GeometryReader pins the ScrollView and its content to the viewport
            // width and clips overflow so the entire page can never translate
            // horizontally — no two-finger / long-press drag can shift the screen.
            GeometryReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        headerSection
                        proFeaturesSection
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
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .background(AppTheme.Colors.charcoal)
            }
            .toolbar(.hidden, for: .navigationBar)
            .keyboardDoneToolbar()
            .dismissKeyboardOnTap()
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .onAppear {
            recenterMap()
            refreshCommunityPricePreviews()
        }
        .onDisappear {
            liveSearchTask?.cancel()
            communityPriceTask?.cancel()
            isSearchingLive = false
            pendingLiveSearch = false
        }
        .onChange(of: mappableStations) { _, _ in
            recenterMap()
        }
        .onChange(of: searchText) { _, _ in
            refreshCommunityPricePreviews()
        }
        .onChange(of: stationListFilter) { _, _ in
            refreshCommunityPricePreviews()
        }
        .onChange(of: locationManager.latestCoordinate) { _, coordinate in
            guard let coordinate else { return }
            centerMap(on: coordinate.clCoordinate)
            if pendingLiveSearch {
                fetchLiveStations(at: coordinate.clCoordinate)
            }
        }
        .onChange(of: locationManager.authorizationStatus) { _, status in
            handleAuthorizationStatusChange(status)
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
        .alert("Delete Station?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) {
                confirmDeletion()
            }
            Button("Cancel", role: .cancel) {
                stationPendingDeletion = nil
            }
        } message: {
            Text("This saved station will be removed from your local list.")
        }
        .alert("Location Access Denied", isPresented: $locationDeniedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Location access is turned off. Enable it in Settings → Privacy → Location Services to find E85 stations near you.")
        }
        .alert(infoAlertTitle, isPresented: infoAlertBinding) {
            Button("OK", role: .cancel) {
                infoMessage = nil
            }
        } message: {
            Text(infoMessage ?? "")
        }
    }

    // 85Blends Pro entry points. Free users see locked preview cards (tapping opens the
    // paywall); Pro users get the live feature shells. Basic station search, favorites, and
    // saved stations below remain fully free.
    private var proFeaturesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "85Blends Pro", subtitle: "Smarter planning and price tracking.")

            ProFeatureGate(
                icon: "map.fill",
                title: "Trip Planner",
                description: "Plan E85 routes with intelligent fuel stops and range estimates."
            ) {
                TripPlannerView()
            }

            ProFeatureGate(
                icon: "bell.badge.fill",
                title: "Station Price Alerts",
                description: "Get notified when E85 prices drop at your saved stations."
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

            if isSearchingLive {
                liveSearchLoadingCard
            } else if filteredUnifiedItems.isEmpty {
                emptyStateForCurrentFilter
            } else {
                ForEach(filteredUnifiedItems) { item in
                    unifiedStationCard(for: item)
                }
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
                deleteAction: { stationPendingDeletion = saved }
            )
        case .nearbyOnly(let live):
            LiveStationRowCard(
                station: live,
                isSaved: false,
                communitySummary: communitySummary(for: live),
                directionsAction: { directionsMessage(for: live) },
                reportPriceAction: { beginPriceUpdate(for: live) },
                saveAction: { saveLiveStation(live) }
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
                    deleteAction: { stationPendingDeletion = saved }
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
                    pendingLiveSearch = false
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
        liveStations = []
        liveSearchError = nil
        isSearchingLive = false
        pendingLiveSearch = false
        stationSearchSource = .currentLocation
        stationListFilter = .all
        AppHaptics.selection()
    }

    private func searchStationsNearTypedLocation() {
        let trimmed = locationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            locationSearchValidationMessage = "Enter a city, state, or ZIP code to search."
            return
        }

        locationSearchValidationMessage = nil
        isGeocodingLocation = true
        liveSearchError = nil
        AppHaptics.selection()

        Task { @MainActor in
            defer { isGeocodingLocation = false }
            do {
                let placemarks = try await CLGeocoder().geocodeAddressString(trimmed)
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
                fetchLiveStations(at: coordinate, limit: 50)
            } catch let clError as CLError {
                switch clError.code {
                case .geocodeFoundNoResult:
                    liveSearchError = "We couldn't find \"\(trimmed)\". Try a city, state, or ZIP code."
                case .network:
                    liveSearchError = "Location search failed. Check your connection and try again."
                default:
                    liveSearchError = "We couldn't find that location. Try a city, state, or ZIP code."
                }
            } catch {
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

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { stationPendingDeletion != nil },
            set: { isPresented in
                if isPresented == false {
                    stationPendingDeletion = nil
                }
            }
        )
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

    private var infoAlertTitle: String {
        infoMessage == thankYouCommunityReportMessage ? "Thank You! 🙌" : "Stations"
    }

    private var thankYouCommunityReportMessage: String {
        "Your E85 price report is live and helps other drivers in your area find the best price."
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
        } else if locationManager.authorizationDenied {
            pendingLiveSearch = false
            locationDeniedAlert = true
        } else {
            pendingLiveSearch = true
            locationManager.requestUserLocation()
        }
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

        pendingLiveSearch = false
        locationDeniedAlert = true

        if locationManager.latestCoordinate == nil, mappableStations.isEmpty, liveStations.isEmpty {
            mapPosition = .region(StationsView.neutralUSRegion)
        }
    }

    private func fetchLiveStations(at coordinate: CLLocationCoordinate2D, limit: Int = 20) {
        liveSearchTask?.cancel()

        guard isValidCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            liveStations = []
            liveSearchError = "Current location is unavailable. Try again in a moment."
            pendingLiveSearch = false
            isSearchingLive = false
            return
        }

        pendingLiveSearch = false
        isSearchingLive = true
        liveSearchError = nil

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
                if results.isEmpty {
                    liveSearchError = "No E85 stations found within \(selectedRadius) of \(stationSearchSource.displayName). Try selecting a larger radius above."
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
            isSearchingLive = false
            liveSearchTask = nil
        }
    }

    private func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude) && (latitude != 0 || longitude != 0)
    }

    private func saveLiveStation(_ station: LiveFuelStation) {
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
            longitude: station.longitude == 0 ? nil : station.longitude
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
        beginPriceUpdate(for: saved)
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
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func normalizedStationKey(for station: FuelStation) -> String? {
        normalizedStationKey(
            name: station.name,
            streetAddress: station.address,
            city: station.city,
            state: station.state,
            zip: station.zipCode
        )
    }

    private func normalizedStationKey(for station: LiveFuelStation) -> String? {
        normalizedStationKey(
            name: station.name,
            streetAddress: station.address,
            city: station.city,
            state: station.state,
            zip: station.zip
        )
    }

    private func normalizedStationKey(
        name: String,
        streetAddress: String,
        city: String,
        state: String,
        zip: String
    ) -> String? {
        let components = [
            normalizedStationText(name),
            normalizedStationText(streetAddress),
            normalizedStationText(city),
            normalizedStationText(state),
            normalizedStationText(zip)
        ]

        guard components.contains(where: { $0.isEmpty == false }) else {
            return nil
        }

        return components.joined(separator: "|")
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
        priceInput = station.lastKnownE85Price > 0 ? String(format: "%.2f", station.lastKnownE85Price) : ""
        priceNoteInput = station.notes
        priceValidationMessage = nil
        priceUpdateContext = .saved(station)
    }

    private func beginPriceUpdate(for station: LiveFuelStation) {
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
            AppHaptics.success()
        } catch {
            #if DEBUG
            print("[85Blends] StationsView: price update save failed:", error)
            #endif
            infoMessage = "Couldn't save changes. Please try again."
        }
        refreshCommunityPricePreviews()

        guard reportToCommunity, context.isLiveDiscovered else {
            if reportToCommunity {
                infoMessage = "Price saved locally. Community reporting is only available for stations found through nearby search."
            }
            dismissPriceUpdateSheet()
            return
        }

        isSubmittingCommunityPrice = true

        Task {
            let message: String

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
                message = thankYouCommunityReportMessage
            } catch {
#if DEBUG
                print("Community price report failed:", error)
#endif
                if let serviceError = error as? CommunityPriceServiceError,
                   case .notConfigured = serviceError {
                    message = "Price saved locally. Community reporting is not available right now."
                } else {
                    message = "Price saved locally. Community report could not be submitted — please try again later."
                }
            }

            await MainActor.run {
                infoMessage = message
                refreshCommunityPricePreviews()
                dismissPriceUpdateSheet()
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
            zip: context.zipCode
        ) ?? normalizedStationText(context.stationName)
    }
}

#Preview {
    StationsView()
        .modelContainer(for: FuelStation.self, inMemory: true)
        .environment(StationLocationManager())
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
}

private struct StationRowCard: View {
    let station: FuelStation
    let communitySummary: CommunityPriceSummary?
    let directionsAction: () -> String?
    let updatePriceAction: () -> Void
    let favoriteAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void
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

            HStack(spacing: 10) {
                Button {
                    directionsMessage = directionsAction()
                } label: {
                    Label("Directions", systemImage: "location.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppTheme.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Get directions to \(station.name)")

                Button(action: reportPriceAction) {
                    Label("Report Price", systemImage: "tag.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.charcoal)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppTheme.Colors.stationYellow)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Report E85 price for \(station.name)")

                Button(action: saveAction) {
                    Label(isSaved ? "Saved" : "Save Station", systemImage: isSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSaved ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(isSaved ? AppTheme.Colors.cardBackground : AppTheme.Colors.primaryGreen.opacity(0.20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(isSaved ? AppTheme.Colors.borderColor : AppTheme.Colors.primaryGreen, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSaved)
                .accessibilityLabel(isSaved ? "\(station.name) already saved" : "Save \(station.name)")
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

    private var locationLine: String {
        let cityState = [station.city, station.state]
            .filter { $0.isEmpty == false }
            .joined(separator: ", ")

        return [station.address, cityState, station.zip]
            .filter { $0.isEmpty == false }
            .joined(separator: " • ")
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
    // true only when this context was built from a live NREL search result.
    // Local/manual FuelStation records carry false regardless of how they were created,
    // since the model has no source marker and we cannot reliably distinguish them.
    let isLiveDiscovered: Bool

    // TODO: FuelStation has no source marker, so NREL-saved and legacy manual stations are
    // indistinguishable here. isLiveDiscovered is conservatively false for all saved records.
    // Future migration: add a StationSource enum field (e.g. .nrelSearch / .manual) to
    // FuelStation. Once available, set isLiveDiscovered = (station.source == .nrelSearch) so
    // NREL-backed saved stations regain community price reporting while manual ones stay local.
    static func saved(_ station: FuelStation) -> StationPriceUpdateContext {
        StationPriceUpdateContext(
            station: station,
            stationName: station.name,
            address: station.address,
            city: station.city,
            state: station.state,
            zipCode: station.zipCode,
            latitude: station.latitude,
            longitude: station.longitude,
            isLiveDiscovered: false
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
            longitude: station.longitude == 0 ? nil : station.longitude,
            isLiveDiscovered: true
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

                            if context.isLiveDiscovered {
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
                                Text("Community price reporting is available for stations found through nearby search.")
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
