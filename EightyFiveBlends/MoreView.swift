//
//  MoreView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData

struct MoreView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SETTINGS & SUPPORT")
                            .font(.caption.weight(.bold))
                            .tracking(1.4)
                            .foregroundStyle(AppTheme.Colors.textMuted)

                        Text("More")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text("Settings, support, and app information in one place.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }

                    VStack(spacing: 12) {
                        MoreNavigationRow(
                            title: "Fuel Log",
                            subtitle: "Review fill-up history, spend, and MPG trends.",
                            systemImage: "list.bullet.clipboard",
                            tint: AppTheme.Colors.accentGreen
                        ) {
                            FuelLogView()
                        }

                        MoreNavigationRow(
                            title: "Preferences",
                            subtitle: "Choose maps, default blend, theme, and tab visibility.",
                            systemImage: "slider.horizontal.3",
                            tint: AppTheme.Colors.accentYellow
                        ) {
                            PreferencesView()
                        }

                        MoreNavigationRow(
                            title: "Help / FAQ",
                            subtitle: "Quick answers to common ethanol and app questions.",
                            systemImage: "questionmark.circle",
                            tint: AppTheme.Colors.accentGreen
                        ) {
                            HelpFAQView()
                        }

                        MoreNavigationRow(
                            title: "Advanced Guide",
                            subtitle: "Blend strategy, pump order, and practical cautions.",
                            systemImage: "graduationcap",
                            tint: AppTheme.Colors.accentYellow
                        ) {
                            AdvancedGuideView()
                        }

                        MoreNavigationRow(
                            title: "Recommended Gear",
                            subtitle: "Coming soon: hand-picked tools and accessories for ethanol-focused setups.",
                            systemImage: "wrench.and.screwdriver",
                            tint: AppTheme.Colors.accentGreen
                        ) {
                            RecommendedGearView()
                        }

                        MoreNavigationRow(
                            title: "About",
                            subtitle: "What 85Blends is, who it is for, and sponsor info.",
                            systemImage: "info.circle",
                            tint: AppTheme.Colors.accentYellow
                        ) {
                            AboutView()
                        }

                        MoreNavigationRow(
                            title: "Privacy",
                            subtitle: "How your local-first data is handled today.",
                            systemImage: "lock.shield",
                            tint: AppTheme.Colors.accentGreen
                        ) {
                            PrivacyView()
                        }

                        MoreNavigationRow(
                            title: "Disclaimer",
                            subtitle: "Important estimation, tuning, warranty, and legal notices.",
                            systemImage: "exclamationmark.triangle",
                            tint: AppTheme.Colors.accentYellow
                        ) {
                            DisclaimerView()
                        }
                    }
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
    }
}

#Preview {
    MoreView()
        .modelContainer(for: [FuelLogEntry.self, VehicleProfile.self], inMemory: true)
}

private struct MoreNavigationRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
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
    }
}
