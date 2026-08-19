//
//  AddEditVehicleView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import PhotosUI
import SwiftData
import UIKit

struct AddEditVehicleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let vehicle: VehicleProfile?
    let existingVehiclesCount: Int
    // Every saved vehicle's (id, nickname) — including `vehicle` itself when editing — used only
    // to detect a nickname conflict via VehicleNicknamePolicy. `vehicle`'s own id is excluded
    // from the conflict check inside nicknameValidationMessage, not by pre-filtering this list.
    let existingVehicles: [(id: PersistentIdentifier, nickname: String)]
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
        existingVehicles: [(id: PersistentIdentifier, nickname: String)],
        isSoleActiveVehicle: Bool = false,
        onSave: @escaping (VehicleDraft) -> Void
    ) {
        self.vehicle = vehicle
        self.existingVehiclesCount = existingVehiclesCount
        self.existingVehicles = existingVehicles
        self.isSoleActiveVehicle = isSoleActiveVehicle
        self.onSave = onSave
        _draft = State(initialValue: VehicleDraft(vehicle: vehicle, existingVehiclesCount: existingVehiclesCount))
    }

    // Actionable, non-technical validation message for the current nickname, or nil when it's
    // safe to save — see VehicleNicknamePolicy. Recomputed live as the user types, mirroring
    // isOdometerRegression/odometerRegressionMessage's pattern below.
    private var nicknameValidationMessage: String? {
        VehicleNicknamePolicy.validationError(
            for: draft.nickname,
            excluding: vehicle?.persistentModelID,
            among: existingVehicles
        )
    }

    // True when saving right now would leave zero active vehicles — i.e. this is the sole
    // active vehicle and the user has turned its "Active" toggle off in the form.
    private var wouldLeaveNoActiveVehicle: Bool {
        isSoleActiveVehicle && draft.isActive == false
    }

    // True only when editing an existing vehicle and the entered odometer is below its stored
    // reading. Always false when creating a new vehicle — there is no prior value to regress
    // against.
    private var isOdometerRegression: Bool {
        guard let vehicle else { return false }
        return VehicleOdometerPolicy.isRegression(existing: vehicle.currentOdometer, requested: draft.currentOdometer)
    }

    private var odometerRegressionMessage: String? {
        guard isOdometerRegression, let vehicle else { return nil }
        return "Current odometer cannot be lower than the saved reading of \(vehicle.currentOdometer.formatted(.number.grouping(.automatic))) mi."
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
                    // Routine editing must never lower the odometer — see saveVehicle for the
                    // authoritative guarantee this mirrors. A blank/conflicting nickname is
                    // blocked the same way — see GarageView.saveVehicle's defensive second guard.
                    .disabled(isOdometerRegression || nicknameValidationMessage != nil)
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

            StringInputField(title: "Nickname", text: $draft.nickname, isInvalid: nicknameValidationMessage != nil)

            // Actionable feedback for a blank or conflicting nickname — see
            // VehicleNicknamePolicy. Save stays disabled above while this is non-nil; the sheet
            // is never dismissed with an invalid nickname.
            if let nicknameValidationMessage {
                Text(nicknameValidationMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(red: 0.98, green: 0.54, blue: 0.54))
            }

            vehiclePhotoSection
            identityFields
            metricsFields
            fuelPreferenceFields
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
            TankSizeInputField(value: $draft.tankSizeGallons)
            if shouldShowTankLookupHelper {
                tankLookupHelperSection
            }
            IntInputField(title: "Current Odometer", value: $draft.currentOdometer, keyboard: .numberPad)

            // Calm, non-blocking explanation — never a destructive/alarming style — for why
            // Save is disabled. Disappears the moment the value is restored to equal or higher.
            if let odometerRegressionMessage {
                Text(odometerRegressionMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

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

    // 85Blends 2.3.0 Garage simplification: this section used to be "Calculator Defaults" with
    // four separate ethanol fields (Default Target/Current/Pump Ethanol %, Gas Ethanol %).
    // Current/Pump/Gas Ethanol are tank/session/app-level state now, not vehicle properties —
    // see FuelPreferenceResolution.swift — so only one, optional field remains here.
    private var fuelPreferenceFields: some View {
        Group {
            SectionHeader(
                title: "Fuel Preference",
                subtitle: nil
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Preferred Ethanol Target")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("Optional \u{00B7} Used as your starting target in the Blend Calculator.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                OptionalPercentField(value: $draft.preferredEthanolTargetPercent)
            }
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
    /// `0` means "not entered" — TankSizeInputField displays it as a blank field rather than a
    /// literal "0". See VehicleProfile.tankSizeGallons and audit item 7 (Tank Size). Never
    /// silently defaulted to a placeholder like 16 — a real tank is never 0 gallons, so 0 is a
    /// safe, unambiguous "unset" sentinel here, unlike an ethanol percent (where 0 is a real,
    /// meaningful value and must never be reused as "unset").
    var tankSizeGallons: Double
    var currentOdometer: Int
    var requiredOctane: Double
    /// `nil` means "no preference" — see VehicleProfile.preferredEthanolTargetPercent. Must
    /// never be coerced to a specific percentage (E0/E10/E30/etc.) anywhere in this type.
    var preferredEthanolTargetPercent: Double?
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
        // No 16-gallon (or any) placeholder for a brand-new vehicle — Tank Size stays genuinely
        // optional during creation. See audit item 3/4 and TankSizeInputField.
        tankSizeGallons = vehicle?.tankSizeGallons ?? 0
        currentOdometer = vehicle?.currentOdometer ?? 0
        requiredOctane = vehicle?.requiredOctane ?? 91

        if let vehicle {
            if vehicle.calculatorPreferenceSemanticsVersion >= VehiclePreferenceSemantics.current {
                preferredEthanolTargetPercent = vehicle.preferredEthanolTargetPercent
            } else {
                // Legacy vehicle: defaultTargetEthanolPercent IS its effective preference today
                // (see PreferredTargetResolution) — show it as the starting value so opening
                // Edit Vehicle never appears to silently clear an existing preference. Saving
                // from this form transitions the vehicle to the new semantics (GarageView).
                preferredEthanolTargetPercent = vehicle.defaultTargetEthanolPercent
            }
        } else {
            // Brand-new vehicle: genuinely no preference until the user sets one.
            preferredEthanolTargetPercent = nil
        }

        isFlexFuel = vehicle?.isFlexFuel ?? false
        isActive = vehicle?.isActive ?? (existingVehiclesCount == 0)
        vehiclePhotoData = vehicle?.vehiclePhotoData
    }

    mutating func normalizeForSave() {
        // See VehicleNicknamePolicy — the persisted nickname is trimmed of leading/trailing
        // whitespace/newlines, never otherwise altered (no case folding, no internal whitespace
        // collapsing). AddEditVehicleView's Save button is already disabled while the nickname
        // is blank or conflicts with another vehicle, so this trim never turns a valid nickname
        // into an invalid one — it only removes whitespace the user didn't mean to save.
        nickname = VehicleNicknamePolicy.normalizedForSave(nickname)
        tankSizeGallons = max(tankSizeGallons, 0)
        currentOdometer = max(currentOdometer, 0)
        requiredOctane = max(requiredOctane, 0)
        if let value = preferredEthanolTargetPercent {
            preferredEthanolTargetPercent = min(max(value, 0), 100)
        }
    }
}

private struct StringInputField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var isInvalid: Bool = false

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
                        .stroke(isInvalid ? AppTheme.Colors.warningRed : AppTheme.Colors.border, lineWidth: 1)
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

/// Tank Size Gallons — a non-optional `Double` where `0` means "not entered". Displays as a
/// blank field (rather than the literal "0") so a new/unset vehicle visually communicates that
/// this is optional, per audit item 3/18. Unparseable, non-empty text leaves the value
/// unchanged (matches DoubleInputField's retain-last-valid-value behavior); a genuinely empty
/// field resolves to 0 (unset), never to a guessed placeholder like 16.
private struct TankSizeInputField: View {
    @Binding var value: Double

    private var textBinding: Binding<String> {
        Binding(
            get: { value > 0 ? formatted(value) : "" },
            set: { newText in
                let trimmed = newText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    value = 0
                } else if let parsed = Double(trimmed) {
                    value = parsed
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tank Size Gallons")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField("Optional", text: textBinding)
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

            Text("Optional \u{00B7} We'll ask again in Calculator if it's needed for a blend.")
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
    }

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Preferred Ethanol Target — a genuinely optional `Double?`. `nil` displays as a blank field
/// and must never be coerced to a specific percentage. Unparseable, non-empty text leaves the
/// value unchanged; a genuinely empty field resolves to `nil` ("no preference"), not to 0 or any
/// other percentage — see audit item 5/11 and VehicleProfile.preferredEthanolTargetPercent.
private struct OptionalPercentField: View {
    @Binding var value: Double?

    private var textBinding: Binding<String> {
        Binding(
            get: { value.map(formatted) ?? "" },
            set: { newText in
                let trimmed = newText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    value = nil
                } else if let parsed = Double(trimmed) {
                    value = parsed
                }
            }
        )
    }

    var body: some View {
        HStack {
            TextField("No preference", text: textBinding)
                .keyboardType(.decimalPad)
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("%")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value)
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
