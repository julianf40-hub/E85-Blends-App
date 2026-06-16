//
//  TripPlannerView.swift
//  EightyFiveBlends
//
//  85Blends Pro feature shell. Only reached when the user has Pro (gated by ProFeatureGate);
//  this is a placeholder for the upcoming intelligent E85 trip planning experience.
//

import SwiftUI

struct TripPlannerView: View {
    private let capabilities: [(icon: String, title: String, detail: String)] = [
        ("map.fill",                 "Route planning",      "Map an E85 route from your start to your destination."),
        ("fuelpump.fill",            "Intelligent fuel stops", "Recommended E85 stops timed to your tank and range."),
        ("gauge.with.dots.needle.67percent", "Range estimation", "Estimate range per leg from your blend and vehicle."),
        ("arrow.triangle.2.circlepath", "Backup stations",  "Fallback E85 options if your planned stop is closed."),
        ("bookmark.fill",            "Saved trips",         "Save and reopen routes you drive often."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProShellHeader(
                    icon: "map.fill",
                    title: "Trip Planner",
                    subtitle: "Plan E85 routes with confidence. Full planning arrives in an upcoming Pro update."
                )

                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "What's coming")
                    ForEach(capabilities, id: \.title) { item in
                        ProShellRow(icon: item.icon, title: item.title, detail: item.detail)
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

                savedTripsCard
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .navigationTitle("Trip Planner")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var savedTripsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Saved trips", subtitle: "Your saved routes will appear here.")
            EmptyStateView(
                title: "No saved trips yet",
                message: "Once trip planning is live, routes you save will show up here for quick access.",
                systemImage: "bookmark"
            )
        }
    }
}

/// Shared header for Pro feature shells — large icon, title, and a short description.
struct ProShellHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(.title, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                ProBadge()
            }

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    NavigationStack {
        TripPlannerView()
    }
}
