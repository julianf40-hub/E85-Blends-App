//
//  AdvancedAnalyticsView.swift
//  EightyFiveBlends
//
//  85Blends Pro feature shell. Only reached when the user has Pro (gated by ProFeatureGate).
//  Metric values are placeholders — full analytics calculations arrive in an upcoming update.
//

import SwiftUI

struct AdvancedAnalyticsView: View {
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProShellHeader(
                    icon: "chart.bar.fill",
                    title: "Fuel Analytics",
                    subtitle: "Deeper insight into your spending and blends. Live calculations arrive in an upcoming Pro update."
                )

                metricsCard
                trendsCard
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .navigationTitle("Advanced Analytics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Key metrics", subtitle: "A preview of the numbers Pro will track.")

            LazyVGrid(columns: columns, spacing: 12) {
                ProMetricTile(title: "Monthly fuel spend", systemImage: "dollarsign.circle.fill")
                ProMetricTile(title: "Cost per mile", systemImage: "road.lanes")
                ProMetricTile(title: "Avg. ethanol content", systemImage: "drop.fill")
                ProMetricTile(title: "Avg. fill-up cost", systemImage: "fuelpump.fill")
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

    private var trendsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Trends", subtitle: "Spending and blend trends over time.")

            chartPlaceholder(title: "Monthly spend")
            chartPlaceholder(title: "Ethanol content")
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

    private func chartPlaceholder(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.surface)
                .frame(height: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.title2)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                        Text("Chart coming soon")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                    }
                )
                .accessibilityLabel("\(title) chart, coming soon")
        }
    }
}

#Preview {
    NavigationStack {
        AdvancedAnalyticsView()
    }
}
