//
//  RemindersView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData

@MainActor
struct RemindersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MaintenanceReminder.updatedAt, order: .reverse)
    private var reminders: [MaintenanceReminder]
    @Query(sort: \VehicleProfile.nickname, order: .forward)
    private var vehicles: [VehicleProfile]
    @Query(filter: #Predicate<VehicleProfile> { $0.isActive == true })
    private var activeVehicles: [VehicleProfile]

    @State private var sheetReminder: MaintenanceReminder?
    @State private var isAddingReminder = false
    @State private var reminderPendingDeletion: MaintenanceReminder?

    private var activeVehicle: VehicleProfile? {
        activeVehicles.first
    }

    private var defaultVehicleName: String {
        activeVehicle?.nickname ?? vehicles.first?.nickname ?? "No Vehicle Selected"
    }

    private var vehicleNames: [String] {
        let names = vehicles.map(\.nickname).filter { $0.isEmpty == false }
        return names.isEmpty ? [defaultVehicleName] : names
    }

    private var reminderInfos: [ReminderStatusInfo] {
        reminders.map { reminder in
            ReminderStatusInfo(reminder: reminder, currentOdometer: odometer(for: reminder))
        }
    }

    private var overdueReminders: [ReminderStatusInfo] {
        reminderInfos
            .filter { $0.group == .overdue }
            .sorted(by: ReminderStatusInfo.sortOrder)
    }

    private var upcomingReminders: [ReminderStatusInfo] {
        reminderInfos
            .filter { $0.group == .upcoming }
            .sorted(by: ReminderStatusInfo.sortOrder)
    }

    private var completedReminders: [ReminderStatusInfo] {
        reminderInfos
            .filter { $0.group == .completed }
            .sorted(by: ReminderStatusInfo.sortOrder)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    if reminders.isEmpty {
                        EmptyStateView(
                            title: "No reminders yet.",
                            message: "Create maintenance reminders to stay ahead of service intervals, dates, and recurring vehicle tasks.",
                            systemImage: "bell.badge"
                        )
                    } else {
                        groupedSection(title: "Overdue", reminders: overdueReminders)
                        groupedSection(title: "Upcoming", reminders: upcomingReminders)
                        groupedSection(title: "Completed", reminders: completedReminders)
                    }
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .sheet(isPresented: $isAddingReminder) {
            AddEditReminderView(
                reminder: nil,
                vehicleNames: vehicleNames,
                defaultVehicleName: defaultVehicleName
            ) { draft in
                createReminder(from: draft)
            }
        }
        .sheet(item: $sheetReminder) { reminder in
            AddEditReminderView(
                reminder: reminder,
                vehicleNames: vehicleNames,
                defaultVehicleName: defaultVehicleName
            ) { draft in
                updateReminder(reminder, from: draft)
            }
        }
        .alert("Delete Reminder?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) {
                confirmDeletion()
            }
            Button("Cancel", role: .cancel) {
                reminderPendingDeletion = nil
            }
        } message: {
            Text("This reminder will be removed from your maintenance schedule.")
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SERVICE TRACKING")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text("Reminders")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("Stay on top of service intervals and recurring vehicle tasks.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Spacer()

            Button {
                isAddingReminder = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("Add Reminder")
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

    @ViewBuilder
    private func groupedSection(title: String, reminders: [ReminderStatusInfo]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: title,
                subtitle: sectionSubtitle(for: title)
            )

            if reminders.isEmpty {
                emptySectionCard(title: title)
            } else {
                ForEach(reminders) { info in
                    ReminderRowCard(
                        info: info,
                        completeAction: { completeReminder(info.reminder) },
                        editAction: { sheetReminder = info.reminder },
                        deleteAction: { reminderPendingDeletion = info.reminder }
                    )
                }
            }
        }
    }

    private func emptySectionCard(title: String) -> some View {
        EmptyStateView(
            title: "No \(title.lowercased()) reminders.",
            message: emptySectionMessage(for: title),
            systemImage: title == "Completed" ? "checkmark.circle" : "wrench.and.screwdriver"
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { reminderPendingDeletion != nil },
            set: { isPresented in
                if isPresented == false {
                    reminderPendingDeletion = nil
                }
            }
        )
    }

    private func odometer(for reminder: MaintenanceReminder) -> Int? {
        if reminder.vehicleName == activeVehicle?.nickname {
            return activeVehicle?.currentOdometer
        }

        return vehicles.first(where: { $0.nickname == reminder.vehicleName })?.currentOdometer
    }

    private func createReminder(from draft: ReminderDraft) {
        let reminder = MaintenanceReminder(
            vehicleName: draft.vehicleName,
            title: draft.title,
            category: draft.category,
            mileageEnabled: draft.mileageEnabled,
            dueMileage: draft.dueMileage,
            repeatMileageInterval: draft.repeatMileageInterval,
            dateEnabled: draft.dateEnabled,
            dueDate: draft.dueDate,
            repeatDateIntervalDays: draft.repeatDateIntervalDays,
            notes: draft.notes,
            isCompleted: draft.isCompleted,
            completedAt: draft.isCompleted ? .now : nil,
            createdAt: .now,
            updatedAt: .now
        )

        modelContext.insert(reminder)
        try? modelContext.save()
        AppHaptics.success()
    }

    private func updateReminder(_ reminder: MaintenanceReminder, from draft: ReminderDraft) {
        reminder.vehicleName = draft.vehicleName
        reminder.title = draft.title
        reminder.category = draft.category
        reminder.mileageEnabled = draft.mileageEnabled
        reminder.dueMileage = draft.dueMileage
        reminder.repeatMileageInterval = draft.repeatMileageInterval
        reminder.dateEnabled = draft.dateEnabled
        reminder.dueDate = draft.dueDate
        reminder.repeatDateIntervalDays = draft.repeatDateIntervalDays
        reminder.notes = draft.notes
        reminder.isCompleted = draft.isCompleted
        reminder.completedAt = draft.isCompleted ? (reminder.completedAt ?? .now) : nil
        reminder.updatedAt = .now

        try? modelContext.save()
        AppHaptics.success()
    }

    private func completeReminder(_ reminder: MaintenanceReminder) {
        let repeatsMileage = reminder.repeatMileageInterval > 0
        let repeatsDate = reminder.repeatDateIntervalDays > 0

        if repeatsMileage {
            reminder.dueMileage += reminder.repeatMileageInterval
        }

        if repeatsDate {
            reminder.dueDate = Calendar.current.date(
                byAdding: .day,
                value: reminder.repeatDateIntervalDays,
                to: reminder.dueDate
            ) ?? reminder.dueDate
        }

        if repeatsMileage || repeatsDate {
            reminder.isCompleted = false
            reminder.completedAt = nil
        } else {
            reminder.isCompleted = true
            reminder.completedAt = .now
        }

        reminder.updatedAt = .now
        try? modelContext.save()
        AppHaptics.success()
    }

    private func confirmDeletion() {
        guard let reminderPendingDeletion else { return }
        modelContext.delete(reminderPendingDeletion)
        try? modelContext.save()
        self.reminderPendingDeletion = nil
        AppHaptics.warning()
    }

    private func sectionSubtitle(for title: String) -> String {
        switch title {
        case "Overdue":
            "Items that need attention now."
        case "Upcoming":
            "Nearest mileage and date intervals first."
        case "Completed":
            "Recently finished service history."
        default:
            ""
        }
    }

    private func emptySectionMessage(for title: String) -> String {
        switch title {
        case "Overdue":
            "Your active schedule has nothing overdue right now."
        case "Upcoming":
            "Add reminders with mileage or date targets to populate this section."
        case "Completed":
            "Completed reminders will appear here after one-time tasks are finished."
        default:
            "No reminders available."
        }
    }
}

#Preview {
    RemindersView()
        .modelContainer(for: [MaintenanceReminder.self, VehicleProfile.self], inMemory: true)
}

@MainActor
private struct ReminderStatusInfo: Identifiable {
    enum Group {
        case overdue
        case upcoming
        case completed
    }

    let reminder: MaintenanceReminder
    let currentOdometer: Int?

    var id: PersistentIdentifier {
        reminder.persistentModelID
    }

    var group: Group {
        if reminder.isCompleted {
            return .completed
        }

        if isMileageOverdue || isDateOverdue {
            return .overdue
        }

        return .upcoming
    }

    var isMileageOverdue: Bool {
        reminder.mileageEnabled && currentOdometer != nil && currentOdometer! >= reminder.dueMileage
    }

    var isDateOverdue: Bool {
        reminder.dateEnabled && Calendar.current.startOfDay(for: reminder.dueDate) < Calendar.current.startOfDay(for: .now)
    }

    var statusText: String {
        switch group {
        case .completed:
            if let completedAt = reminder.completedAt {
                return "Completed \(completedAt.formatted(date: .abbreviated, time: .omitted))"
            }
            return "Completed"
        case .overdue:
            var parts: [String] = []
            if let currentOdometer, reminder.mileageEnabled {
                parts.append("\(max(currentOdometer - reminder.dueMileage, 0)) mi overdue")
            }
            if reminder.dateEnabled {
                let days = max(Calendar.current.dateComponents([.day], from: reminder.dueDate, to: .now).day ?? 0, 0)
                parts.append("\(days) day\(days == 1 ? "" : "s") overdue")
            }
            return parts.isEmpty ? "Overdue" : parts.joined(separator: " • ")
        case .upcoming:
            var parts: [String] = []
            if let currentOdometer, reminder.mileageEnabled {
                let milesRemaining = max(reminder.dueMileage - currentOdometer, 0)
                parts.append("\(milesRemaining) mi remaining")
            }
            if reminder.dateEnabled {
                let daysRemaining = max(Calendar.current.dateComponents([.day], from: .now, to: reminder.dueDate).day ?? 0, 0)
                parts.append("\(daysRemaining) day\(daysRemaining == 1 ? "" : "s") remaining")
            }
            return parts.isEmpty ? "Upcoming" : parts.joined(separator: " • ")
        }
    }

    static func sortOrder(lhs: ReminderStatusInfo, rhs: ReminderStatusInfo) -> Bool {
        switch (lhs.group, rhs.group) {
        case (.overdue, .overdue), (.upcoming, .upcoming), (.completed, .completed):
            return lhs.priorityScore < rhs.priorityScore
        case (.overdue, _):
            return true
        case (_, .overdue):
            return false
        case (.upcoming, _):
            return true
        case (_, .upcoming):
            return false
        }
    }

    private var priorityScore: Int {
        switch group {
        case .overdue:
            let mileageScore = reminder.mileageEnabled ? -(currentOdometer.map { $0 - reminder.dueMileage } ?? .max) : .max / 2
            let dateScore = reminder.dateEnabled ? -(Calendar.current.dateComponents([.day], from: reminder.dueDate, to: .now).day ?? 0) : .max / 2
            return min(mileageScore, dateScore)
        case .upcoming:
            let mileageScore = reminder.mileageEnabled ? max(reminder.dueMileage - (currentOdometer ?? reminder.dueMileage), 0) : .max / 2
            let dateScore = reminder.dateEnabled ? max(Calendar.current.dateComponents([.day], from: .now, to: reminder.dueDate).day ?? 0, 0) : .max / 2
            return min(mileageScore, dateScore)
        case .completed:
            let completedAtInterval = reminder.completedAt?.timeIntervalSince1970 ?? reminder.updatedAt.timeIntervalSince1970
            return -Int(completedAtInterval)
        }
    }
}

private struct ReminderRowCard: View {
    let info: ReminderStatusInfo
    let completeAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.reminder.title.isEmpty ? "Untitled Reminder" : info.reminder.title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary.opacity(info.group == .completed ? 0.7 : 1))

                    Text(info.reminder.vehicleName)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Spacer()

                Text(info.reminder.category)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badgeForeground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(badgeBackground)
                    .clipShape(Capsule())
            }

            Text(info.statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(statusColor)

            HStack(spacing: 18) {
                if info.reminder.mileageEnabled {
                    reminderMetric(title: "Due Mileage", value: "\(info.reminder.dueMileage)")
                }
                if info.reminder.dateEnabled {
                    reminderMetric(title: "Due Date", value: info.reminder.dueDate.formatted(date: .abbreviated, time: .omitted))
                }
            }

            if info.reminder.notes.isEmpty == false {
                Text(info.reminder.notes)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(info.group == .completed ? 0.8 : 1))
            }

            HStack(spacing: 10) {
                Button(action: completeAction) {
                    Text(info.group == .completed ? "Completed" : "Mark Complete")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(info.group == .completed ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(info.group == .completed ? AppTheme.Colors.surface : AppTheme.Colors.accentGreen.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(info.group == .completed ? AppTheme.Colors.border : AppTheme.Colors.accentGreen, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(info.group == .completed)

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
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opacity(info.group == .completed ? 0.72 : 1)
    }

    private var cardBackground: Color {
        switch info.group {
        case .overdue:
            return Color(red: 0.24, green: 0.10, blue: 0.11)
        case .upcoming, .completed:
            return AppTheme.Colors.surfaceElevated
        }
    }

    private var cardBorder: Color {
        switch info.group {
        case .overdue:
            return Color(red: 0.91, green: 0.35, blue: 0.36).opacity(0.6)
        case .upcoming:
            return AppTheme.Colors.border
        case .completed:
            return AppTheme.Colors.border
        }
    }

    private var statusColor: Color {
        switch info.group {
        case .overdue:
            return Color(red: 0.98, green: 0.54, blue: 0.54)
        case .upcoming:
            return AppTheme.Colors.accentYellow
        case .completed:
            return AppTheme.Colors.textSecondary
        }
    }

    private var badgeBackground: Color {
        switch info.group {
        case .overdue:
            return Color(red: 0.91, green: 0.35, blue: 0.36).opacity(0.2)
        case .upcoming:
            return AppTheme.Colors.accentYellow.opacity(0.24)
        case .completed:
            return AppTheme.Colors.surface
        }
    }

    private var badgeForeground: Color {
        switch info.group {
        case .overdue:
            return Color(red: 0.98, green: 0.54, blue: 0.54)
        case .upcoming:
            return AppTheme.Colors.textPrimary
        case .completed:
            return AppTheme.Colors.textSecondary
        }
    }

    private func reminderMetric(title: String, value: String) -> some View {
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
