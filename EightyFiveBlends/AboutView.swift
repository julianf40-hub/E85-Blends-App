//
//  AboutView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct AboutView: View {
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ABOUT")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text("85Blends")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Blend planning, saved stations, and local-first tracking in a cleaner OLED presentation.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                InfoCard(
                    title: "85Blends",
                    bodyText: "A local-first ethanol blend toolkit for tracking vehicles, planning mixes, saving stations, and keeping fuel history organized."
                )

                InfoCard(
                    title: "Build",
                    bodyText: versionText
                )

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(
                        title: "Changelog",
                        subtitle: "Recent product-facing updates."
                    )

                    changelogItem("Completed reminder history can now be deleted.")
                    changelogItem("Onboarding now lets users choose visible tabs.")
                    changelogItem("Saved station filter simplified into a gold toggle button.")
                    changelogItem("Reminder completion history added for recurring service.")
                    changelogItem("Saved station filter moved to top action area.")
                    changelogItem("More tab restored alongside Gear tab.")
                    changelogItem("Recommended Gear added as a main tab.")
                    changelogItem("Reminder completion confirmation and history details added.")
                    changelogItem("Garage vehicle cards now show odometer.")
                    changelogItem("Fuel Log back navigation from More fixed.")
                    changelogItem("Saved station favorites filter restored.")
                    changelogItem("Onboarding safety acknowledgements now guide users to missing items.")
                    changelogItem("Onboarding safety acknowledgment Finish button fixed.")
                    changelogItem("RVP Supply sponsor card linked.")
                    changelogItem("Sponsor section moved to More.")
                    changelogItem("Onboarding disclaimer acknowledgements added.")
                    changelogItem("Stations header fixed and duplicate live saves prevented.")
                    changelogItem("MapKit deprecation warnings cleaned up.")
                    changelogItem("Stations header layout refined.")
                    changelogItem("Station directions now open in the selected maps app.")
                    changelogItem("Stations map user-location centering fixed.")
                    changelogItem("Live nearby E85 station search connected.")
                    changelogItem("Live station service target compatibility cleaned up.")
                    changelogItem("Use My Location map centering added.")
                    changelogItem("Stations map UI polished.")
                    changelogItem("Stations now shows a real MapKit map.")
                    changelogItem("MapKit station map foundation added.")
                    changelogItem("Final polish verification before TestFlight upload.")
                    changelogItem("Stations layout decluttered for faster station access.")
                    changelogItem("Keyboard Done controls added to app inputs.")
                    changelogItem("Calculator Blend Guide made compact and collapsed by default.")
                    changelogItem("Stations UI refreshed with OLED station cards.")
                    changelogItem("Blend Guide tap-to-select interaction added.")
                    changelogItem("Stations OLED polish improvements")
                    changelogItem("2.0.1 (2) — Calculator UI polish improvements")
                    changelogItem("2.0.1 (2) — OLED visual polish inspired by the original 85Blends interface.")
                    changelogItem("Native SwiftUI rebuild")
                    changelogItem("E85 blend calculator")
                    changelogItem("Garage vehicle profiles")
                    changelogItem("Fuel log")
                    changelogItem("Maintenance reminders")
                    changelogItem("Local saved stations")
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
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func changelogItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.Colors.accentGreen)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }
}
