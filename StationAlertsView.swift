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

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Your alerts", subtitle: "Tap an alert to change it or turn it off.")
                ForEach(model.rows) { row in
                    rowButton(row)
                }
            }

            PriceAlertsNotificationCard(model: model.notifications)
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
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Opens this alert so you can change it or turn it off.")
    }
}

#Preview {
    NavigationStack {
        StationAlertsView()
    }
}
