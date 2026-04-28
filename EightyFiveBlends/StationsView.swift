//
//  StationsView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData

struct StationsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FuelStation.updatedAt, order: .reverse)
    private var stations: [FuelStation]

    @State private var searchText = ""
    @State private var selectedRadius = "25 mi"
    @State private var sheetStation: FuelStation?
    @State private var isAddingStation = false
    @State private var stationPendingDeletion: FuelStation?
    @State private var infoMessage: String?

    private let radiusOptions = ["10 mi", "25 mi", "50 mi", "100 mi"]

    private var filteredStations: [FuelStation] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return stations
            .filter { station in
                guard trimmed.isEmpty == false else { return true }
                let needle = trimmed.lowercased()
                return station.name.lowercased().contains(needle) ||
                    station.city.lowercased().contains(needle) ||
                    station.state.lowercased().contains(needle) ||
                    station.address.lowercased().contains(needle)
            }
            .sorted { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite {
                    return lhs.isFavorite && !rhs.isFavorite
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    mapOverviewCard
                    searchCard
                    radiusSelector
                    locationInfoCard
                    stationsSection
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .sheet(isPresented: $isAddingStation) {
            AddEditStationView(station: nil) { draft in
                createStation(from: draft)
            }
        }
        .sheet(item: $sheetStation) { station in
            AddEditStationView(station: station) { draft in
                updateStation(station, from: draft)
            }
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
        .alert("Coming Soon", isPresented: infoAlertBinding) {
            Button("OK", role: .cancel) {
                infoMessage = nil
            }
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.Colors.softGreenBackground.opacity(0.72))

                    Image(systemName: "map.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 4) {
                    Text("LOCAL STOPS")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text("E85 Stations")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Save trusted E85 stations locally now. Nearby discovery and routing can be layered in later.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    infoMessage = "Live station refresh and nearby discovery can be added in a later update."
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

                Button {
                    isAddingStation = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                        Text("Add Station")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppTheme.Colors.primaryGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private var mapOverviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppTheme.Colors.softGreenBackground.opacity(0.95),
                                    AppTheme.Colors.gasOrange.opacity(0.24)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Image(systemName: "map.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)

                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                        .offset(x: 22, y: 22)
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved Station Finder")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Build a local list of ethanol stops now. Live nearby search, routing, and distance can plug in later without changing your saved data.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            HStack(spacing: 10) {
                heroTag(title: "Local-First", accent: AppTheme.Colors.primaryGreen)
                heroTag(title: "No Permission Yet", accent: AppTheme.Colors.stationYellow)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var searchCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField("Search saved stations", text: $searchText)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
        .padding(16)
        .background(AppTheme.Colors.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var radiusSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Search Radius", subtitle: "Visual only for now until live nearby search is connected.")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(radiusOptions, id: \.self) { radius in
                        Button {
                            AppHaptics.selection()
                            selectedRadius = radius
                            infoMessage = "Live radius search is coming later. Saved stations stay fully local for now."
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
        }
    }

    private var locationInfoCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "location.circle")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.stationYellow)

            VStack(alignment: .leading, spacing: 6) {
                Text("Location Access Later")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("Location permission is not requested yet. Saved stations work locally now, and nearby search can be added later when live discovery is ready.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
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

    private var stationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Saved Stations", subtitle: "Favorites are pinned first, then recently updated stops.")

            if filteredStations.isEmpty {
                emptyStateCard
            } else {
                ForEach(filteredStations) { station in
                    StationRowCard(
                        station: station,
                        favoriteAction: { toggleFavorite(station) },
                        editAction: { sheetStation = station },
                        deleteAction: { stationPendingDeletion = station }
                    )
                }
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title2)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.Colors.stationYellow.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("No saved E85 stations yet")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Add stations manually now. Live station search can be added later.")
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

    private func heroTag(title: String, accent: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(accent.opacity(0.18))
            .overlay(
                Capsule()
                    .stroke(accent.opacity(0.6), lineWidth: 1)
            )
            .clipShape(Capsule())
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

    private func createStation(from draft: StationDraft) {
        let station = FuelStation(
            name: draft.name,
            address: draft.address,
            city: draft.city,
            state: draft.state,
            zipCode: draft.zipCode,
            lastKnownE85Price: draft.lastKnownE85Price,
            lastUpdated: .now,
            notes: draft.notes,
            isFavorite: draft.isFavorite,
            createdAt: .now,
            updatedAt: .now
        )
        modelContext.insert(station)
        try? modelContext.save()
        AppHaptics.success()
    }

    private func updateStation(_ station: FuelStation, from draft: StationDraft) {
        station.name = draft.name
        station.address = draft.address
        station.city = draft.city
        station.state = draft.state
        station.zipCode = draft.zipCode
        station.lastKnownE85Price = draft.lastKnownE85Price
        station.notes = draft.notes
        station.isFavorite = draft.isFavorite
        station.lastUpdated = .now
        station.updatedAt = .now
        try? modelContext.save()
        AppHaptics.success()
    }

    private func toggleFavorite(_ station: FuelStation) {
        station.isFavorite.toggle()
        station.updatedAt = .now
        try? modelContext.save()
        AppHaptics.selection()
    }

    private func confirmDeletion() {
        guard let stationPendingDeletion else { return }
        modelContext.delete(stationPendingDeletion)
        try? modelContext.save()
        self.stationPendingDeletion = nil
        AppHaptics.warning()
    }
}

#Preview {
    StationsView()
        .modelContainer(for: FuelStation.self, inMemory: true)
}

private struct StationRowCard: View {
    let station: FuelStation
    let favoriteAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void
    @State private var directionsInfoVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppTheme.Colors.softGreenBackground.opacity(0.85),
                                    AppTheme.Colors.primaryGreen.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

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

                    Text("Distance available with live station search")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("LAST E85")
                        .font(.caption2.weight(.bold))
                        .tracking(1.0)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text(station.lastKnownE85Price > 0 ? "$\(String(format: "%.2f", station.lastKnownE85Price))" : "--")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AppTheme.Colors.primaryGreen.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            if station.notes.isEmpty == false {
                Text(station.notes)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            HStack {
                Text("Last updated \(station.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Spacer()

                Text(station.isFavorite ? "Favorite" : "Saved")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(station.isFavorite ? AppTheme.Colors.stationYellow : AppTheme.Colors.textSecondary)
            }

            HStack(spacing: 10) {
                Button {
                    directionsInfoVisible = true
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
        .alert("Directions Coming Soon", isPresented: $directionsInfoVisible) {
            Button("OK", role: .cancel) {
                directionsInfoVisible = false
            }
        } message: {
            Text("Use your preferred maps app from Preferences once live station routing is connected.")
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
}
