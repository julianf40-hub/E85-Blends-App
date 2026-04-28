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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sponsored by RVP Supply")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Sponsor footer reserved for launch support, brand partnerships, and future product recommendations.")
                        .font(.subheadline)
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
