//
//  PriceAlertSheet.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B). The compact sheet a station's bell opens: the
//  station, the alert it has (or doesn't), the two kinds of alert to choose from, a price for "At or
//  Below", Save, the notification opt-in, and Turn Off. This file is the VIEW only — every decision
//  (what is shown, what a tap does, what is allowed while something is in flight) lives in
//  PriceAlertsStationModel, which is unit-tested; the views below read it and forward taps to it.
//
//  Built from what the app already does, not beside it: the opaque card/field/button styling and
//  keyboard "Done" of the price-report sheet, DestructiveConfirmationOverlay for the Turn Off
//  confirmation, ProFeatureLockView (and through it the one ProUpgradeView paywall) for a Free user,
//  AppHaptics for subtle feedback, and the same Open Settings call the pump-detection card uses.
//
//  WHAT THE SHEET SHOWS, BY PHASE (PriceAlertsStationModel.Phase)
//    resolvingEntitlement  "Checking your subscription…" — never the Pro card, never Free messaging
//    proRequired           the existing locked-feature card with its "Unlock 85Blends Pro" button
//    loading / loadFailed  a spinner / a plain-words error with Try Again
//    ready                 status, alert type, price, Save, notifications, Turn Off
//
//  ACCESSIBILITY. Every state is carried by words and an icon, never by colour alone (the selected
//  alert type has a check mark, its border is thicker and VoiceOver reads it as selected; errors
//  have an icon and text). Type scales with Dynamic Type (text styles, no fixed point sizes; the
//  option cards and rows grow instead of truncating). The price field has an accessible label and
//  hint, its validation message sits right under it, and the outcome of Save / Turn Off is announced.
//

import SwiftUI
import UIKit

struct PriceAlertSheet: View {
    @State private var model: PriceAlertsStationModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isPriceFieldFocused: Bool

    init(target: PriceAlertStationTarget) {
        self.init(target: target, service: PriceAlertsService.shared)
    }

    /// For previews and tests: any service. (Two initializers rather than a default argument, which
    /// would reference the main-actor `shared` from a nonisolated default-value context.)
    init(target: PriceAlertStationTarget, service: any PriceAlertsServing) {
        _model = State(initialValue: PriceAlertsStationModel(target: target, service: service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    content
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal.ignoresSafeArea())
            .navigationTitle("Price Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .disabled(model.isBusy)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isPriceFieldFocused = false }
                }
            }
        }
        .accessibilityHidden(model.isConfirmingTurnOff)
        .overlay {
            if model.isConfirmingTurnOff {
                DestructiveConfirmationOverlay(
                    title: PriceAlertsStationModel.turnOffTitle,
                    message: PriceAlertsStationModel.turnOffMessage,
                    destructiveActionTitle: PriceAlertsStationModel.turnOffActionTitle,
                    cancelAction: { model.cancelTurnOff() },
                    destructiveAction: { Task { await model.confirmTurnOff() } }
                )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.isConfirmingTurnOff)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.isBusy)
        // Loads when the sheet opens, and again if the entitlement becomes active while it is open
        // (a purchase made from the Pro card, or RevenueCat answering).
        .task(id: model.entitlement) {
            await model.load()
        }
        .onChange(of: model.announcement) { _, announcement in
            guard let announcement else { return }
            if announcement.isError {
                AppHaptics.warning()
            } else {
                AppHaptics.success()
            }
            AccessibilityNotification.Announcement(announcement.text).post()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.target.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if model.target.locationLine.isEmpty == false {
                Text(model.target.locationLine)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Content by phase

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .resolvingEntitlement:
            resolvingCard
        case .proRequired:
            ProFeatureLockView(
                icon: "bell.badge.fill",
                title: "Price Alerts",
                description: "Get notified when this station's E85 price drops or reaches your target price."
            )
        case .loading:
            loadingCard
        case .loadFailed(let message):
            loadFailedCard(message)
        case .ready:
            readyContent
        }
    }

    private var resolvingCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking your subscription…")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                Text("Price Alerts open as soon as we've confirmed your subscription.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecondaryButton(title: "Try Again") {
                    Task { await SubscriptionManager.shared.refreshProStatus() }
                }
            }
        }
    }

    private var loadingCard: some View {
        AppCard {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading your alert…")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func loadFailedCard(_ message: PriceAlertsUserMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WarningCard(title: message.headline, message: message.body)
            SecondaryButton(title: "Try Again") {
                Task { await model.load() }
            }
        }
    }

    // MARK: - The form

    @ViewBuilder
    private var readyContent: some View {
        if let warning = model.refreshWarning {
            refreshWarningCard(warning)
        }
        statusCard
        kindSection
        if model.form.showsPriceField {
            priceSection
        }
        saveSection
        PriceAlertsNotificationCard(model: model.notifications)
        if model.hasExistingAlert {
            turnOffSection
        }
    }

    private func refreshWarningCard(_ message: PriceAlertsUserMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WarningCard(
                title: "Couldn't refresh",
                message: "\(message.headline). What's shown may be out of date."
            )
            SecondaryButton(title: "Refresh") {
                Task { await model.load() }
            }
        }
    }

    private var statusCard: some View {
        AppCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.hasExistingAlert ? "bell.fill" : "bell.slash")
                    .font(.title3)
                    .foregroundStyle(model.hasExistingAlert ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textMuted)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("ALERT STATUS")
                        .font(.caption2.weight(.bold))
                        .tracking(0.9)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text(model.currentSummary.map { "On: \($0.title)" } ?? "No alert set")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.currentSummary?.detail ?? "Choose an alert type below to hear about this station.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var kindSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Alert type")
            ForEach(PriceAlertKind.allCases) { kind in
                kindOption(kind)
            }
        }
    }

    private func kindOption(_ kind: PriceAlertKind) -> some View {
        let isSelected = model.form.kind == kind
        let traits: AccessibilityTraits = isSelected ? [.isSelected] : []
        return Button {
            guard isSelected == false else { return }
            AppHaptics.selection()
            model.select(kind)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textSecondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(kind.detail)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppTheme.Colors.softGreenBackground : AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.border, lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityLabel("\(kind.title). \(kind.detail)")
        .accessibilityAddTraits(traits)
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Target price")

            HStack(spacing: 4) {
                Text("$")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .accessibilityHidden(true)

                TextField("0.00", text: $model.form.priceText)
                    .keyboardType(.decimalPad)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .focused($isPriceFieldFocused)
                    .disabled(model.isBusy)
                    .accessibilityLabel("Target price in dollars per gallon")
                    .accessibilityHint(PriceAlertPriceInput.emptyHint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            // The whole drawn box focuses the field, not only the line of text inside it (the padding
            // and the "$" would otherwise be dead space, and the line alone is under 44 pt tall).
            .contentShape(Rectangle())
            .onTapGesture { isPriceFieldFocused = true }
            .background(AppTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(model.priceFieldMessage == nil ? AppTheme.Colors.border : AppTheme.Colors.warningRed, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let message = model.priceFieldMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(red: 0.98, green: 0.54, blue: 0.54))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint = model.priceFieldHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isPriceFieldFocused = false
                Task { await model.save() }
            } label: {
                HStack(spacing: 8) {
                    if model.isSaving {
                        ProgressView()
                            .tint(AppTheme.Colors.textPrimary)
                    }
                    Text(model.saveButtonTitle)
                }
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 6)
                .background(AppTheme.Colors.primaryGreen)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(model.canSave || model.isSaving ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(model.canSave == false)
            .accessibilityHint(saveAccessibilityHint)

            if let failure = model.visibleSaveFailure {
                failureText(failure)
            } else if let notice = model.visibleSuccessNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
                    .fixedSize(horizontal: false, vertical: true)

                // An alert nobody is notified about is easy to miss: after it is created, say where
                // notifications are turned on if they are not yet.
                if model.hasExistingAlert, model.notifications.presentation.kind == .notEnabled {
                    Text("Turn on notifications below to be notified.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(model.deliveryNote)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why Save is unavailable, for VoiceOver: a dimmed button with no reason is a dead end.
    private var saveAccessibilityHint: String {
        if model.canSave || model.isBusy { return "" }
        if let message = model.priceFieldMessage { return message }
        if model.priceFieldHint != nil { return "Enter a target price first." }
        return "There are no changes to save."
    }

    private var turnOffSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(role: .destructive) {
                isPriceFieldFocused = false
                model.requestTurnOff()
            } label: {
                HStack(spacing: 8) {
                    if model.isTurningOff {
                        ProgressView()
                            .tint(AppTheme.Colors.warningRed)
                    } else {
                        Image(systemName: "bell.slash")
                    }
                    Text("Turn Off Price Alert")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.warningRed)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.Colors.warningRed.opacity(0.6), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityHint("Deletes this alert. You'll be asked to confirm.")

            if let failure = model.visibleTurnOffFailure {
                failureText(failure)
            }
        }
    }

    private func failureText(_ message: PriceAlertsUserMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(message.headline, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.bold))
            Text(message.body)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(red: 0.98, green: 0.54, blue: 0.54))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Notifications card (also used by the Price Alerts overview)

/// The "Notifications" card. Shows where notification delivery stands and offers the one action that
/// state allows. Turning notifications on is ONLY ever a tap on this card's button.
struct PriceAlertsNotificationCard: View {
    let model: PriceAlertsNotificationModel

    var body: some View {
        let presentation = model.presentation
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Notifications")

                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if presentation.kind == .enabling {
                            ProgressView()
                        } else {
                            Image(systemName: presentation.systemImage)
                                .font(.title3)
                                .foregroundStyle(iconColor(for: presentation.kind))
                        }
                    }
                    .frame(width: 28)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(presentation.title)
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(presentation.detail)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                actionButton(for: presentation.action)
            }
        }
        .onChange(of: presentation.kind) { previous, current in
            if previous == .enabling, current == .enabled {
                AppHaptics.success()
            }
        }
    }

    private func iconColor(for kind: PriceAlertsNotificationPresentation.Kind) -> Color {
        switch kind {
        case .enabled: return AppTheme.Colors.primaryGreen
        case .notEnabled, .enabling: return AppTheme.Colors.textSecondary
        case .denied, .notReady, .unavailable, .needsPro, .checkingSubscription, .retryScheduled, .failed:
            return AppTheme.Colors.stationYellow
        }
    }

    @ViewBuilder
    private func actionButton(for action: PriceAlertsNotificationPresentation.Action) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .turnOn:
            PrimaryButton(title: "Turn On Notifications") {
                AppHaptics.selection()
                Task { await model.turnOnNotifications() }
            }
        case .tryAgain:
            SecondaryButton(title: "Try Again") {
                Task { await model.turnOnNotifications() }
            }
        case .openSettings:
            SecondaryButton(title: "Open Settings") {
                openSystemSettings()
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
