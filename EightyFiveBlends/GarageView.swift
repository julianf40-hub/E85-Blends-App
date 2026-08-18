//
//  GarageView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData
import UIKit

struct GarageView: View {
    @Environment(\.modelContext) private var modelContext
    // Drives headerSection's normal-row vs. stacked fallback layout — see headerSection.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \VehicleProfile.createdAt, order: .forward)
    private var vehicles: [VehicleProfile]

    @State private var sheetContext: VehicleSheetContext?
    @State private var vehiclePendingDeletion: VehicleProfile?
    @State private var deletionMessage = ""
    @State private var odometerUpdateContext: ActiveOdometerUpdateContext?
    @State private var odometerInput = ""
    @State private var odometerValidationMessage: String?
    @State private var saveErrorMessage: String?

    private var activeVehicle: VehicleProfile? {
        vehicles.first(where: { $0.isActive })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection

                    if let activeVehicle {
                        ActiveVehicleCard(
                            vehicle: activeVehicle,
                            editAction: { sheetContext = .edit(activeVehicle) },
                            odometerAction: { beginOdometerUpdate(for: activeVehicle) }
                        )
                    } else {
                        // Distinguish "no vehicles saved yet" from "vehicles exist but none is
                        // flagged active" (e.g. restored/synced data) — the two need different
                        // guidance, and the second must not tell the user to add a vehicle they
                        // already have.
                        EmptyGarageCard(hasSavedVehicles: vehicles.isEmpty == false)
                    }

                    savedVehiclesSection
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .sheet(item: $sheetContext) { context in
            AddEditVehicleView(
                vehicle: context.vehicle,
                existingVehiclesCount: vehicles.count,
                // Lets the form explain, live, why turning "Active" off won't take effect —
                // the actual guarantee is enforced in saveVehicle regardless of this hint.
                isSoleActiveVehicle: context.vehicle.map { editingVehicle in
                    editingVehicle.isActive && vehicles.filter(\.isActive).count == 1
                } ?? false
            ) { draft in
                saveVehicle(from: draft, editing: context.vehicle)
            }
        }
        .sheet(item: $odometerUpdateContext) { context in
            ActiveOdometerUpdateSheet(
                context: context,
                odometerInput: $odometerInput,
                validationMessage: $odometerValidationMessage,
                saveAction: { saveOdometerUpdate(for: context) },
                cancelAction: dismissOdometerSheet
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert("Delete Vehicle?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) {
                confirmDeletion()
            }

            Button("Cancel", role: .cancel) {
                vehiclePendingDeletion = nil
            }
        } message: {
            Text(deletionMessage)
        }
        .alert("Save Error", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    // Normal sizes use headerRow (title stack + button side by side, unchanged from Build 80's
    // appearance). At accessibility Dynamic Type sizes — where the two can no longer reliably
    // share one row — headerStack puts the button on its own line below the title stack instead
    // of letting either get compressed. Driven by an explicit dynamicTypeSize check rather than
    // ViewThatFits: ViewThatFits picks a candidate by each view's *ideal* (unconstrained) width,
    // and an un-fixed-size Text's ideal width is its single-line, unwrapped width — for the
    // subtitle here that's wider than the screen even at normal sizes, so ViewThatFits would
    // pick the stacked fallback unconditionally rather than only at genuinely-too-narrow sizes.
    private var headerSection: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                headerStack
            } else {
                headerRow
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 16) {
            headerTitleStack
            Spacer()
            addVehicleButton
        }
    }

    private var headerStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerTitleStack
            addVehicleButton
        }
    }

    private var headerTitleStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VEHICLE SETUP")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text("Garage")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("Manage your vehicles and calculator defaults.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        // Purely decorative/non-interactive — must never intercept a touch meant for
        // addVehicleButton beside it (the original partial-hit-area bug: this stack's laid-out
        // frame, sized by its Text children's ideal width before wrapping is applied, could
        // extend further than its rendered glyphs and sit in front of the button in hit-test
        // terms even though nothing was visibly wrong).
        .allowsHitTesting(false)
    }

    private var addVehicleButton: some View {
        Button {
            sheetContext = .add
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("Add Vehicle")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(AppTheme.Colors.accentGreen)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Matches the visible rounded rect exactly (rather than a plain Rectangle), applied
            // after the size/shape chain above so the button's full visible background — not
            // just its text/icon glyphs — is the tappable region.
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        // Locks this button to its natural (unwrapped) content width and gives it first claim
        // on horizontal space in headerRow's HStack, so the more-flexible (wrap-capable) title
        // stack beside it can never compress the button below its full intrinsic/rendered size —
        // the root cause of the original bug: the button's declared frame(minHeight: 44) only
        // ever guaranteed its HEIGHT, leaving its laid-out WIDTH to ordinary HStack space
        // negotiation, which could end up narrower than what was actually painted on screen.
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityLabel("Add Vehicle")
    }

    private var savedVehiclesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Saved Vehicles",
                subtitle: "Profiles used by the calculator, reminders, and fill-up history."
            )

            // Persistent Pro entry point for the Garage — visible to every free user, not just
            // once they hit the soft limit, so the upgrade path is always discoverable here.
            if !SubscriptionManager.shared.isProUser {
                ProFeatureLockView(
                    icon: "car.2.fill",
                    title: "Unlimited Vehicles",
                    description: "Manage your entire garage with 85Blends Pro."
                )
            }

            if vehicles.isEmpty {
                EmptySavedVehiclesCard()
            } else {
                ForEach(vehicles) { vehicle in
                    VehicleRowCard(
                        vehicle: vehicle,
                        setActiveAction: { setActiveVehicle(vehicle) },
                        editAction: { sheetContext = .edit(vehicle) },
                        deleteAction: { promptDeletion(for: vehicle) }
                    )
                }
            }
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { vehiclePendingDeletion != nil },
            set: { isPresented in
                if isPresented == false {
                    vehiclePendingDeletion = nil
                }
            }
        )
    }

    private func saveVehicle(from draft: VehicleDraft, editing vehicle: VehicleProfile?) {
        var shouldBeActive = vehicle == nil ? (vehicles.isEmpty || draft.isActive) : draft.isActive

        // Never let a normal edit leave every vehicle inactive: if this is the only currently
        // active vehicle and the edit would turn it off, keep it active instead. Zero active
        // vehicles hides every reminder under the Reminders tab's default filter, so this
        // invariant is enforced here regardless of what AddEditVehicleView's toggle shows —
        // that view surfaces the matching explanation, but this is the actual guarantee.
        if let vehicle, VehicleActivation.shouldKeepActive(
            editedVehicleIsActive: vehicle.isActive,
            requestedActive: shouldBeActive,
            anyOtherVehicleIsActive: vehicles.contains(where: { $0.persistentModelID != vehicle.persistentModelID && $0.isActive })
        ) {
            shouldBeActive = true
        }

        if shouldBeActive {
            clearActiveFlag(except: vehicle)
        }

        if let vehicle {
            let oldNickname = vehicle.nickname
            vehicle.nickname = draft.nickname
            vehicle.year = draft.year
            vehicle.make = draft.make
            vehicle.model = draft.model
            vehicle.trim = draft.trim
            vehicle.tankSizeGallons = draft.tankSizeGallons
            // Routine editing must never lower the odometer — AddEditVehicleView disables Save
            // while the entered value is a regression, but this is the actual guarantee: it
            // holds even if that UI check is ever bypassed or stale.
            vehicle.currentOdometer = VehicleOdometerPolicy.resolvedOdometerForRoutineEdit(
                existing: vehicle.currentOdometer,
                requested: draft.currentOdometer
            )
            // Saving through the Edit Vehicle form always transitions the vehicle to the current
            // preference semantics — even if the resulting value equals what the legacy field
            // already held (see VehicleProfile.calculatorPreferenceSemanticsVersion). The legacy
            // default*/gasEthanolPercent fields are intentionally left untouched below: they are
            // frozen, unread compatibility columns from here on — see VehicleProfile.swift.
            vehicle.preferredEthanolTargetPercent = draft.preferredEthanolTargetPercent
            vehicle.calculatorPreferenceSemanticsVersion = VehiclePreferenceSemantics.current
            vehicle.requiredOctane = draft.requiredOctane
            vehicle.isFlexFuel = draft.isFlexFuel
            vehicle.isActive = shouldBeActive
            vehicle.vehiclePhotoData = draft.vehiclePhotoData
            vehicle.updatedAt = .now
            if oldNickname != draft.nickname, !oldNickname.isEmpty {
                propagateVehicleRename(from: oldNickname, to: draft.nickname)
            }
        } else {
            // Legacy default*/gasEthanolPercent fields are intentionally omitted here — they
            // take VehicleProfile's own persistence-compatible defaults and are never read as a
            // preference for a new-semantics vehicle. See VehicleProfile.swift.
            let newVehicle = VehicleProfile(
                nickname: draft.nickname,
                year: draft.year,
                make: draft.make,
                model: draft.model,
                trim: draft.trim,
                tankSizeGallons: draft.tankSizeGallons,
                currentOdometer: draft.currentOdometer,
                requiredOctane: draft.requiredOctane,
                isFlexFuel: draft.isFlexFuel,
                isActive: shouldBeActive,
                vehiclePhotoData: draft.vehiclePhotoData,
                createdAt: .now,
                updatedAt: .now,
                preferredEthanolTargetPercent: draft.preferredEthanolTargetPercent,
                calculatorPreferenceSemanticsVersion: VehiclePreferenceSemantics.current
            )
            modelContext.insert(newVehicle)
        }

        do {
            try modelContext.save()
            AppHaptics.success()
        } catch {
            #if DEBUG
            print("[85Blends] GarageView: vehicle save failed:", error)
            #endif
            saveErrorMessage = "Couldn't save changes. Please try again."
        }
    }

    private func setActiveVehicle(_ vehicle: VehicleProfile) {
        clearActiveFlag(except: vehicle)
        vehicle.isActive = true
        vehicle.updatedAt = .now
        do {
            try modelContext.save()
            AppHaptics.selection()
        } catch {
            #if DEBUG
            print("[85Blends] GarageView: set active vehicle save failed:", error)
            #endif
            saveErrorMessage = "Couldn't save changes. Please try again."
        }
    }

    private func clearActiveFlag(except vehicle: VehicleProfile?) {
        for otherVehicle in vehicles where otherVehicle.persistentModelID != vehicle?.persistentModelID {
            otherVehicle.isActive = false
            otherVehicle.updatedAt = .now
        }
    }

    private func propagateVehicleRename(from oldName: String, to newName: String) {
        let fuelDescriptor = FetchDescriptor<FuelLogEntry>(
            predicate: #Predicate { $0.vehicleName == oldName }
        )
        if let logs = try? modelContext.fetch(fuelDescriptor) {
            for log in logs { log.vehicleName = newName }
        }

        let reminderDescriptor = FetchDescriptor<MaintenanceReminder>(
            predicate: #Predicate { $0.vehicleName == oldName }
        )
        if let reminders = try? modelContext.fetch(reminderDescriptor) {
            for reminder in reminders { reminder.vehicleName = newName }
        }

        let completionDescriptor = FetchDescriptor<ReminderCompletionRecord>(
            predicate: #Predicate { $0.vehicleName == oldName }
        )
        if let records = try? modelContext.fetch(completionDescriptor) {
            for record in records { record.vehicleName = newName }
        }
    }

    private func promptDeletion(for vehicle: VehicleProfile) {
        vehiclePendingDeletion = vehicle
        deletionMessage = vehicle.isActive
            ? "Deleting the active vehicle will activate another saved vehicle if one exists."
            : "This vehicle will be removed from your garage."
    }

    private func confirmDeletion() {
        guard let vehiclePendingDeletion else {
            return
        }

        let deletedVehicleID = vehiclePendingDeletion.persistentModelID
        let wasActive = vehiclePendingDeletion.isActive

        modelContext.delete(vehiclePendingDeletion)

        if wasActive, let replacement = vehicles.first(where: { $0.persistentModelID != deletedVehicleID }) {
            replacement.isActive = true
            replacement.updatedAt = .now
        }

        do {
            try modelContext.save()
            AppHaptics.warning()
        } catch {
            #if DEBUG
            print("[85Blends] GarageView: vehicle deletion save failed:", error)
            #endif
            saveErrorMessage = "Couldn't delete vehicle. Please try again."
        }
        self.vehiclePendingDeletion = nil
    }

    private func beginOdometerUpdate(for vehicle: VehicleProfile) {
        odometerInput = String(vehicle.currentOdometer)
        odometerValidationMessage = nil
        odometerUpdateContext = ActiveOdometerUpdateContext(vehicle: vehicle)
    }

    private func dismissOdometerSheet() {
        odometerUpdateContext = nil
        odometerInput = ""
        odometerValidationMessage = nil
    }

    private func saveOdometerUpdate(for context: ActiveOdometerUpdateContext) {
        let trimmedInput = odometerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newOdometer = Int(trimmedInput) else {
            odometerValidationMessage = "Enter a valid odometer value."
            return
        }

        guard newOdometer >= context.vehicle.currentOdometer else {
            odometerValidationMessage = "New odometer cannot be lower than the current reading."
            return
        }

        context.vehicle.currentOdometer = newOdometer
        context.vehicle.updatedAt = .now
        do {
            try modelContext.save()
            AppHaptics.success()
            dismissOdometerSheet()
        } catch {
            #if DEBUG
            print("[85Blends] GarageView: odometer save failed:", error)
            #endif
            saveErrorMessage = "Couldn't save odometer. Please try again."
        }
    }
}

#Preview {
    GarageView()
        .modelContainer(for: VehicleProfile.self, inMemory: true)
}

private struct ActiveVehicleCard: View {
    let vehicle: VehicleProfile
    let editAction: () -> Void
    let odometerAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let photo = vehicle.uiImage {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack {
                HStack(spacing: 10) {
                    VehicleThumbnail(vehicle: vehicle, size: CGSize(width: 38, height: 38), accentColor: AppTheme.Colors.primaryGreen)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active Vehicle")
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text("Used for calculator defaults and quick logging.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Spacer()

                Text("ACTIVE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppTheme.Colors.accentGreen.opacity(0.22))
                    .clipShape(Capsule())
            }

            VehicleSummary(vehicle: vehicle)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    activeVehicleActionButton(title: "Edit Active Vehicle", action: editAction)
                    activeVehicleActionButton(title: "Update Odometer", action: odometerAction)
                }

                VStack(spacing: 10) {
                    activeVehicleActionButton(title: "Edit Active Vehicle", action: editAction)
                    activeVehicleActionButton(title: "Update Odometer", action: odometerAction)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.accentGreen.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func activeVehicleActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct EmptyGarageCard: View {
    let hasSavedVehicles: Bool

    var body: some View {
        if hasSavedVehicles {
            // Vehicles exist, but none is flagged active (restored/synced data, or an edge case
            // that predates this app version) — never tell the user to add a vehicle they
            // already have.
            EmptyStateView(
                title: "No Active Vehicle",
                message: "No active vehicle is selected. Edit a vehicle below and set it as active.",
                systemImage: "car.circle"
            )
        } else {
            EmptyStateView(
                title: "No Active Vehicle",
                message: "Add your first vehicle to personalize blends, reminders, and At the Pump mode.",
                systemImage: "car.circle"
            )
        }
    }
}

private struct EmptySavedVehiclesCard: View {
    var body: some View {
        EmptyStateView(
            title: "No Vehicles Yet",
            message: "Tap Add Vehicle above to save your tank size, ethanol targets, and calculator defaults.",
            systemImage: "car.fill"
        )
    }
}

private struct VehicleRowCard: View {
    let vehicle: VehicleProfile
    let setActiveAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VehicleThumbnail(
                    vehicle: vehicle,
                    size: CGSize(width: 64, height: 64),
                    accentColor: vehicle.isActive ? AppTheme.Colors.primaryGreen : AppTheme.Colors.stationYellow
                )

                VehicleSummary(vehicle: vehicle)

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: setActiveAction) {
                    Text(vehicle.isActive ? "Active" : "Set Active")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(vehicle.isActive ? AppTheme.Colors.textPrimary : AppTheme.Colors.charcoal)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(vehicle.isActive ? AppTheme.Colors.accentGreen.opacity(0.22) : AppTheme.Colors.accentYellow)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(vehicle.isActive ? AppTheme.Colors.accentGreen : AppTheme.Colors.accentYellow, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(vehicle.isActive)

                Button(action: editAction) {
                    Text("Edit")
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

                Button(action: deleteAction) {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.95, green: 0.47, blue: 0.44))
                        .frame(width: 46, height: 46)
                        .background(AppTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppTheme.Colors.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(vehicle.isActive ? AppTheme.Colors.accentGreen.opacity(0.45) : AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct VehicleSummary: View {
    let vehicle: VehicleProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(vehicle.nickname.isEmpty ? "Unnamed Vehicle" : vehicle.nickname)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                if vehicle.isFlexFuel {
                    Text("Flex Fuel")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppTheme.Colors.accentYellow.opacity(0.28))
                        .clipShape(Capsule())
                }
            }

            Text(identityLine)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 90), spacing: 12, alignment: .leading),
                    GridItem(.flexible(minimum: 90), spacing: 12, alignment: .leading)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                summaryMetric(title: "Tank", value: vehicle.tankSizeGallons > 0 ? "\(display(vehicle.tankSizeGallons, places: 1)) gal" : "Not set")
                summaryMetric(title: "Octane", value: display(vehicle.requiredOctane, places: 0))
                summaryMetric(title: "Target", value: configuredTargetPercent.map { "E\(display($0, places: 0))" } ?? "Not set")
                summaryMetric(title: "Odometer", value: odometerText)
            }
        }
    }

    private var identityLine: String {
        [vehicle.year, vehicle.make, vehicle.model, vehicle.trim]
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    // What the user has actually CONFIGURED on this vehicle — deliberately NOT Calculator's
    // PreferredTargetResolution, which additionally falls through to an app-level preference and
    // then E30 for a vehicle with no target set. Garage answers a different question ("what is
    // configured?") than Calculator ("what should be used right now?"); a current-semantics
    // vehicle with no preference must show "Not set" here even though Calculator correctly
    // resolves an effective target for it. See GarageVehicleTargetDisplay.swift.
    private var configuredTargetPercent: Double? {
        GarageVehicleTargetDisplay.targetPercent(for: vehicle)
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func display(_ value: Double, places: Int) -> String {
        if places == 0 {
            return String(Int(value.rounded()))
        }

        return String(format: "%.\(places)f", value)
    }

    private var odometerText: String {
        "\(vehicle.currentOdometer.formatted(.number.grouping(.automatic))) mi"
    }
}

private struct VehicleThumbnail: View {
    let vehicle: VehicleProfile
    let size: CGSize
    let accentColor: Color

    var body: some View {
        Group {
            if let photo = vehicle.uiImage {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: vehicle.isActive ? "checkmark.circle.fill" : "car.fill")
                    .font(.headline)
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(accentColor.opacity(0.12))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accentColor.opacity(vehicle.uiImage == nil ? 0 : 0.25), lineWidth: vehicle.uiImage == nil ? 0 : 1)
        )
    }
}

private extension VehicleProfile {
    var uiImage: UIImage? {
        guard let vehiclePhotoData else { return nil }
        return UIImage(data: vehiclePhotoData)
    }
}

private struct VehicleSheetContext: Identifiable {
    let id = UUID()
    let vehicle: VehicleProfile?

    static let add = VehicleSheetContext(vehicle: nil)

    static func edit(_ vehicle: VehicleProfile) -> VehicleSheetContext {
        VehicleSheetContext(vehicle: vehicle)
    }
}

private struct ActiveOdometerUpdateContext: Identifiable {
    let id = UUID()
    let vehicle: VehicleProfile
}

private struct ActiveOdometerUpdateSheet: View {
    let context: ActiveOdometerUpdateContext
    @Binding var odometerInput: String
    @Binding var validationMessage: String?
    let saveAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.vehicle.nickname.isEmpty ? "Active Vehicle" : context.vehicle.nickname)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text("Quickly update the active vehicle odometer without editing the full profile.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        odometerMetric(
                            title: "Current Odometer",
                            value: "\(context.vehicle.currentOdometer.formatted(.number.grouping(.automatic))) mi"
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Text("New Odometer")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary)

                            TextField("New Odometer", text: $odometerInput)
                                .keyboardType(.numberPad)
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

                        if let validationMessage {
                            Text(validationMessage)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color(red: 0.98, green: 0.54, blue: 0.54))
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
            .navigationTitle("Update Odometer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancelAction)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveAction)
                        .foregroundStyle(AppTheme.Colors.accentGreen)
                }
            }
        }
        .keyboardDoneToolbar()
    }

    private func odometerMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
    }
}
