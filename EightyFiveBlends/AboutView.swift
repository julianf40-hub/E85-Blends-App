//
//  AboutView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct AboutView: View {
    @State private var showPreviousHighlights = false
    @State private var showAppFoundation = false

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
                    message: "A local-first ethanol blend toolkit for tracking vehicles, planning mixes, saving stations, and keeping fuel history organized."
                )

                InfoCard(
                    title: "Build",
                    message: versionText
                )

                changelogGroup(
                    title: "What's New in 2.2.1",
                    subtitle: "Recent product-facing updates.",
                    items: [
                        "Smarter Trip Planner fallback routing when E85 alone cannot complete a route.",
                        "Required gasoline-backup stops now appear directly in the Fuel Plan.",
                        "Backup gas station options now start collapsed for a cleaner results view.",
                        "E85 Required mode now stays E85-only and clearly marks unreachable routes.",
                        "Route summaries now show desired fuel, actual route mode, buffer, and risk more clearly.",
                    ]
                )

                collapsibleChangelogGroup(
                    title: "Previous Highlights",
                    isExpanded: $showPreviousHighlights,
                    items: [
                        "Added Trip Planner for Pro users with route distance, fuel range, arrival buffer, and stop planning.",
                        "Added Saved Trips so planned routes can be reopened later.",
                        "Improved station discovery, saved stations, favorites, and map handoff to Apple Maps, Google Maps, and Waze.",
                        "Added 85Blends Pro with premium planning, analytics, and station features.",
                        "Improved At the Pump mode for faster blend guidance while fueling.",
                    ]
                )

                collapsibleChangelogGroup(
                    title: "App Foundation",
                    isExpanded: $showAppFoundation,
                    items: [
                        "Native SwiftUI rebuild with OLED dark styling.",
                        "E85 blend calculator, garage profiles, fuel log, maintenance reminders, and local saved stations.",
                        "Community E85 price reporting and station freshness indicators.",
                        "iCloud sync and local-first data reliability improvements.",
                        "Light theme and accent theme polish across major screens.",
                    ]
                )

                Color.clear.frame(height: 24)
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func changelogGroup(title: String, subtitle: String? = nil, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, subtitle: subtitle)

            ForEach(items, id: \.self) { changelogItem($0) }
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

    @ViewBuilder
    private func collapsibleChangelogGroup(title: String, isExpanded: Binding<Bool>, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                AppHaptics.selection()
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(alignment: .top) {
                    SectionHeader(title: title)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .padding(.top, 2)
                }
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                ForEach(items, id: \.self) { changelogItem($0) }
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
