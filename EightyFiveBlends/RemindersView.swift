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
    @Query(sort: \ReminderCompletionRecord.completedAt, order: .reverse)
    private var completionRecords: [ReminderCompletionRecord]
    @Query(sort: \VehicleProfile.nickname, order: .forward)
    private var vehicles: [VehicleProfile]
    @Query(filter: #Predicate<VehicleProfile> { $0.isActive == true })
    private var activeVehicles: [VehicleProfile]

    @State private var sheetReminder: MaintenanceReminder?
    @State private var isAddingReminder = false
    @State private var reminderPendingDeletion: MaintenanceReminder?
    @State private var completionRecordPendingDeletion: ReminderCompletionRecord?
    @State private var completionContext: ReminderCompletionContext?
    @State private var completionMileageInput = ""
    @State private var completionDate = Date()
    @State private var completionMileageError: String?
    @State private var reminderFeedbackMessage: String?

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

    private var reminderTemplates: [ReminderTemplate] {
        [
            ReminderTemplate(title: "Oil Change", category: "Oil Change", mileageInterval: 5000),
            ReminderTemplate(title: "Tire Rotation", category: "Tire Rotation", mileageInterval: 7500),
            ReminderTemplate(title: "Air Filter", category: "Air Filter", mileageInterval: 15000),
            ReminderTemplate(title: "Spark Plugs", category: "Spark Plugs", mileageInterval: 30000),
            ReminderTemplate(title: "Brake Fluid", category: "Brake Fluid", mileageInterval: 25000)
        ]
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

    private var recurringCompletionRecords: [ReminderCompletionRecord] {
        completionRecords.filter { record in
            completedReminders.contains(where: { matchesCompletionRecord(record, to: $0.reminder) }) == false
        }
    }

    private var completedHistoryItems: [CompletedHistoryItem] {
        let reminderItems = completedReminders.map(CompletedHistoryItem.reminder)
        let recordItems = recurringCompletionRecords.map(CompletedHistoryItem.record)
        return (reminderItems + recordItems).sorted { lhs, rhs in
            lhs.completedAt > rhs.completedAt
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    if reminders.isEmpty {
                        ReminderTemplateCard(templates: reminderTemplates) { template in
                            createReminder(from: template)
                        }
                    }
                    if reminders.isEmpty && completionRecords.isEmpty {
                        EmptyStateView(
                            title: "No Reminders Yet",
                            message: "Track oil changes, tire rotations, and more. Tap Add Reminder or pick a Quick Start template above.",
                            systemImage: "bell.badge"
                        )
                    } else {
                        groupedSection(title: "Overdue", reminders: overdueReminders)
                        groupedSection(title: "Upcoming", reminders: upcomingReminders)
                        completedSection
                    }
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .overlay(alignment: .top) {
            if let reminderFeedbackMessage {
                feedbackBanner(text: reminderFeedbackMessage)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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
        .sheet(item: $completionContext) { context in
            ReminderCompletionSheet(
                context: context,
                completionMileageInput: $completionMileageInput,
                completionDate: $completionDate,
                validationMessage: $completionMileageError,
                confirmAction: { confirmCompletion(using: context) },
                cancelAction: dismissCompletionSheet
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
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
        .alert("Delete Completed History?", isPresented: completionRecordDeleteAlertBinding) {
            Button("Delete", role: .destructive) {
                confirmCompletionRecordDeletion()
            }
            Button("Cancel", role: .cancel) {
                completionRecordPendingDeletion = nil
            }
        } message: {
            Text("This completed history entry will be removed. The recurring reminder itself will stay intact.")
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
                        completeAction: { beginCompletion(for: info.reminder) },
                        editAction: { sheetReminder = info.reminder },
                        deleteAction: { reminderPendingDeletion = info.reminder },
                        linkOpenFailedAction: { showReminderFeedback("Couldn’t open this link.") }
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

    @ViewBuilder
    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Completed",
                subtitle: sectionSubtitle(for: "Completed")
            )

            if completedHistoryItems.isEmpty {
                emptySectionCard(title: "Completed")
            } else {
                ForEach(completedHistoryItems) { item in
                    switch item {
                    case .reminder(let info):
                        ReminderRowCard(
                            info: info,
                            completeAction: { },
                            editAction: { sheetReminder = info.reminder },
                            deleteAction: { reminderPendingDeletion = info.reminder },
                            linkOpenFailedAction: { showReminderFeedback("Couldn’t open this link.") }
                        )
                    case .record(let record):
                        ReminderCompletionRecordCard(record: record) {
                            completionRecordPendingDeletion = record
                        }
                    }
                }
            }
        }
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

    private var completionRecordDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { completionRecordPendingDeletion != nil },
            set: { isPresented in
                if isPresented == false {
                    completionRecordPendingDeletion = nil
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
            purchaseURLString: draft.purchaseLinks.first?.urlString,
            purchaseLinksJSON: MaintenanceReminder.encodePurchaseLinks(draft.purchaseLinks),
            isCompleted: draft.isCompleted,
            completedAt: draft.isCompleted ? .now : nil,
            completedMileage: nil,
            createdAt: .now,
            updatedAt: .now
        )

        modelContext.insert(reminder)
        try? modelContext.save()
        AppHaptics.success()
    }

    private func createReminder(from template: ReminderTemplate) {
        let currentOdometer = activeVehicle?.currentOdometer ?? 0
        let reminder = MaintenanceReminder(
            vehicleName: activeVehicle?.nickname ?? defaultVehicleName,
            title: template.title,
            category: template.category,
            mileageEnabled: true,
            dueMileage: currentOdometer + template.mileageInterval,
            repeatMileageInterval: template.mileageInterval,
            dateEnabled: false,
            dueDate: .now,
            repeatDateIntervalDays: 0,
            notes: "",
            isCompleted: false,
            completedAt: nil,
            completedMileage: nil,
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
        reminder.purchaseURLString = draft.purchaseLinks.first?.urlString
        reminder.purchaseLinksJSON = MaintenanceReminder.encodePurchaseLinks(draft.purchaseLinks)
        reminder.isCompleted = draft.isCompleted
        reminder.completedAt = draft.isCompleted ? (reminder.completedAt ?? .now) : nil
        reminder.completedMileage = draft.isCompleted ? reminder.completedMileage : nil
        reminder.updatedAt = .now

        try? modelContext.save()
        AppHaptics.success()
    }

    private func beginCompletion(for reminder: MaintenanceReminder) {
        let initialMileage = activeVehicle?.currentOdometer ?? reminder.dueMileage
        completionMileageInput = reminder.mileageEnabled ? String(initialMileage) : ""
        completionDate = .now
        completionMileageError = nil
        completionContext = ReminderCompletionContext(
            reminder: reminder,
            activeVehicleOdometer: activeVehicle?.currentOdometer,
            currentVehicleOdometer: odometer(for: reminder),
            initialMileage: initialMileage
        )
    }

    private func confirmCompletion(using context: ReminderCompletionContext) {
        let completionMileage = context.reminder.mileageEnabled ? validatedCompletionMileage(for: context) : nil
        guard context.reminder.mileageEnabled == false || completionMileage != nil else {
            AppHaptics.warning()
            return
        }

        completeReminder(
            context.reminder,
            completionMileage: completionMileage,
            completionDate: completionDate
        )
        dismissCompletionSheet()
    }

    private func dismissCompletionSheet() {
        completionContext = nil
        completionMileageInput = ""
        completionDate = .now
        completionMileageError = nil
    }

    private func validatedCompletionMileage(for context: ReminderCompletionContext) -> Int? {
        let trimmedMileage = completionMileageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let completionMileage = Int(trimmedMileage), completionMileage >= 0 else {
            completionMileageError = "Enter a valid completion mileage to continue."
            return nil
        }

        if let currentVehicleOdometer = context.currentVehicleOdometer, completionMileage < currentVehicleOdometer {
            completionMileageError = "Completion mileage cannot be lower than the current vehicle odometer."
            return nil
        }

        completionMileageError = nil
        return completionMileage
    }

    private func completeReminder(_ reminder: MaintenanceReminder, completionMileage: Int?, completionDate: Date) {
        let repeatsMileage = reminder.repeatMileageInterval > 0
        let repeatsDate = reminder.repeatDateIntervalDays > 0

        let completionRecord = ReminderCompletionRecord(
            reminderTitle: reminder.title,
            vehicleName: reminder.vehicleName,
            category: reminder.category,
            completedAt: completionDate,
            completedMileage: completionMileage,
            notes: reminder.notes.isEmpty ? nil : reminder.notes,
            createdAt: .now
        )
        modelContext.insert(completionRecord)

        if repeatsMileage, let completionMileage {
            reminder.dueMileage = completionMileage + reminder.repeatMileageInterval
        }

        if repeatsDate {
            reminder.dueDate = Calendar.current.date(
                byAdding: .day,
                value: reminder.repeatDateIntervalDays,
                to: completionDate
            ) ?? reminder.dueDate
        }

        if repeatsMileage || repeatsDate {
            reminder.isCompleted = false
            reminder.completedAt = completionDate
        } else {
            reminder.isCompleted = true
            reminder.completedAt = completionDate
        }

        reminder.completedMileage = completionMileage

        if let completionMileage, let activeVehicle, completionMileage > activeVehicle.currentOdometer {
            activeVehicle.currentOdometer = completionMileage
            activeVehicle.updatedAt = .now
        }

        reminder.updatedAt = .now
        try? modelContext.save()
        AppHaptics.success()
        showReminderFeedback("Reminder updated.")
    }

    private func confirmDeletion() {
        guard let reminderPendingDeletion else { return }
        modelContext.delete(reminderPendingDeletion)
        try? modelContext.save()
        self.reminderPendingDeletion = nil
        AppHaptics.warning()
    }

    private func confirmCompletionRecordDeletion() {
        guard let completionRecordPendingDeletion else { return }
        modelContext.delete(completionRecordPendingDeletion)
        try? modelContext.save()
        self.completionRecordPendingDeletion = nil
        AppHaptics.warning()
        showReminderFeedback("Completed history deleted.")
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
            "Nothing overdue right now — you're all caught up."
        case "Upcoming":
            "Add reminders with mileage or date targets to see upcoming service here."
        case "Completed":
            "Completed service history will appear here as you finish tasks."
        default:
            "No reminders available."
        }
    }

    private func matchesCompletionRecord(_ record: ReminderCompletionRecord, to reminder: MaintenanceReminder) -> Bool {
        guard let reminderCompletedAt = reminder.completedAt else {
            return false
        }

        return record.reminderTitle == reminder.title &&
            record.vehicleName == reminder.vehicleName &&
            record.category == reminder.category &&
            record.completedAt == reminderCompletedAt &&
            record.completedMileage == reminder.completedMileage
    }

    private func showReminderFeedback(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            reminderFeedbackMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeIn(duration: 0.2)) {
                if reminderFeedbackMessage == message {
                    reminderFeedbackMessage = nil
                }
            }
        }
    }

    private func feedbackBanner(text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                Capsule()
                    .stroke(AppTheme.Colors.accentGreen.opacity(0.7), lineWidth: 1)
            )
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 6)
    }
}

#Preview {
    RemindersView()
        .modelContainer(for: [MaintenanceReminder.self, ReminderCompletionRecord.self, VehicleProfile.self], inMemory: true)
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

    var lastCompletedDateText: String? {
        guard group != .completed, let completedAt = reminder.completedAt else {
            return nil
        }

        return "Last completed: \(completedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    var lastCompletedMileageText: String? {
        guard group != .completed, let completedMileage = reminder.completedMileage else {
            return nil
        }

        return "At: \(completedMileage.formatted(.number.grouping(.automatic))) mi"
    }
}

private struct ReminderRowCard: View {
    @Environment(\.openURL) private var openURL
    @State private var isShowingPurchaseLinks = false

    let info: ReminderStatusInfo
    let completeAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void
    let linkOpenFailedAction: () -> Void

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
                    reminderMetric(title: info.group == .completed ? "Completed Mileage" : "Due Mileage", value: mileageValue)
                }
                if info.reminder.dateEnabled {
                    reminderMetric(
                        title: info.group == .completed ? "Completed Date" : "Due Date",
                        value: dateValue
                    )
                }
            }

            if let lastCompletedDateText = info.lastCompletedDateText {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lastCompletedDateText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)

                    if let lastCompletedMileageText = info.lastCompletedMileageText {
                        Text(lastCompletedMileageText)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }

            if info.reminder.notes.isEmpty == false {
                Text(info.reminder.notes)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(info.group == .completed ? 0.8 : 1))
            }

            if purchaseLinks.isEmpty == false {
                Button {
                    isShowingPurchaseLinks = true
                } label: {
                    Text(purchaseLinksButtonTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AppTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.Colors.accentGreen.opacity(0.7), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show parts links for \(reminderTitle)")
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
                .accessibilityLabel(info.group == .completed ? "\(reminderTitle) completed" : "Mark \(reminderTitle) complete")

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
                .accessibilityLabel("Edit \(reminderTitle)")

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
                .accessibilityLabel("Delete \(reminderTitle)")
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
        .sheet(isPresented: $isShowingPurchaseLinks) {
            ReminderPurchaseLinksSheet(
                title: reminderTitle,
                links: purchaseLinks,
                openAction: openPurchaseLink
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var cardBackground: Color {
        switch info.group {
        case .overdue:
            return Color(red: 0.24, green: 0.10, blue: 0.11)
        case .upcoming, .completed:
            return AppTheme.Colors.surfaceElevated
        }
    }

    private var reminderTitle: String {
        info.reminder.title.isEmpty ? "Untitled Reminder" : info.reminder.title
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

    private var mileageValue: String {
        let mileage = info.group == .completed ? info.reminder.completedMileage : info.reminder.dueMileage
        guard let mileage else {
            return "Unavailable"
        }

        return "\(mileage.formatted(.number.grouping(.automatic))) mi"
    }

    private var dateValue: String {
        let date = info.group == .completed ? (info.reminder.completedAt ?? info.reminder.dueDate) : info.reminder.dueDate
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var purchaseLinks: [ReminderPurchaseLink] {
        info.reminder.purchaseLinks
    }

    private var purchaseLinksButtonTitle: String {
        guard let firstLink = purchaseLinks.first else {
            return "Parts Links"
        }

        if purchaseLinks.count == 1 {
            return firstLink.label.isEmpty ? "Parts Link" : firstLink.label
        }

        return "\(firstLink.label.isEmpty ? "Parts Links" : firstLink.label) +\(purchaseLinks.count - 1)"
    }

    private func openPurchaseLink(_ link: ReminderPurchaseLink) {
        guard let normalizedURLString = MaintenanceReminder.normalizedPurchaseURLString(from: link.urlString),
              let url = URL(string: normalizedURLString) else {
            linkOpenFailedAction()
            return
        }

        openURL(url) { accepted in
            if accepted == false {
                linkOpenFailedAction()
            }
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

private struct ReminderPurchaseLinksSheet: View {
    let title: String
    let links: [ReminderPurchaseLink]
    let openAction: (ReminderPurchaseLink) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(links) { link in
                        Button {
                            openAction(link)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(link.label.isEmpty ? "Parts Link" : link.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppTheme.Colors.textPrimary)

                                    Text(link.urlString)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.Colors.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                Image(systemName: "arrow.up.forward.app")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.Colors.accentGreen)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.Colors.surfaceElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(AppTheme.Colors.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(link.label.isEmpty ? "parts link" : link.label)")
                    }
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationTitle("Parts Links")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ReminderTemplate: Identifiable {
    let title: String
    let category: String
    let mileageInterval: Int

    var id: String {
        title
    }

    var subtitle: String {
        "Due every \(mileageInterval.formatted()) miles"
    }
}

private struct ReminderTemplateCard: View {
    let templates: [ReminderTemplate]
    let templateAction: (ReminderTemplate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Quick Start Templates",
                subtitle: "Tap any template to add it instantly."
            )

            ForEach(templates) { template in
                Button {
                    templateAction(template)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)

                            Text(template.subtitle)
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }

                        Spacer()

                        Image(systemName: "plus")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(AppTheme.Colors.accentGreen)
                            .clipShape(Circle())
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.Colors.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private enum CompletedHistoryItem: Identifiable {
    case reminder(ReminderStatusInfo)
    case record(ReminderCompletionRecord)

    var id: String {
        switch self {
        case .reminder(let info):
            return "reminder-\(info.id)"
        case .record(let record):
            return "record-\(record.persistentModelID)"
        }
    }

    var completedAt: Date {
        switch self {
        case .reminder(let info):
            return info.reminder.completedAt ?? info.reminder.updatedAt
        case .record(let record):
            return record.completedAt
        }
    }
}

private struct ReminderCompletionRecordCard: View {
    let record: ReminderCompletionRecord
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.reminderTitle.isEmpty ? "Untitled Reminder" : record.reminderTitle)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text(record.vehicleName.isEmpty ? "No Vehicle Selected" : record.vehicleName)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Spacer()

                Text(record.category)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppTheme.Colors.surface)
                    .clipShape(Capsule())

                Button(action: deleteAction) {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.95, green: 0.47, blue: 0.44))
                        .frame(width: 40, height: 40)
                        .background(AppTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.Colors.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text("Completed \(record.completedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            HStack(spacing: 18) {
                reminderMetric(title: "Completed Date", value: record.completedAt.formatted(date: .abbreviated, time: .omitted))

                if let completedMileage = record.completedMileage {
                    reminderMetric(
                        title: "Completed Mileage",
                        value: "\(completedMileage.formatted(.number.grouping(.automatic))) mi"
                    )
                }
            }

            if let notes = record.notes, notes.isEmpty == false {
                Text(notes)
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
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", role: .destructive, action: deleteAction)
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

private struct ReminderCompletionContext: Identifiable {
    let id = UUID()
    let reminder: MaintenanceReminder
    let activeVehicleOdometer: Int?
    let currentVehicleOdometer: Int?
    let initialMileage: Int
}

private struct ReminderCompletionSheet: View {
    let context: ReminderCompletionContext
    @Binding var completionMileageInput: String
    @Binding var completionDate: Date
    @Binding var validationMessage: String?
    let confirmAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.reminder.title.isEmpty ? "Untitled Reminder" : context.reminder.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text("Enter the mileage when this service was completed so 85Blends can calculate the next interval.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        if context.reminder.mileageEnabled {
                            completionMetric(
                                title: "Current Active Vehicle Odometer",
                                value: context.activeVehicleOdometer.map { "\($0.formatted(.number.grouping(.automatic))) mi" } ?? "Unavailable"
                            )
                            completionMetric(
                                title: "Due Mileage",
                                value: "\(context.reminder.dueMileage.formatted(.number.grouping(.automatic))) mi"
                            )

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Completion Mileage")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.Colors.textSecondary)

                                TextField("Completion Mileage", text: $completionMileageInput)
                                    .keyboardType(.numberPad)
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(AppTheme.Colors.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(validationMessage == nil ? AppTheme.Colors.border : Color(red: 0.91, green: 0.35, blue: 0.36), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Completion Date")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary)

                            DatePicker(
                                "Completion Date",
                                selection: $completionDate,
                                displayedComponents: .date
                            )
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .tint(AppTheme.Colors.accentGreen)
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
            .navigationTitle("Confirm Completion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancelAction)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm Completion", action: confirmAction)
                        .foregroundStyle(AppTheme.Colors.accentGreen)
                }
            }
        }
        .keyboardDoneToolbar()
    }

    private func completionMetric(title: String, value: String) -> some View {
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
