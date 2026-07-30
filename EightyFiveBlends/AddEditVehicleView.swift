//
//  AddEditVehicleView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import PhotosUI
import UIKit

struct AddEditVehicleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let vehicle: VehicleProfile?
    let existingVehiclesCount: Int
    // True when `vehicle` is currently the only active vehicle. Used only to explain, live,
    // why turning "Active" off won't take effect — saveVehicle enforces the actual guarantee
    // regardless of this hint, so a stale value here can never let the invariant slip.
    let isSoleActiveVehicle: Bool
    let onSave: (VehicleDraft) -> Void

    @State private var draft: VehicleDraft
    @State private var selectedPhotoItem: PhotosPickerItem?

    @MainActor
    init(
        vehicle: VehicleProfile?,
        existingVehiclesCount: Int,
        isSoleActiveVehicle: Bool = false,
        onSave: @escaping (VehicleDraft) -> Void
    ) {
        self.vehicle = vehicle
        self.existingVehiclesCount = existingVehiclesCount
        self.isSoleActiveVehicle = isSoleActiveVehicle
        self.onSave = onSave
        _draft = State(initialValue: VehicleDraft(vehicle: vehicle, existingVehiclesCount: existingVehiclesCount))
    }

    // True when saving right now would leave zero active vehicles — i.e. this is the sole
    // active vehicle and the user has turned its "Active" toggle off in the form.
    private var wouldLeaveNoActiveVehicle: Bool {
        isSoleActiveVehicle && draft.isActive == false
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
            .navigationTitle(vehicle == nil ? "Add Vehicle" : "Edit Vehicle")
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
                        var finalDraft = draft
                        finalDraft.normalizeForSave()
                        onSave(finalDraft)
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.Colors.accentGreen)
                }
            }
        }
        .keyboardDoneToolbar()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await loadSelectedPhoto(from: newItem)
            }
        }
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: vehicle == nil ? "New Vehicle" : "Edit Vehicle",
                subtitle: "Save a profile for calculator defaults, fuel logs, and reminders."
            )

            StringInputField(title: "Nickname", text: $draft.nickname)
            vehiclePhotoSection
            identityFields
            metricsFields
            defaultsFields
            togglesSection
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

    private var identityFields: some View {
        Group {
            StringInputField(title: "Year", text: $draft.year, keyboard: .numberPad)
            StringInputField(title: "Make", text: $draft.make)
            StringInputField(title: "Model", text: $draft.model)
            StringInputField(title: "Trim", text: $draft.trim)
        }
    }

    private var vehiclePhotoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Vehicle Photo",
                subtitle: "Choose a local photo for this Garage profile."
            )

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                vehiclePhotoPreview
            }
            .buttonStyle(.plain)

            if draft.vehiclePhotoData != nil {
                Button("Remove Photo") {
                    draft.vehiclePhotoData = nil
                    selectedPhotoItem = nil
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.warningRed)
            }
        }
    }

    private var vehiclePhotoPreview: some View {
        VStack(spacing: 10) {
            if let image = vehiclePreviewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)

                    Text("Choose a vehicle photo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Add a photo from your library to make this profile easier to spot.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            }

            HStack {
                Text(draft.vehiclePhotoData == nil ? "Select Photo" : "Change Photo")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Spacer()

                Image(systemName: "photo.on.rectangle")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.accentGreen)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var vehiclePreviewImage: UIImage? {
        guard let photoData = draft.vehiclePhotoData else { return nil }
        return UIImage(data: photoData)
    }

    private var metricsFields: some View {
        Group {
            DoubleInputField(title: "Tank Size Gallons", value: $draft.tankSizeGallons, keyboard: .decimalPad)
            if shouldShowTankLookupHelper {
                tankLookupHelperSection
            }
            IntInputField(title: "Current Odometer", value: $draft.currentOdometer, keyboard: .numberPad)
            DoubleInputField(title: "Required Octane", value: $draft.requiredOctane, keyboard: .decimalPad)
        }
    }

    private var shouldShowTankLookupHelper: Bool {
        draft.make.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var tankLookupHelperSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Need the tank size?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("Search the web for this vehicle's fuel tank capacity, then confirm the value before saving.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Button {
                openTankSizeSearch()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Look Up Tank Size")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.Colors.primaryGreen)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var defaultsFields: some View {
        Group {
            SectionHeader(
                title: "Calculator Defaults",
                subtitle: "Used to prefill your blend setup on the calculator tab."
            )

            DoubleInputField(title: "Default Target Ethanol %", value: $draft.defaultTargetEthanolPercent, keyboard: .decimalPad)
            DoubleInputField(title: "Default Current Ethanol %", value: $draft.defaultCurrentEthanolPercent, keyboard: .decimalPad)
            DoubleInputField(title: "Default Pump Ethanol %", value: $draft.defaultPumpEthanolPercent, keyboard: .decimalPad)
            DoubleInputField(title: "Gas Ethanol %", value: $draft.gasEthanolPercent, keyboard: .decimalPad)
        }
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToggleRow(title: "Flex Fuel Vehicle", isOn: $draft.isFlexFuel)
            ToggleRow(
                title: existingVehiclesCount == 0 ? "Active Vehicle (first vehicle auto-activates)" : "Set As Active Vehicle",
                isOn: $draft.isActive
            )

            // Calm, non-blocking explanation — never an error — for why this vehicle will stay
            // active on save. Matches the historical-entry notice style used for reminder
            // completion: informational, not alarming, and doesn't disable Save.
            if wouldLeaveNoActiveVehicle {
                Text("At least one vehicle must remain active. Set another vehicle active before turning this one off.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    @MainActor
    private func loadSelectedPhoto(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let processedData = processedPhotoData(from: data) else {
            return
        }

        draft.vehiclePhotoData = processedData
    }

    private func processedPhotoData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let resizedImage = resizedImageIfNeeded(image, maxDimension: 1200)
        return resizedImage.jpegData(compressionQuality: 0.75)
    }

    private func resizedImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxDimension else { return image }

        let scale = maxDimension / longestSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private func openTankSizeSearch() {
        let query = [
            draft.year,
            draft.make,
            draft.model,
            draft.trim,
            "fuel tank capacity gallons"
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
        .joined(separator: " ")

        guard
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "https://www.google.com/search?q=\(encodedQuery)")
        else {
            return
        }

        openURL(url)
    }
}

struct VehicleDraft {
    var nickname: String
    var year: String
    var make: String
    var model: String
    var trim: String
    var tankSizeGallons: Double
    var currentOdometer: Int
    var requiredOctane: Double
    var defaultTargetEthanolPercent: Double
    var defaultCurrentEthanolPercent: Double
    var defaultPumpEthanolPercent: Double
    var gasEthanolPercent: Double
    var isFlexFuel: Bool
    var isActive: Bool
    var vehiclePhotoData: Data?

    @MainActor
    init(vehicle: VehicleProfile?, existingVehiclesCount: Int) {
        nickname = vehicle?.nickname ?? ""
        year = vehicle?.year ?? ""
        make = vehicle?.make ?? ""
        model = vehicle?.model ?? ""
        trim = vehicle?.trim ?? ""
        tankSizeGallons = vehicle?.tankSizeGallons ?? 16
        currentOdometer = vehicle?.currentOdometer ?? 0
        requiredOctane = vehicle?.requiredOctane ?? 91
        defaultTargetEthanolPercent = vehicle?.defaultTargetEthanolPercent ?? 30
        defaultCurrentEthanolPercent = vehicle?.defaultCurrentEthanolPercent ?? 10
        defaultPumpEthanolPercent = vehicle?.defaultPumpEthanolPercent ?? 85
        gasEthanolPercent = vehicle?.gasEthanolPercent ?? 10
        isFlexFuel = vehicle?.isFlexFuel ?? false
        isActive = vehicle?.isActive ?? (existingVehiclesCount == 0)
        vehiclePhotoData = vehicle?.vehiclePhotoData
    }

    mutating func normalizeForSave() {
        tankSizeGallons = max(tankSizeGallons, 0)
        currentOdometer = max(currentOdometer, 0)
        requiredOctane = max(requiredOctane, 0)
        defaultTargetEthanolPercent = min(max(defaultTargetEthanolPercent, 0), 100)
        defaultCurrentEthanolPercent = min(max(defaultCurrentEthanolPercent, 0), 100)
        defaultPumpEthanolPercent = min(max(defaultPumpEthanolPercent, 0), 100)
        gasEthanolPercent = min(max(gasEthanolPercent, 0), 100)
    }
}

private struct StringInputField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, text: $text)
                .keyboardType(keyboard)
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

private struct IntInputField: View {
    let title: String
    @Binding var value: Int
    var keyboard: UIKeyboardType = .numberPad

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, value: $value, format: .number)
                .keyboardType(keyboard)
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

private struct DoubleInputField: View {
    let title: String
    @Binding var value: Double
    var keyboard: UIKeyboardType = .decimalPad

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, value: $value, format: .number)
                .keyboardType(keyboard)
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

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .tint(AppTheme.Colors.accentGreen)
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
