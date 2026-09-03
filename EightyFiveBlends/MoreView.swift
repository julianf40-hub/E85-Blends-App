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
    @AppStorage(AppPreferenceKey.appExperienceMode) private var appExperienceModeRaw = AppExperienceMode.normal.rawValue

    @State private var sponsorLinkMessage: String?
    @State private var supportContactMessage: String?

    private var appExperienceMode: AppExperienceMode {
        .resolved(from: appExperienceModeRaw)
    }

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

                        // Fuel Log is a Normal Mode feature — Simple Mode's core promise is
                        // Calculator, Stations, and streamlined Settings only.
                        if appExperienceMode == .normal {
                            MoreNavigationRow(
                                title: "Fuel Log",
                                subtitle: "Review fill-up history, spend, and MPG trends.",
                                systemImage: "list.bullet.clipboard",
                                tint: AppTheme.Colors.accentGreen
                            ) {
                                FuelLogView()
                            }
                        }

                        // Same underlying CostCalculatorView ("Compare Fuel Cost") Calculator's
                        // own entry card opens — kept here too so this existing, known route
                        // isn't removed.
                        MoreNavigationRow(
                            title: "Compare Fuel Cost",
                            subtitle: "See what different ethanol blends cost.",
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

                        // 85Blends' existing, official support address (support@85blends.app,
                        // already the contact used on 85blends.app's own Support page) — verified
                        // reachable during the 2.3.2 release-readiness correction pass; not a
                        // guessed or invented address. An action row, not a NavigationLink, since
                        // it opens Mail rather than an in-app screen — see MoreActionRow below.
                        MoreActionRow(
                            title: "Contact Support",
                            subtitle: "Email us with a question, issue, or feedback.",
                            systemImage: "envelope",
                            tint: AppTheme.Colors.accentGreen,
                            action: openSupportEmail
                        )

                        if let supportContactMessage {
                            Text(supportContactMessage)
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textMuted)
                                .padding(.horizontal, 4)
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

                    // Trip Planner, Advanced Fuel Analytics, and Station Price Alerts are
                    // Normal Mode feature navigation — not offered through the Simple Mode
                    // More screen. Nothing here is deleted; a Pro subscriber who switches back
                    // to Normal Mode sees this section again unchanged.
                    if appExperienceMode == .normal {
                        proPreviewSection
                        comingSoonSection
                    }
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
        }
    }

    // 2.3.0 UI polish pass: split out of proPreviewSection above so "current Pro features" and
    // "not built yet" are never visually adjacent under the same "Included with 85Blends Pro"
    // header — device feedback found that juxtaposition read as if purchasing today unlocks
    // these too. Both entries are placeholder shells (see AdvancedAnalyticsView/
    // StationAlertsView) — .comingSoon availability means neither shows a "PRO" badge or an
    // "Unlock 85Blends Pro" CTA (see ProFeatureGate.Availability).
    private var comingSoonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Coming Soon",
                subtitle: "Features planned for a future update."
            )

            ProFeatureGate(
                icon: "chart.bar.fill",
                title: "Advanced Fuel Analytics",
                description: "Deeper insights into blend history, MPG, and spending trends. Arrives in an upcoming Pro update.",
                availability: .comingSoon
            ) {
                AdvancedAnalyticsView()
            }

            ProFeatureGate(
                icon: "bell.badge.fill",
                title: "Station Price Alerts",
                description: "Get notified about E85 price changes. Arrives in an upcoming Pro update.",
                availability: .comingSoon
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

    // support@85blends.app is 85Blends' existing, official support address — see this row's own
    // call-site comment. The subject line is a courtesy default only; the user can change it
    // before sending, and nothing here attaches diagnostic or personal data automatically.
    private func openSupportEmail() {
        supportContactMessage = nil

        let subject = "85Blends Support"
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        guard let url = URL(string: "mailto:support@85blends.app?subject=\(encodedSubject)") else {
            supportContactMessage = "Support email link is unavailable right now."
            return
        }

        openURL(url) { accepted in
            if accepted == false {
                // Most commonly means no Mail account is configured on this device — Mail.app
                // itself still opens in that case, but openURL's completion reports `false` when
                // there's genuinely nothing that can handle a mailto: URL at all.
                supportContactMessage = "Couldn't open Mail. You can reach us at support@85blends.app."
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

// Same visual chrome as MoreNavigationRow, but performs an action (opening Mail, a URL, etc.)
// instead of pushing a NavigationLink destination — trailing "arrow.up.forward.square" instead
// of "chevron.right" signals "this leaves the app" rather than "this navigates within it".
private struct MoreActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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

                Image(systemName: "arrow.up.forward.square")
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
        .buttonStyle(.plain)
    }
}
