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
    @State private var completionRecordDeletionContext: CompletionRecordDeletionContext?
    @State private var completionContext: ReminderCompletionContext?
    @State private var completionMileageInput = ""
    @State private var completionDate = Date()
    @State private var completionMileageError: String?
    @State private var reminderFeedbackMessage: String?
    @State private var saveErrorMessage: String?
    @State private var vehicleFilter: ReminderVehicleFilter = .activeVehicle

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

    private var availableVehicleFilters: [ReminderVehicleFilter] {
        var options: [ReminderVehicleFilter] = [.activeVehicle, .allVehicles]
        for name in vehicles.map(\.nickname).filter({ $0.isEmpty == false }) {
            options.append(.vehicle(name))
        }
        return options
    }

    private var filteredReminderInfos: [ReminderStatusInfo] {
        reminderInfos.filter { matchesVehicleFilter($0.reminder.vehicleName) }
    }

    private func matchesVehicleFilter(_ reminderVehicleName: String) -> Bool {
        switch vehicleFilter {
        case .activeVehicle:
            if let activeVehicle {
                return reminderVehicleName == activeVehicle.nickname
            }
            // No active vehicle is selected — invalid legacy/synced data, or every vehicle was
            // deactivated outside normal UI flow (saveVehicle now prevents this going forward).
            // Never silently hide every reminder by matching against an impossible empty
            // string: fall back to showing all vehicles' reminders (isActiveVehicleFallback
            // surfaces the explanatory banner). If there are no vehicles at all, there is
            // nothing to fall back to — keep the existing "nothing matches" behavior so the
            // top-level "No Reminders Yet" / "add your first vehicle" empty state still applies.
            return VehicleActivation.shouldFallBackToAllVehicles(hasActiveVehicle: false, hasAnyVehicle: vehicles.isEmpty == false)
        case .allVehicles:
            return true
        case .vehicle(let name):
            return reminderVehicleName == name
        }
    }

    // True only when the Active Vehicle filter is silently falling back to showing every
    // vehicle's reminders because no vehicle is currently flagged active. Never true when the
    // active vehicle genuinely has zero reminders (that's a normal, honest empty state) or when
    // there are no vehicles at all (a different, already-handled empty state).
    private var isActiveVehicleFilterFallback: Bool {
        vehicleFilter == .activeVehicle &&
            VehicleActivation.shouldFallBackToAllVehicles(hasActiveVehicle: activeVehicle != nil, hasAnyVehicle: vehicles.isEmpty == false)
    }

    private var overdueReminders: [ReminderStatusInfo] {
        filteredReminderInfos
            .filter { $0.group == .overdue }
            .sorted(by: ReminderStatusInfo.sortOrder)
    }

    private var upcomingReminders: [ReminderStatusInfo] {
        filteredReminderInfos
            .filter { $0.group == .upcoming }
            .sorted(by: ReminderStatusInfo.sortOrder)
    }

    private var completedReminders: [ReminderStatusInfo] {
        filteredReminderInfos
            .filter { $0.group == .completed }
            .sorted(by: ReminderStatusInfo.sortOrder)
    }

    private var recurringCompletionRecords: [ReminderCompletionRecord] {
        completionRecords.filter { record in
            guard matchesVehicleFilter(record.vehicleName) else { return false }
            return completedReminders.contains(where: { matchesCompletionRecord(record, to: $0.reminder) }) == false
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
                    if vehicles.count > 1 {
                        vehicleFilterRow
                    }
                    if isActiveVehicleFilterFallback {
                        noActiveVehicleBanner
                    }
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
            .toolbar(.hidden, for: .navigationBar)
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
        // Background content is inert/hidden to VoiceOver while either destructive confirmation
        // below is active — see DestructiveConfirmationOverlay's own .isModal trait.
        .accessibilityHidden(reminderPendingDeletion != nil || completionRecordDeletionContext != nil)
        .overlay {
            // At most one destructive confirmation renders at a time. reminderPendingDeletion
            // (delete an active/upcoming reminder) and completionRecordDeletionContext (undo or
            // delete a completed-history entry) are set from disjoint UI actions and are never
            // both driven by the same tap, but this ordering makes the precedence deterministic
            // if that ever changed — never both, never simultaneous.
            if reminderPendingDeletion != nil {
                DestructiveConfirmationOverlay(
                    title: "Delete Reminder?",
                    message: "This reminder will be removed from your maintenance schedule.",
                    destructiveActionTitle: "Delete",
                    cancelAction: { reminderPendingDeletion = nil },
                    destructiveAction: confirmDeletion
                )
            } else if completionRecordDeletionContext != nil {
                // Title/message/action label reuse the exact same classification-driven computed
                // properties the native alert used — Undo Latest Completion? / Delete History
                // Entry? and their matching messages/action labels are untouched.
                DestructiveConfirmationOverlay(
                    title: completionRecordDeletionAlertTitle,
                    message: completionRecordDeletionMessage,
                    destructiveActionTitle: completionRecordDeletionActionLabel,
                    cancelAction: { completionRecordDeletionContext = nil },
                    destructiveAction: confirmCompletionRecordDeletion
                )
            }
        }
        .alert("Save Error", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
        .onChange(of: vehicles.map(\.nickname)) { _, names in
            if case .vehicle(let selectedName) = vehicleFilter, names.contains(selectedName) == false {
                vehicleFilter = .activeVehicle
            }
        }
    }

    private var vehicleFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(availableVehicleFilters) { option in
                    vehicleFilterChip(option)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Shown only when isActiveVehicleFilterFallback is true — never reassuring "you're all
    // caught up" phrasing here, since reminders may simply be showing from every vehicle
    // rather than genuinely being absent. No new navigation is introduced; the instruction is
    // plain text pointing at the Garage tab, which already owns vehicle-active state.
    private var noActiveVehicleBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "car.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("No active vehicle is selected.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("Showing reminders for all vehicles. Open the Garage tab and set a vehicle as active to filter this list again.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Spacer(minLength: 0)
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

    private func vehicleFilterChip(_ option: ReminderVehicleFilter) -> some View {
        let isSelected = vehicleFilter == option
        return Button {
            vehicleFilter = option
            AppHaptics.selection()
        } label: {
            Text(option.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(isSelected ? AppTheme.Colors.accentGreen.opacity(0.22) : AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? AppTheme.Colors.accentGreen : AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
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
                        // This section only ever shows overdue/upcoming (non-.completed)
                        // reminders, where this action is never used.
                        undoCompletionAction: nil,
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
                            // A one-time reminder's own latest completion never appears as a
                            // standalone history card (see recurringCompletionRecords), so this
                            // is the only entry point for undoing it. nil (no button shown) if
                            // no matching completion record can be found at all.
                            undoCompletionAction: latestOwnCompletionRecord(for: info.reminder).map { record in
                                { beginCompletionRecordDeletion(record) }
                            },
                            linkOpenFailedAction: { showReminderFeedback("Couldn’t open this link.") }
                        )
                    case .record(let record):
                        ReminderCompletionRecordCard(record: record) {
                            beginCompletionRecordDeletion(record)
                        }
                    }
                }
            }
        }
    }

    private var completionRecordDeletionAlertTitle: String {
        switch completionRecordDeletionContext?.classification {
        case .undoLatestCompletion:
            return "Undo Latest Completion?"
        case .olderCompletion, .latestButNotUndoable, nil:
            return "Delete History Entry?"
        }
    }

    private var completionRecordDeletionMessage: String {
        switch completionRecordDeletionContext?.classification {
        case .undoLatestCompletion:
            return "This will remove the service-history entry and restore the reminder to its previous schedule. Your vehicle odometer will not be lowered."
        case .olderCompletion:
            return "This is not the latest completion. Deleting it will remove only this history entry and will not change the current reminder schedule."
        case .latestButNotUndoable, nil:
            return "This older entry does not contain enough information to safely restore the reminder. Deleting it will remove the history entry only."
        }
    }

    private var completionRecordDeletionActionLabel: String {
        completionRecordDeletionContext?.classification == .undoLatestCompletion ? "Undo Completion" : "Delete Entry"
    }

    // The VehicleProfile a reminder is assigned to — not necessarily the globally active
    // vehicle. Completion logic must read and update this vehicle's odometer, never the
    // active vehicle's, when a reminder belongs to a different one.
    //
    // 85Blends 2.3.0 release-blocker fix: existing users may already have duplicate vehicle
    // nicknames saved from before VehicleNicknamePolicy prevented new ones. Resolution now fails
    // closed (nil) whenever reminder.vehicleName currently matches more than one saved vehicle,
    // instead of arbitrarily returning the first match — see VehicleNicknameResolution. A
    // zero-match name (no vehicle currently has this name) already returned nil before this
    // change and still does; only the ambiguous, 2+-match case is new. This affects both this
    // function's write-path caller (completeReminder's odometer advance) and its read-path
    // callers (odometer(for:) display) identically — a wrong-vehicle write and a wrong-vehicle
    // display are the same underlying risk.
    private func vehicleProfile(for reminder: MaintenanceReminder) -> VehicleProfile? {
        VehicleNicknameResolution.uniqueMatch(nickname: reminder.vehicleName, among: vehicles)
    }

    private func odometer(for reminder: MaintenanceReminder) -> Int? {
        vehicleProfile(for: reminder)?.currentOdometer
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
            // Both fields set explicitly in init for new records; use purchaseLinks setter on existing ones.
            purchaseURLString: draft.purchaseLinks.first?.urlString,
            purchaseLinksJSON: MaintenanceReminder.encodePurchaseLinks(draft.purchaseLinks),
            // A newly-created reminder is always active. Completion — with its history record,
            // odometer advance, and recurrence math — only ever happens through the "Mark
            // Complete" pipeline (beginCompletion -> ReminderCompletionSheet -> completeReminder),
            // never through form state.
            isCompleted: false,
            completedAt: nil,
            completedMileage: nil,
            createdAt: .now,
            updatedAt: .now,
            reminderIdentifier: UUID().uuidString
        )

        modelContext.insert(reminder)
        do {
            try modelContext.save()
            AppHaptics.success()
        } catch {
            #if DEBUG
            print("[85Blends] RemindersView: reminder create failed:", error)
            #endif
            saveErrorMessage = "Couldn't save changes. Please try again."
        }
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
            updatedAt: .now,
            reminderIdentifier: UUID().uuidString
        )

        modelContext.insert(reminder)
        do {
            try modelContext.save()
            AppHaptics.success()
        } catch {
            #if DEBUG
            print("[85Blends] RemindersView: reminder from template save failed:", error)
            #endif
            saveErrorMessage = "Couldn't save changes. Please try again."
        }
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
        // Setter keeps both purchaseLinksJSON (primary) and purchaseURLString (legacy) in sync.
        reminder.purchaseLinks = draft.purchaseLinks
        // isCompleted/completedAt/completedMileage are deliberately left untouched here. An
        // ordinary edit (title, vehicle, category, notes, due values, recurrence) must never
        // mark a reminder complete, uncomplete it, or rewrite its completion metadata — only
        // the "Mark Complete" pipeline (completeReminder) may change those fields.
        reminder.updatedAt = .now

        do {
            try modelContext.save()
            AppHaptics.success()
        } catch {
            #if DEBUG
            print("[85Blends] RemindersView: reminder update save failed:", error)
            #endif
            saveErrorMessage = "Couldn't save changes. Please try again."
        }
    }

    private func beginCompletion(for reminder: MaintenanceReminder) {
        let currentVehicleOdometer = odometer(for: reminder)
        let initialMileage = currentVehicleOdometer ?? reminder.dueMileage
        completionMileageInput = reminder.mileageEnabled ? String(initialMileage) : ""
        completionDate = .now
        completionMileageError = nil
        completionContext = ReminderCompletionContext(
            reminder: reminder,
            currentVehicleOdometer: currentVehicleOdometer,
            initialMileage: initialMileage
        )
    }

    private func confirmCompletion(using context: ReminderCompletionContext) {
        // Fail closed BEFORE any mutation (odometer write, completion record insertion,
        // recurring-reminder advancement) when this completion would need to advance a uniquely
        // identified vehicle's odometer but the reminder's vehicle name currently matches more
        // than one saved vehicle — see VehicleNicknameResolution and Phase 11/12 of the
        // 2.3.0 release-blocker fix. A date-only reminder (mileageEnabled == false) never
        // attempts an odometer write, so an ambiguous nickname never blocks it — this check is
        // for AMBIGUOUS identification specifically, not every reminder with a missing vehicle.
        if context.reminder.mileageEnabled,
           VehicleNicknameResolution.isAmbiguous(nickname: context.reminder.vehicleName, among: vehicles) {
            completionMileageError = "More than one vehicle is named \u{201C}\(context.reminder.vehicleName).\u{201D} Rename one in Garage before completing this reminder."
            AppHaptics.warning()
            return
        }

        let completionMileage = context.reminder.mileageEnabled ? validatedCompletionMileage(for: context) : nil
        guard context.reminder.mileageEnabled == false || completionMileage != nil else {
            AppHaptics.warning()
            return
        }

        // The sheet's DatePicker already restricts selection to today or earlier; this is a
        // defensive backstop so a future date can never reach persistence another way.
        let safeCompletionDate = ReminderScheduling.isFutureCompletionDate(completionDate) ? Date.now : completionDate

        completeReminder(
            context.reminder,
            completionMileage: completionMileage,
            completionDate: safeCompletionDate
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
        guard let completionMileage = ReminderScheduling.validatedCompletionMileage(from: completionMileageInput) else {
            completionMileageError = "Enter a valid completion mileage to continue."
            return nil
        }

        // A completion mileage lower than the vehicle's current odometer is a valid historical
        // service entry — ReminderCompletionSheet shows a calm, non-blocking notice for it, and
        // it must never be rejected here or made to overwrite/lower the vehicle's odometer.
        completionMileageError = nil
        return completionMileage
    }

    private func completeReminder(_ reminder: MaintenanceReminder, completionMileage: Int?, completionDate: Date) {
        let repeatsMileage = reminder.repeatMileageInterval > 0
        let repeatsDate = reminder.repeatDateIntervalDays > 0

        // Self-heal: a reminder created before 2.2.2 has no stable identity yet. Assign one now,
        // the first time it's needed, rather than a bulk migration — every completion from this
        // point on can be matched back to this exact reminder unambiguously, even if another
        // reminder shares its title/vehicle/category.
        if reminder.reminderIdentifier.isEmpty {
            reminder.reminderIdentifier = UUID().uuidString
        }

        // Captured before any mutation below — this is what a later undo (deleting this
        // completion's history record) restores the reminder to.
        let priorDueMileage = reminder.dueMileage
        let priorDueDate = reminder.dueDate
        let priorIsCompleted = reminder.isCompleted
        let priorCompletedAt = reminder.completedAt
        let priorCompletedMileage = reminder.completedMileage

        if let completionMileage,
           let nextDueMileage = ReminderScheduling.nextDueMileage(
               afterCompleting: completionMileage,
               repeatMileageInterval: reminder.repeatMileageInterval
           ) {
            reminder.dueMileage = nextDueMileage
        }

        if repeatsDate {
            reminder.dueDate = ReminderScheduling.nextDueDate(
                afterCompleting: completionDate,
                repeatIntervalDays: reminder.repeatDateIntervalDays
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

        // Advance the *reminder's assigned* vehicle's odometer — never the globally active
        // vehicle when the reminder belongs to a different one — and never backward for a
        // historical completion below the current reading.
        if let completionMileage, let targetVehicle = vehicleProfile(for: reminder) {
            let advancedOdometer = ReminderScheduling.advancedOdometer(
                current: targetVehicle.currentOdometer,
                completionMileage: completionMileage
            )
            if advancedOdometer != targetVehicle.currentOdometer {
                targetVehicle.currentOdometer = advancedOdometer
                targetVehicle.updatedAt = .now
            }
        }

        reminder.updatedAt = .now

        // Built after the mutations above so resultingDueMileage/resultingDueDate/
        // resultingIsCompleted reflect the reminder's actual new state — the safety check a
        // later undo uses to confirm nothing else has changed the reminder since this
        // completion before trusting priorDueMileage/priorDueDate/priorIsCompleted.
        let completionRecord = ReminderCompletionRecord(
            reminderTitle: reminder.title,
            vehicleName: reminder.vehicleName,
            category: reminder.category,
            completedAt: completionDate,
            completedMileage: completionMileage,
            notes: reminder.notes.isEmpty ? nil : reminder.notes,
            createdAt: .now,
            reminderIdentifier: reminder.reminderIdentifier,
            priorDueMileage: priorDueMileage,
            priorDueDate: priorDueDate,
            priorIsCompleted: priorIsCompleted,
            priorCompletedAt: priorCompletedAt,
            priorCompletedMileage: priorCompletedMileage,
            resultingDueMileage: reminder.dueMileage,
            resultingDueDate: reminder.dueDate,
            resultingIsCompleted: reminder.isCompleted
        )
        modelContext.insert(completionRecord)

        do {
            try modelContext.save()
            AppHaptics.success()
            showReminderFeedback("Reminder updated.")
        } catch {
            #if DEBUG
            print("[85Blends] RemindersView: reminder completion save failed:", error)
            #endif
            saveErrorMessage = "Couldn't save changes. Please try again."
        }
    }

    private func confirmDeletion() {
        guard let reminderPendingDeletion else { return }
        modelContext.delete(reminderPendingDeletion)
        do {
            try modelContext.save()
            AppHaptics.warning()
        } catch {
            #if DEBUG
            print("[85Blends] RemindersView: reminder deletion save failed:", error)
            #endif
            saveErrorMessage = "Couldn't delete reminder. Please try again."
        }
        self.reminderPendingDeletion = nil
    }

    // The MaintenanceReminder a completion record belongs to. Uses the stable identifier when
    // the record has one (authoritative — see ReminderCompletionRecord.hasUndoMetadata);
    // otherwise falls back to the legacy title/vehicle/category match, which is best-effort and
    // only ever used to phrase confirmation copy accurately, never to justify an automatic
    // undo. Returns nil if the reminder no longer exists (e.g. it was separately deleted) —
    // undo is impossible in that case, so the record is treated as non-undoable.
    private func owningReminder(for record: ReminderCompletionRecord) -> MaintenanceReminder? {
        if record.reminderIdentifier.isEmpty == false {
            return reminders.first(where: { $0.reminderIdentifier == record.reminderIdentifier })
        }

        return reminders.first(where: {
            $0.title == record.reminderTitle &&
                $0.vehicleName == record.vehicleName &&
                $0.category == record.category
        })
    }

    // Every completion record for a given reminder, unordered. Unlike owningReminder(for:) —
    // which resolves a single record to a single reminder and must not blend match strategies —
    // this is a union of the stable-ID and legacy matches. A reminder that predates this fix can
    // have older records with no reminderIdentifier alongside newer ones that have it; using
    // only the stable-ID match would silently under-count those older siblings and could make a
    // genuinely-latest record look not-latest. The union only ever adds candidates to compare
    // against, so it can make the "is this the latest?" check more conservative (denying an
    // eligible undo) but never less — it can never manufacture a false "yes, latest" that
    // wasn't already true, so this stays safe even if the legacy portion occasionally pulls in
    // a same-titled different reminder's record.
    private func completionRecords(for reminder: MaintenanceReminder) -> [ReminderCompletionRecord] {
        var matches = completionRecords.filter {
            $0.reminderTitle == reminder.title &&
                $0.vehicleName == reminder.vehicleName &&
                $0.category == reminder.category
        }

        if reminder.reminderIdentifier.isEmpty == false {
            let matchedIDs = Set(matches.map(\.persistentModelID))
            let stableMatches = completionRecords.filter {
                $0.reminderIdentifier == reminder.reminderIdentifier && matchedIDs.contains($0.persistentModelID) == false
            }
            matches.append(contentsOf: stableMatches)
        }

        return matches
    }

    // The most recent completion record belonging to a reminder, if any. Used to give a
    // completed one-time reminder — whose own latest completion is deliberately not shown as a
    // separate history card, see recurringCompletionRecords — a way to undo that completion.
    private func latestOwnCompletionRecord(for reminder: MaintenanceReminder) -> ReminderCompletionRecord? {
        completionRecords(for: reminder).max(by: { $0.completedAt < $1.completedAt })
    }

    private func recordSnapshot(_ record: ReminderCompletionRecord) -> ReminderCompletionUndo.RecordSnapshot {
        // persistentModelID has no public stable string form guaranteed to sort meaningfully
        // across launches, but it only needs to be a deterministic, unique-per-record value for
        // the duration of this single ordering decision — String(describing:) satisfies that.
        ReminderCompletionUndo.RecordSnapshot(completedAt: record.completedAt, tiebreaker: String(describing: record.persistentModelID))
    }

    private func beginCompletionRecordDeletion(_ record: ReminderCompletionRecord) {
        guard let owningReminder = owningReminder(for: record) else {
            // The reminder this completion belonged to no longer exists — nothing to restore.
            completionRecordDeletionContext = CompletionRecordDeletionContext(
                record: record,
                owningReminder: nil,
                classification: .latestButNotUndoable
            )
            return
        }

        let siblingSnapshots = completionRecords(for: owningReminder).map(recordSnapshot)
        let candidateSnapshot = recordSnapshot(record)
        let isLatest = ReminderCompletionUndo.isLatest(candidateSnapshot, among: siblingSnapshots)
        let hasUndoMetadata = record.hasUndoMetadata
        let stateMatchesRecordedResult = hasUndoMetadata && ReminderCompletionUndo.reminderMatchesRecordedResult(
            isCompleted: owningReminder.isCompleted,
            resultingIsCompleted: record.resultingIsCompleted,
            mileageEnabled: owningReminder.mileageEnabled,
            dueMileage: owningReminder.dueMileage,
            resultingDueMileage: record.resultingDueMileage,
            dateEnabled: owningReminder.dateEnabled,
            dueDate: owningReminder.dueDate,
            resultingDueDate: record.resultingDueDate
        )

        let classification = ReminderCompletionUndo.classify(
            candidateIsLatest: isLatest,
            candidateHasUndoMetadata: hasUndoMetadata,
            reminderStateMatchesRecordedResult: stateMatchesRecordedResult
        )

        completionRecordDeletionContext = CompletionRecordDeletionContext(
            record: record,
            owningReminder: owningReminder,
            classification: classification
        )
    }

    private func confirmCompletionRecordDeletion() {
        guard let context = completionRecordDeletionContext else { return }

        // Restore and delete happen against the same in-memory ModelContext and are committed
        // by the single modelContext.save() below — the restoration is never persisted without
        // the record deletion also succeeding, or vice versa.
        if context.classification == .undoLatestCompletion, let owningReminder = context.owningReminder {
            let record = context.record
            owningReminder.dueMileage = record.priorDueMileage ?? owningReminder.dueMileage
            owningReminder.dueDate = record.priorDueDate ?? owningReminder.dueDate
            owningReminder.isCompleted = record.priorIsCompleted
            owningReminder.completedAt = record.priorCompletedAt
            owningReminder.completedMileage = record.priorCompletedMileage
            // Never lower the odometer — undoing a completion restores the reminder's schedule
            // only. A historical completion below the current odometer never advanced it in the
            // first place (see completeReminder/ReminderScheduling.advancedOdometer), so there
            // is nothing to reverse here even for that case.
            owningReminder.updatedAt = .now
        }

        modelContext.delete(context.record)

        do {
            try modelContext.save()
            AppHaptics.warning()
            showReminderFeedback(context.classification == .undoLatestCompletion ? "Completion undone." : "Completed history deleted.")
        } catch {
            #if DEBUG
            print("[85Blends] RemindersView: completion record deletion save failed:", error)
            #endif
            saveErrorMessage = context.classification == .undoLatestCompletion
                ? "Couldn't undo this completion. Please try again."
                : "Couldn't delete history. Please try again."
        }

        completionRecordDeletionContext = nil
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
        guard reminder.mileageEnabled, let odometer = currentOdometer else { return false }
        return odometer >= reminder.dueMileage
    }

    var isDateOverdue: Bool {
        reminder.dateEnabled && ReminderScheduling.isOverdue(dueDate: reminder.dueDate)
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
                let days = max(ReminderScheduling.wholeDays(from: reminder.dueDate, to: .now), 0)
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
                let daysRemaining = max(ReminderScheduling.wholeDays(from: .now, to: reminder.dueDate), 0)
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
            let dateScore = reminder.dateEnabled ? -ReminderScheduling.wholeDays(from: reminder.dueDate, to: .now) : .max / 2
            return min(mileageScore, dateScore)
        case .upcoming:
            let mileageScore = reminder.mileageEnabled ? max(reminder.dueMileage - (currentOdometer ?? reminder.dueMileage), 0) : .max / 2
            let dateScore = reminder.dateEnabled ? max(ReminderScheduling.wholeDays(from: .now, to: reminder.dueDate), 0) : .max / 2
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingPurchaseLinks = false

    let info: ReminderStatusInfo
    let completeAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void
    // Only meaningful (non-nil) when info.group == .completed: undoes this reminder's own
    // latest completion, restoring it per REM-P1-005A. nil when no matching completion record
    // exists to undo, in which case the button stays disabled exactly as it did before this
    // action existed.
    let undoCompletionAction: (() -> Void)?
    let linkOpenFailedAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.reminder.title.isEmpty ? "Untitled Reminder" : info.reminder.title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text(info.reminder.vehicleName.isEmpty ? "Unassigned" : info.reminder.vehicleName)
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
                    .foregroundStyle(AppTheme.Colors.textSecondary)
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
                Button(action: primaryAction) {
                    Text(primaryActionLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isPrimaryActionDisabled ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(isPrimaryActionDisabled ? AppTheme.Colors.surface : AppTheme.Colors.accentGreen.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(isPrimaryActionDisabled ? AppTheme.Colors.border : AppTheme.Colors.accentGreen, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(isPrimaryActionDisabled)
                .accessibilityLabel(primaryActionAccessibilityLabel)

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
        // Single opacity source for the whole card (was also separately compounded on the
        // title/notes text above, which multiplied to a much-too-faint ~0.5 effective opacity
        // in light mode — 2.3.0 UI polish pass). 0.85 keeps completed cards visually secondary
        // to Upcoming/Overdue while keeping title/vehicle/dates/category/buttons all readable.
        .opacity(info.group == .completed ? 0.85 : 1)
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

    // LIGHT-MODE CONTRAST FIX: the overdue palette below was tuned against a fixed dark
    // burgundy card — fine in Dark/OLED, where AppTheme.Colors.textPrimary/textSecondary also
    // resolve to light values, but in Light appearance those same theme colors resolve dark,
    // producing dark text on a dark card. Dark/OLED are untouched (colorScheme reports .dark
    // for both, so this always falls through to the original values); only Light gets its own
    // palette. AppTheme.Colors itself has no existing semantic light error/warning surface to
    // reuse (only warningRed, a foreground-style color), so this introduces one locally.
    private var isOverdueLight: Bool {
        info.group == .overdue && colorScheme == .light
    }

    // Deep, WCAG-checked red (contrast ratio ~5.6:1 at full opacity against the #FCEAEA card
    // background below, comfortably above the 4.5:1 AA threshold for normal text) — used for
    // every overdue red accent in Light mode (status text, category badge) so the palette reads
    // as one consistent "overdue" signal rather than several different reds.
    private static let overdueRedLight = Color(red: 0.72, green: 0.11, blue: 0.15)

    private var cardBackground: Color {
        if isOverdueLight {
            // #FCEAEA — soft pale rose, keeps the card clearly "overdue" without reading as a
            // blocking error modal.
            return Color(red: 0.988, green: 0.918, blue: 0.918)
        }
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

    // The card's primary action slot serves three purposes depending on state: complete an
    // active reminder, undo a completed one's latest completion (reusing the same slot rather
    // than adding a fourth button), or — if no completion record could be found to undo, which
    // shouldn't normally happen for a genuinely completed reminder — a disabled label exactly
    // matching this button's pre-REM-P1-005A appearance.
    private var isPrimaryActionDisabled: Bool {
        info.group == .completed && undoCompletionAction == nil
    }

    private var primaryActionLabel: String {
        if info.group != .completed { return "Mark Complete" }
        return undoCompletionAction != nil ? "Undo Completion" : "Completed"
    }

    private var primaryAction: () -> Void {
        if info.group != .completed { return completeAction }
        return undoCompletionAction ?? {}
    }

    private var primaryActionAccessibilityLabel: String {
        if info.group != .completed { return "Mark \(reminderTitle) complete" }
        return undoCompletionAction != nil ? "Undo completion for \(reminderTitle)" : "\(reminderTitle) completed"
    }

    private var cardBorder: Color {
        if isOverdueLight {
            return Self.overdueRedLight.opacity(0.85)
        }
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
        if isOverdueLight {
            return Self.overdueRedLight
        }
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
        if isOverdueLight {
            // 0.08, not the dark-mode 0.2 — badgeForeground renders AT FULL OPACITY on TOP of
            // this fill (not on the plain card background), so a lighter tint keeps the fill
            // closer to cardBackground's high luminance, preserving badgeForeground's ~4.5:1+
            // contrast against what it's actually drawn on. A higher opacity here darkens the
            // fill toward overdueRedLight itself, closing the luminance gap with the
            // already-dark foreground text and dropping contrast below the same-size-text
            // 4.5:1 AA threshold.
            return Self.overdueRedLight.opacity(0.08)
        }
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
        if isOverdueLight {
            return Self.overdueRedLight
        }
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

                    Text(record.vehicleName.isEmpty ? "Unassigned" : record.vehicleName)
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
                .accessibilityLabel("Delete completed reminder: \(record.reminderTitle.isEmpty ? "Untitled Reminder" : record.reminderTitle)")
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
    // The odometer of the vehicle this reminder is assigned to — not necessarily the globally
    // active vehicle. Always the value the sheet should display and reason about.
    let currentVehicleOdometer: Int?
    let initialMileage: Int
}

// The record pending deletion, its resolved owning reminder (nil if that reminder no longer
// exists), and the already-computed classification driving which confirmation copy and outcome
// apply. Computed once in beginCompletionRecordDeletion so the alert and the actual mutation
// always agree on the same decision.
private struct CompletionRecordDeletionContext: Identifiable {
    let id = UUID()
    let record: ReminderCompletionRecord
    let owningReminder: MaintenanceReminder?
    let classification: ReminderCompletionUndo.DeletionClassification
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
                                title: "Current Vehicle Odometer",
                                value: context.currentVehicleOdometer.map { "\($0.formatted(.number.grouping(.automatic))) mi" } ?? "Unavailable"
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
                                            .stroke(validationMessage == nil ? AppTheme.Colors.border : AppTheme.Colors.warningRed, lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            // Calm, non-blocking notice for a valid historical completion — never
                            // an error color, and never disables Confirm Completion.
                            if let historicalEntryNotice {
                                Text(historicalEntryNotice)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Completion Date")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary)

                            DatePicker(
                                "Completion Date",
                                selection: $completionDate,
                                in: ...Date(),
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
            .navigationTitle("Complete Service")
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

    // A calm, informational notice — never an error — shown when the entered mileage is a
    // valid historical completion below the reminder's assigned vehicle's current odometer.
    // Mirrors the same parsing/validity rule as RemindersView.validatedCompletionMileage so
    // this only appears once the entry is otherwise valid.
    private var historicalEntryNotice: String? {
        guard let currentVehicleOdometer = context.currentVehicleOdometer,
              let enteredMileage = ReminderScheduling.validatedCompletionMileage(from: completionMileageInput),
              enteredMileage < currentVehicleOdometer else {
            return nil
        }

        return "Historical service entry. Your current vehicle odometer will remain \(currentVehicleOdometer.formatted(.number.grouping(.automatic))) mi."
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

private enum ReminderVehicleFilter: Hashable, Identifiable {
    case activeVehicle
    case allVehicles
    case vehicle(String)

    var id: String {
        switch self {
        case .activeVehicle: return "__active__"
        case .allVehicles: return "__all__"
        case .vehicle(let name): return "vehicle:\(name)"
        }
    }

    var title: String {
        switch self {
        case .activeVehicle: return "Active Vehicle"
        case .allVehicles: return "All Vehicles"
        case .vehicle(let name): return name
        }
    }
}
