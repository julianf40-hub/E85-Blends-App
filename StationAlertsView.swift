//
//  StationAlertsView.swift
//  EightyFiveBlends
//
//  85Blends Pro feature shell. Only reached when the user has Pro (gated by ProFeatureGate).
//  Toggles are local placeholders — alert delivery is wired up in an upcoming Pro update.
//

import SwiftUI

struct StationAlertsView: View {
    // Local-only placeholder state. Persisted preferences + real notifications arrive later.
    @State private var favoriteStationAlerts = true
    @State private var priceDropAlerts = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProShellHeader(
                    icon: "bell.badge.fill",
                    title: "Price Alerts",
                    subtitle: "Stay on top of E85 prices. Alert delivery arrives in an upcoming Pro update."
                )

                alertTypesCard
                recentlyUpdatedCard
                notificationPreferencesCard
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .navigationTitle("Station Price Alerts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var alertTypesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Alerts")

            placeholderToggle(
                title: "Favorite station alerts",
                detail: "Notify me about prices at my favorite stations.",
                isOn: $favoriteStationAlerts
            )

            placeholderToggle(
                title: "Price drop alerts",
                detail: "Notify me when E85 prices drop near me.",
                isOn: $priceDropAlerts
            )
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

    private var recentlyUpdatedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recently updated prices", subtitle: "Stations with fresh E85 prices will appear here.")
            EmptyStateView(
                title: "Nothing new yet",
                message: "Once alerts are live, recently updated station prices will show up here.",
                systemImage: "clock.arrow.circlepath"
            )
        }
    }

    private var notificationPreferencesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Notification preferences")
            ProShellRow(
                icon: "app.badge",
                title: "Delivery & quiet hours",
                detail: "Choose how and when alerts are delivered.",
                badge: "Coming soon"
            )
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

    private func placeholderToggle(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(AppTheme.Colors.primaryGreen)
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        StationAlertsView()
    }
}
