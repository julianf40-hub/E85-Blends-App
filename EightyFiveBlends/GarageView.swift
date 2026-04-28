//
//  GarageView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData

struct GarageView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VehicleProfile.createdAt, order: .forward)
    private var vehicles: [VehicleProfile]

    @State private var sheetContext: VehicleSheetContext?
    @State private var vehiclePendingDeletion: VehicleProfile?
    @State private var deletionMessage = ""

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
                            editAction: { sheetContext = .edit(activeVehicle) }
                        )
                    } else {
                        EmptyGarageCard()
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
                existingVehiclesCount: vehicles.count
            ) { draft in
                saveVehicle(from: draft, editing: context.vehicle)
            }
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
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
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

            Spacer()

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
                .background(AppTheme.Colors.accentGreen)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var savedVehiclesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Saved Vehicles",
                subtitle: "Profiles used by the calculator, reminders, and fill-up history."
            )

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
        let shouldBeActive = vehicle == nil ? (vehicles.isEmpty || draft.isActive) : draft.isActive

        if shouldBeActive {
            clearActiveFlag(except: vehicle)
        }

        if let vehicle {
            vehicle.nickname = draft.nickname
            vehicle.year = draft.year
            vehicle.make = draft.make
            vehicle.model = draft.model
            vehicle.trim = draft.trim
            vehicle.tankSizeGallons = draft.tankSizeGallons
            vehicle.currentOdometer = draft.currentOdometer
            vehicle.defaultTargetEthanolPercent = draft.defaultTargetEthanolPercent
            vehicle.defaultCurrentEthanolPercent = draft.defaultCurrentEthanolPercent
            vehicle.defaultPumpEthanolPercent = draft.defaultPumpEthanolPercent
            vehicle.gasEthanolPercent = draft.gasEthanolPercent
            vehicle.requiredOctane = draft.requiredOctane
            vehicle.isFlexFuel = draft.isFlexFuel
            vehicle.isActive = shouldBeActive
            vehicle.updatedAt = .now
        } else {
            let newVehicle = VehicleProfile(
                nickname: draft.nickname,
                year: draft.year,
                make: draft.make,
                model: draft.model,
                trim: draft.trim,
                tankSizeGallons: draft.tankSizeGallons,
                currentOdometer: draft.currentOdometer,
                defaultTargetEthanolPercent: draft.defaultTargetEthanolPercent,
                defaultCurrentEthanolPercent: draft.defaultCurrentEthanolPercent,
                defaultPumpEthanolPercent: draft.defaultPumpEthanolPercent,
                gasEthanolPercent: draft.gasEthanolPercent,
                requiredOctane: draft.requiredOctane,
                isFlexFuel: draft.isFlexFuel,
                isActive: shouldBeActive,
                createdAt: .now,
                updatedAt: .now
            )
            modelContext.insert(newVehicle)
        }

        try? modelContext.save()
        AppHaptics.success()
    }

    private func setActiveVehicle(_ vehicle: VehicleProfile) {
        clearActiveFlag(except: vehicle)
        vehicle.isActive = true
        vehicle.updatedAt = .now
        try? modelContext.save()
        AppHaptics.selection()
    }

    private func clearActiveFlag(except vehicle: VehicleProfile?) {
        for otherVehicle in vehicles where otherVehicle.persistentModelID != vehicle?.persistentModelID {
            otherVehicle.isActive = false
            otherVehicle.updatedAt = .now
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

        try? modelContext.save()
        self.vehiclePendingDeletion = nil
        AppHaptics.warning()
    }
}

#Preview {
    GarageView()
        .modelContainer(for: VehicleProfile.self, inMemory: true)
}

private struct ActiveVehicleCard: View {
    let vehicle: VehicleProfile
    let editAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "car.fill")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                        .frame(width: 38, height: 38)
                        .background(AppTheme.Colors.primaryGreen.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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

            Button(action: editAction) {
                Text("Edit Active Vehicle")
                    .font(.subheadline.weight(.semibold))
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
}

private struct EmptyGarageCard: View {
    var body: some View {
        EmptyStateView(
            title: "No Active Vehicle",
            message: "Add your first vehicle to unlock calculator auto-fill and active blend defaults.",
            systemImage: "car.circle"
        )
    }
}

private struct EmptySavedVehiclesCard: View {
    var body: some View {
        EmptyStateView(
            title: "No vehicles saved yet.",
            message: "Use Add Vehicle to create a garage profile with your fuel and blend defaults.",
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
                Image(systemName: vehicle.isActive ? "checkmark.circle.fill" : "car.fill")
                    .font(.headline)
                    .foregroundStyle(vehicle.isActive ? AppTheme.Colors.primaryGreen : AppTheme.Colors.stationYellow)
                    .frame(width: 40, height: 40)
                    .background((vehicle.isActive ? AppTheme.Colors.primaryGreen : AppTheme.Colors.stationYellow).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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

            HStack(spacing: 18) {
                summaryMetric(title: "Tank", value: "\(display(vehicle.tankSizeGallons, places: 1)) gal")
                summaryMetric(title: "Octane", value: display(vehicle.requiredOctane, places: 0))
                summaryMetric(title: "Target", value: "E\(display(vehicle.defaultTargetEthanolPercent, places: 0))")
            }
        }
    }

    private var identityLine: String {
        [vehicle.year, vehicle.make, vehicle.model, vehicle.trim]
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
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
    }

    private func display(_ value: Double, places: Int) -> String {
        if places == 0 {
            return String(Int(value.rounded()))
        }

        return String(format: "%.\(places)f", value)
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
