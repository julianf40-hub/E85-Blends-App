//
//  StationAlertsView.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — the central Price Alerts screen (More → Station Price Alerts, and the Pro section
//  of Stations). It REPLACES the "Pro feature shell" this file used to be, whose toggles were local
//  placeholders that did nothing; leaving them next to a live feature would have been a lie.
//
//  What it is: every alert the server holds for this installation, the notification card, and a way
//  into the Price Alert sheet for each. It is deliberately thin. Changing an alert and turning it off
//  happen in that sheet (PriceAlertSheet → PriceAlertsStationModel), so there is one implementation of
//  saving, validation, confirmation and error handling, and the rows here are derived from the
//  server's list (PriceAlertsOverviewModel) so a change made there shows here with no signalling.
//
//  Reached only through ProFeatureGate, so a Free user sees the locked preview instead of this screen;
//  the phases below still handle an entitlement that changes while it is open.
//
//  An alert is created from a STATION (its bell, on the Stations screen), not from here: the screen
//  says so when there are none.
//
//  ALERTS MADE BEFORE CASH AND CREDIT PRICES WERE REPORTED SEPARATELY have no payment type. Each such row carries a
//  "Payment type needed" banner with an Edit action, and the list starts with one "Choose Your Price Type" explanation.
//  Both come from the server's list (PriceAlertsOverviewModel) on every read; nothing is stored locally, and nothing is
//  written by opening this screen. Edit opens the same Price Alert sheet as a tap on the row.
//

import SwiftUI

struct StationAlertsView: View {
    @State private var model: PriceAlertsOverviewModel
    @State private var selectedTarget: PriceAlertStationTarget?

    init() {
        self.init(service: PriceAlertsService.shared)
    }

    /// For previews and tests: any service. (Two initializers rather than a default argument, which
    /// would reference the main-actor `shared` from a nonisolated default-value context.)
    init(service: any PriceAlertsServing) {
        _model = State(initialValue: PriceAlertsOverviewModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProShellHeader(
                    icon: "bell.badge.fill",
                    title: "Price Alerts",
                    subtitle: "Get notified when a station's E85 price drops or reaches your target."
                )

                content
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .navigationTitle("Station Price Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.entitlement) {
            await model.load()
        }
        .sheet(item: $selectedTarget) { target in
            PriceAlertSheet(target: target)
        }
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
                description: "Get notified when a station's E85 price drops or reaches your target price."
            )
        case .loading:
            loadingCard
        case .loadFailed(let message):
            loadFailedCard(message)
        case .empty:
            emptyContent
        case .list:
            listContent
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
                Text("Your alerts appear as soon as we've confirmed your subscription.")
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
                Text("Loading your alerts…")
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

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            refreshWarning
            EmptyStateView(
                title: "No Price Alerts yet",
                message: "Open a station on the Stations tab and tap the bell to be notified when its E85 price drops or reaches your target.",
                systemImage: "bell.slash"
            )
            PriceAlertsNotificationCard(model: model.notifications)
        }
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            refreshWarning

            if let prompt = model.paymentChoicePrompt {
                paymentChoiceExplainer(prompt)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Your alerts", subtitle: "Tap an alert to change it or turn it off.")
                ForEach(model.rows) { row in
                    alertCard(row)
                }
            }

            PriceAlertsNotificationCard(model: model.notifications)
        }
    }

    /// Said once, above the list, when any alert needs a price type. Calm, not an error.
    private func paymentChoiceExplainer(_ prompt: PriceAlertPaymentChoicePrompt) -> some View {
        AppCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(prompt.message)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// One alert: the row (a button that opens its sheet) and, for an alert with no payment type, the banner under it.
    /// The card's frame is drawn here so the banner sits INSIDE the same card as its row.
    private func alertCard(_ row: PriceAlertsOverviewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rowButton(row)
            if let banner = row.paymentChoiceBanner {
                paymentChoiceBanner(banner, row: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(row.needsPaymentChoice ? AppTheme.Colors.stationYellow.opacity(0.65) : AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// "Payment type needed" with a clear Edit action. Laid out vertically (text, then the button) so it holds at the
    /// largest Dynamic Type sizes instead of squeezing the words beside a button.
    private func paymentChoiceBanner(_ banner: PriceAlertPaymentChoiceBanner, row: PriceAlertsOverviewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .overlay(AppTheme.Colors.border)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                        .frame(width: 28)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(banner.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.stationYellow)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(banner.message)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)

                    Spacer(minLength: 0)
                }

                Button {
                    AppHaptics.selection()
                    selectedTarget = row.target
                } label: {
                    Text(banner.editTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .background(AppTheme.Colors.primaryGreen)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(banner.editAccessibilityLabel)
                .accessibilityHint(banner.editAccessibilityHint)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var refreshWarning: some View {
        if let warning = model.refreshWarning {
            VStack(alignment: .leading, spacing: 12) {
                WarningCard(
                    title: "Couldn't refresh",
                    message: "\(warning.headline). What's shown may be out of date."
                )
                SecondaryButton(title: "Refresh") {
                    Task { await model.load() }
                }
            }
        }
    }

    private func rowButton(_ row: PriceAlertsOverviewModel.Row) -> some View {
        Button {
            AppHaptics.selection()
            selectedTarget = row.target
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.target.name)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if row.target.locationLine.isEmpty == false {
                        Text(row.target.locationLine)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(row.alertTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                        .multilineTextAlignment(.leading)

                    // Which price the alert watches (and, for Price Drop, how big a drop). An alert made
                    // before payment types existed says so, in the warning colour, and the sheet it opens
                    // asks for a choice.
                    Text(row.watchText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(row.needsPaymentChoice ? AppTheme.Colors.stationYellow : AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let latestPriceText = row.latestPriceText {
                        Text(latestPriceText)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(row.accessibilityHint)
    }
}

#Preview {
    NavigationStack {
        StationAlertsView()
    }
}
