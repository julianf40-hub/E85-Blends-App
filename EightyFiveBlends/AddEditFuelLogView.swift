//
//  AddEditFuelLogView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData
import CoreLocation

struct AddEditFuelLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FuelStation.updatedAt, order: .reverse)
    private var savedStations: [FuelStation]

    let entry: FuelLogEntry?
    let initialDraft: FuelLogDraft?
    let onSave: (FuelLogDraft) throws -> Void

    @State private var draft: FuelLogDraft
    @State private var saveErrorMessage: String?
    @State private var locationManager = StationLocationManager()
    @State private var isDetectingStation = false
    @State private var detectStationMessage: String?
    @State private var detectedStationName: String?
    @State private var overwriteCandidate: DetectedFuelStationCandidate?
    @State private var confirmOverwrite = false

    @MainActor
    init(
        entry: FuelLogEntry?,
        initialDraft: FuelLogDraft? = nil,
        onSave: @escaping (FuelLogDraft) throws -> Void
    ) {
        self.entry = entry
        self.initialDraft = initialDraft
        self.onSave = onSave
        _draft = State(initialValue: FuelLogDraft(entry: entry, seed: initialDraft))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formCard
                }
                .padding(16)
            }
            .dismissKeyboardOnTap()
            .background(AppTheme.Colors.charcoal)
            .navigationTitle(entry == nil ? "Add Fill-Up" : "Edit Fill-Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        do {
                            try onSave(draft)
                            dismiss()
                        } catch {
                            saveErrorMessage = error.localizedDescription
                        }
                    }
                    .foregroundStyle(AppTheme.Colors.accentGreen)
                }
            }
        }
        .keyboardDoneToolbar()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: locationManager.latestCoordinate) { _, coordinate in
            guard isDetectingStation, let coordinate else { return }
            handleDetectedCoordinate(coordinate)
        }
        .onChange(of: locationManager.authorizationStatus) { _, status in
            guard isDetectingStation else { return }

            switch status {
            case .denied, .restricted:
                isDetectingStation = false
                detectStationMessage = "Location access is off. Enable it in Settings to detect a nearby station."
            default:
                break
            }
        }
        .alert("Use detected station?", isPresented: $confirmOverwrite) {
            Button("Use Detected Station") {
                applyDetectedStationCandidate()
            }
            Button("Keep Current Name", role: .cancel) {
                overwriteCandidate = nil
            }
        } message: {
            Text("Replace the current station name with \(overwriteCandidate?.station.name ?? "this station")?")
        }
        .alert("Couldn’t Save Fill-Up", isPresented: saveErrorBinding) {
            Button("OK", role: .cancel) {
                saveErrorMessage = nil
            }
        } message: {
            Text(saveErrorMessage ?? "Please try again.")
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    saveErrorMessage = nil
                }
            }
        )
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: entry == nil ? "New Fill-Up" : "Edit Fill-Up",
                subtitle: "Fuel totals are stored locally and blend outputs remain estimates."
            )

            DatePicker(
                "Date",
                selection: $draft.date,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .tint(AppTheme.Colors.accentGreen)
            .foregroundStyle(AppTheme.Colors.textPrimary)

            FuelStringInputField(title: "Vehicle Name", text: $draft.vehicleName)
            stationNameSection
            FuelIntInputField(title: "Odometer", value: $draft.odometer)
            FuelDoubleInputField(title: "Target Blend Percent", value: $draft.targetBlendPercent)
            FuelDoubleInputField(title: "Final Blend Percent", value: $draft.finalBlendPercent)
            FuelDoubleInputField(title: "E85 Gallons", value: $draft.e85Gallons)
            FuelDoubleInputField(title: "Gas Gallons", value: $draft.gasGallons)
            FuelDoubleInputField(title: "E85 Price Per Gallon", value: $draft.e85PricePerGallon)
            FuelDoubleInputField(title: "Gas Price Per Gallon", value: $draft.gasPricePerGallon)

            SectionHeader(
                title: "Computed Values",
                subtitle: "Calculated from the gallons and price inputs below."
            )

            ComputedFuelValueRow(title: "Gallons Added", value: String(format: "%.2f", draft.computedGallonsAdded))
            ComputedFuelValueRow(title: "Total Cost", value: "$\(String(format: "%.2f", draft.computedTotalCost))")
            ComputedFuelValueRow(
                title: "MPG",
                value: draft.mpg > 0 ? String(format: "%.1f", draft.mpg) : "Calculated on save"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Notes")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                TextField("Optional notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(4, reservesSpace: true)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var stationNameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Station Name")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                Spacer()

                Button {
                    detectNearestStation()
                } label: {
                    HStack(spacing: 6) {
                        if isDetectingStation {
                            ProgressView()
                                .tint(AppTheme.Colors.charcoal)
                                .scaleEffect(0.85)
                        } else {
                            Image(systemName: "location.magnifyingglass")
                        }
                        Text(isDetectingStation ? "Detecting…" : "Detect Station")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.charcoal)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.Colors.stationYellow)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isDetectingStation)
            }

            TextField("Station Name", text: $draft.stationName)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let detectedStationName {
                Text("Detected: \(detectedStationName)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
            } else if let detectStationMessage {
                Text(detectStationMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            } else if draft.stationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Tap Detect Station to autofill from your location.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private func detectNearestStation() {
        detectStationMessage = nil
        detectedStationName = nil
        overwriteCandidate = nil
        isDetectingStation = true
        locationManager.requestUserLocation()
    }

    private func handleDetectedCoordinate(_ coordinate: StationCoordinate) {
        isDetectingStation = false

        guard let candidate = nearestSavedStation(to: coordinate.clCoordinate) else {
            detectStationMessage = "No nearby saved station found."
            return
        }

        let currentName = draft.stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentName.isEmpty == false,
           currentName.caseInsensitiveCompare(candidate.station.name) != .orderedSame {
            overwriteCandidate = candidate
            confirmOverwrite = true
            return
        }

        applyDetectedStation(candidate)
    }

    private func nearestSavedStation(to coordinate: CLLocationCoordinate2D) -> DetectedFuelStationCandidate? {
        let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        let candidates: [DetectedFuelStationCandidate] = savedStations.compactMap { station -> DetectedFuelStationCandidate? in
            guard let latitude = station.latitude, let longitude = station.longitude else {
                return nil
            }

            let stationLocation = CLLocation(latitude: latitude, longitude: longitude)
            let distance = userLocation.distance(from: stationLocation)
            guard distance <= 804.67 else { return nil }

            return DetectedFuelStationCandidate(station: station, distance: distance)
        }

        return candidates.sorted { lhs, rhs in
            lhs.distance < rhs.distance
        }.first
    }

    private func applyDetectedStationCandidate() {
        guard let overwriteCandidate else { return }
        applyDetectedStation(overwriteCandidate)
        self.overwriteCandidate = nil
    }

    private func applyDetectedStation(_ candidate: DetectedFuelStationCandidate) {
        draft.stationName = candidate.station.name
        detectedStationName = candidate.station.name
        detectStationMessage = nil
        AppHaptics.success()
    }
}

private struct DetectedFuelStationCandidate {
    let station: FuelStation
    let distance: CLLocationDistance
}

struct FuelLogDraft {
    var date: Date
    var vehicleName: String
    var stationName: String
    var odometer: Int
    var targetBlendPercent: Double
    var finalBlendPercent: Double
    var e85Gallons: Double
    var gasGallons: Double
    var e85PricePerGallon: Double
    var gasPricePerGallon: Double
    var mpg: Double
    var notes: String

    var computedGallonsAdded: Double {
        e85Gallons + gasGallons
    }

    var computedTotalCost: Double {
        (e85Gallons * e85PricePerGallon) + (gasGallons * gasPricePerGallon)
    }

    mutating func normalizeForSave() {
        odometer = max(odometer, 0)
        targetBlendPercent = min(max(targetBlendPercent, 0), 100)
        finalBlendPercent = min(max(finalBlendPercent, 0), 100)
        e85Gallons = max(e85Gallons, 0)
        gasGallons = max(gasGallons, 0)
        e85PricePerGallon = max(e85PricePerGallon, 0)
        gasPricePerGallon = max(gasPricePerGallon, 0)
        mpg = max(mpg, 0)
    }

    init(
        date: Date,
        vehicleName: String,
        stationName: String,
        odometer: Int,
        targetBlendPercent: Double,
        finalBlendPercent: Double,
        e85Gallons: Double,
        gasGallons: Double,
        e85PricePerGallon: Double,
        gasPricePerGallon: Double,
        mpg: Double,
        notes: String
    ) {
        self.date = date
        self.vehicleName = vehicleName
        self.stationName = stationName
        self.odometer = odometer
        self.targetBlendPercent = targetBlendPercent
        self.finalBlendPercent = finalBlendPercent
        self.e85Gallons = e85Gallons
        self.gasGallons = gasGallons
        self.e85PricePerGallon = e85PricePerGallon
        self.gasPricePerGallon = gasPricePerGallon
        self.mpg = mpg
        self.notes = notes
    }

    @MainActor
    init(entry: FuelLogEntry?, seed: FuelLogDraft? = nil) {
        if let entry {
            date = entry.date
            vehicleName = entry.vehicleName
            stationName = entry.stationName
            odometer = entry.odometer
            targetBlendPercent = entry.targetBlendPercent
            finalBlendPercent = entry.finalBlendPercent
            e85Gallons = entry.e85Gallons
            gasGallons = entry.gasGallons
            e85PricePerGallon = entry.e85PricePerGallon
            gasPricePerGallon = entry.gasPricePerGallon
            mpg = entry.mpg
            notes = entry.notes
        } else if let seed {
            self = seed
        } else {
            date = .now
            vehicleName = ""
            stationName = ""
            odometer = 0
            targetBlendPercent = 30
            finalBlendPercent = 30
            e85Gallons = 0
            gasGallons = 0
            e85PricePerGallon = 0
            gasPricePerGallon = 0
            mpg = 0
            notes = ""
        }
    }
}

private struct FuelStringInputField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, text: $text)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct FuelIntInputField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, value: $value, format: .number)
                .keyboardType(.numberPad)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct FuelDoubleInputField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, value: $value, format: .number)
                .keyboardType(.decimalPad)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct ComputedFuelValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
