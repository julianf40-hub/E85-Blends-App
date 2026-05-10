//
//  AddEditReminderView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct AddEditReminderView: View {
    @Environment(\.dismiss) private var dismiss

    let reminder: MaintenanceReminder?
    let vehicleNames: [String]
    let defaultVehicleName: String
    let onSave: (ReminderDraft) -> Void

    @State private var draft: ReminderDraft

    @MainActor
    init(
        reminder: MaintenanceReminder?,
        vehicleNames: [String],
        defaultVehicleName: String,
        onSave: @escaping (ReminderDraft) -> Void
    ) {
        self.reminder = reminder
        self.vehicleNames = vehicleNames
        self.defaultVehicleName = defaultVehicleName
        self.onSave = onSave
        _draft = State(initialValue: ReminderDraft(reminder: reminder, defaultVehicleName: defaultVehicleName))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formCard
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.Colors.charcoal)
            .navigationTitle(reminder == nil ? "Add Reminder" : "Edit Reminder")
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
                        let trimmedTitle = finalDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        finalDraft.title = trimmedTitle.isEmpty ? finalDraft.category : trimmedTitle
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
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: reminder == nil ? "New Reminder" : "Edit Reminder",
                subtitle: "Create mileage or date-based service reminders for any saved vehicle."
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Vehicle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                Picker("Vehicle", selection: $draft.vehicleName) {
                    if vehicleNames.isEmpty {
                        Text(defaultVehicleName.isEmpty ? "No Vehicle Selected" : defaultVehicleName)
                            .tag(defaultVehicleName)
                    } else {
                        ForEach(vehicleNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
                .pickerStyle(.menu)
                .tint(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            ReminderStringField(title: "Title (optional)", text: $draft.title)

            VStack(alignment: .leading, spacing: 8) {
                Text("Category")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                Picker("Category", selection: $draft.category) {
                    ForEach(ReminderDraft.categories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            ReminderToggleRow(title: "Track by Mileage", isOn: $draft.mileageEnabled)

            if draft.mileageEnabled {
                SectionHeader(
                    title: "Mileage Schedule",
                    subtitle: "Use the active vehicle odometer to flag overdue maintenance."
                )
                ReminderIntField(title: "Due Mileage", value: $draft.dueMileage)
                ReminderIntField(title: "Repeat Mileage Interval", value: $draft.repeatMileageInterval)
            }

            ReminderToggleRow(title: "Track by Date", isOn: $draft.dateEnabled)

            if draft.dateEnabled {
                SectionHeader(
                    title: "Date Schedule",
                    subtitle: "Useful for registration, insurance, and calendar-based service."
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text("Due Date")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)

                    DatePicker(
                        "Due Date",
                        selection: $draft.dueDate,
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .tint(AppTheme.Colors.accentGreen)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                ReminderIntField(title: "Repeat Date Interval Days", value: $draft.repeatDateIntervalDays)
            }

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

            purchaseLinksSection

            ReminderToggleRow(title: "Completed", isOn: $draft.isCompleted)
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

    private var purchaseLinksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Parts / Purchase Links")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                Spacer()

                Button {
                    draft.purchaseLinks.append(ReminderPurchaseLink())
                } label: {
                    Label("Add Link", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AppTheme.Colors.accentGreen.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.Colors.accentGreen, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text("Save links to the oil, spark plugs, filter, or parts you use for this reminder.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            ForEach($draft.purchaseLinks) { $link in
                ReminderPurchaseLinkRow(link: $link) {
                    draft.purchaseLinks.removeAll { $0.id == link.id }
                    if draft.purchaseLinks.isEmpty {
                        draft.purchaseLinks.append(ReminderPurchaseLink())
                    }
                }
            }
        }
    }
}

struct ReminderDraft {
    static let categories = [
        "Oil Change",
        "Tire Rotation",
        "Air Filter",
        "Spark Plugs",
        "Transmission",
        "Brake Fluid",
        "Coolant",
        "Registration",
        "Insurance",
        "Other",
    ]

    var vehicleName: String
    var title: String
    var category: String
    var mileageEnabled: Bool
    var dueMileage: Int
    var repeatMileageInterval: Int
    var dateEnabled: Bool
    var dueDate: Date
    var repeatDateIntervalDays: Int
    var notes: String
    var purchaseURLString: String
    var purchaseLinks: [ReminderPurchaseLink]
    var isCompleted: Bool

    @MainActor
    init(reminder: MaintenanceReminder?, defaultVehicleName: String) {
        vehicleName = reminder?.vehicleName ?? defaultVehicleName
        title = reminder?.title ?? ""
        category = reminder?.category.isEmpty == false ? reminder?.category ?? "Oil Change" : "Oil Change"
        mileageEnabled = reminder?.mileageEnabled ?? true
        dueMileage = reminder?.dueMileage ?? 0
        repeatMileageInterval = reminder?.repeatMileageInterval ?? 0
        dateEnabled = reminder?.dateEnabled ?? false
        dueDate = reminder?.dueDate ?? .now
        repeatDateIntervalDays = reminder?.repeatDateIntervalDays ?? 0
        notes = reminder?.notes ?? ""
        purchaseURLString = reminder?.purchaseURLString ?? ""
        let links = reminder?.purchaseLinks ?? []
        purchaseLinks = links.isEmpty ? [ReminderPurchaseLink()] : links
        isCompleted = reminder?.isCompleted ?? false
    }

    static func normalizedPurchaseURLString(from value: String) -> String? {
        MaintenanceReminder.normalizedPurchaseURLString(from: value)
    }

    mutating func normalizeForSave() {
        dueMileage = max(dueMileage, 0)
        repeatMileageInterval = max(repeatMileageInterval, 0)
        repeatDateIntervalDays = max(repeatDateIntervalDays, 0)
        purchaseLinks = MaintenanceReminder.normalizedPurchaseLinks(purchaseLinks)
        purchaseURLString = purchaseLinks.first?.urlString ?? ""
    }
}

private struct ReminderPurchaseLinkRow: View {
    @Binding var link: ReminderPurchaseLink
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Store / Label")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)

                    TextField("Amazon, AutoZone, O’Reilly, RockAuto", text: $link.label)
                        .textInputAutocapitalization(.words)
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

                Button(action: deleteAction) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color(red: 0.95, green: 0.47, blue: 0.44))
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel("Remove purchase link")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("URL")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                TextField("https://…", text: $link.urlString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
        .padding(14)
        .background(AppTheme.Colors.surface.opacity(0.45))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ReminderStringField: View {
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

private struct ReminderIntField: View {
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

private struct ReminderToggleRow: View {
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
