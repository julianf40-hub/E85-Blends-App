//
//  MoreView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData

struct MoreView: View {
    @Environment(\.openURL) private var openURL

    @State private var sponsorLinkMessage: String?

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
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text("Settings, support, and app information in one place.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }

                    sponsorCard

                    VStack(spacing: 12) {
                        MoreNavigationRow(
                            title: "85Blends Pro",
                            subtitle: "Drive farther. Plan smarter. Fuel with confidence.",
                            systemImage: "crown.fill",
                            tint: AppTheme.Colors.stationYellow
                        ) {
                            ProUpgradeView()
                        }

                        MoreNavigationRow(
                            title: "Fuel Log",
                            subtitle: "Review fill-up history, spend, and MPG trends.",
                            systemImage: "list.bullet.clipboard",
                            tint: AppTheme.Colors.accentGreen
                        ) {
                            FuelLogView()
                        }

                        MoreNavigationRow(
                            title: "Cost Calculator",
                            subtitle: "Compare blend cost, range, and savings.",
                            systemImage: "dollarsign.circle",
                            tint: AppTheme.Colors.accentYellow
                        ) {
                            CostCalculatorView()
                        }

                        MoreNavigationRow(
                            title: "Preferences",
                            subtitle: "Choose maps, default blend, theme, and tab visibility.",
                            systemImage: "slider.horizontal.3",
                            tint: AppTheme.Colors.accentGreen
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
                            subtitle: "Hand-picked tools, accessories, and sponsor-safe gear recommendations for ethanol-focused setups.",
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

                    proPreviewSection
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
    }

    // 85Blends Pro feature entry points. Free users see locked preview cards (tapping opens
    // the paywall); Pro users get a live entry that opens the feature shell.
    private var proPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "85Blends Pro Features",
                subtitle: "Included with 85Blends Pro."
            )

            ProFeatureGate(
                icon: "map.fill",
                title: "Trip Planner",
                description: "Intelligent E85 trip planning with route-based fuel stops."
            ) {
                TripPlannerView()
            }

            ProFeatureGate(
                icon: "chart.bar.fill",
                title: "Advanced Fuel Analytics",
                description: "Deeper insights into blend history, MPG, and spending trends."
            ) {
                AdvancedAnalyticsView()
            }

            ProFeatureGate(
                icon: "bell.badge.fill",
                title: "Station Price Alerts",
                description: "Get notified when E85 prices drop at your saved stations."
            ) {
                StationAlertsView()
            }
        }
    }

    private var sponsorCard: some View {
        Button {
            openSponsorLink()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image("RVPSupplyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .padding(.horizontal, 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sponsored by RVP Supply")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Tap to visit the shop")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                if let sponsorLinkMessage {
                    Text(sponsorLinkMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.Colors.stationYellow.opacity(0.24), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func openSponsorLink() {
        sponsorLinkMessage = nil

        guard let url = URL(string: "https://rvpsupply.com") else {
            sponsorLinkMessage = "Shop link is unavailable right now."
            return
        }

        openURL(url) { accepted in
            if accepted == false {
                sponsorLinkMessage = "Unable to open the shop link right now."
            }
        }
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
                    .background(tint.opacity(0.14))
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
                    .foregroundStyle(AppTheme.Colors.textMuted)
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
