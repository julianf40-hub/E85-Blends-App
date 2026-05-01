//
//  RecommendedGearView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct RecommendedGearView: View {
    @Environment(\.openURL) private var openURL

    @State private var sponsorLinkMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    sponsorCard
                    gearPreviewCard
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GEAR")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text("Recommended Gear")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("A dedicated home for future ethanol-focused tools, accessories, and sponsor-ready gear highlights.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
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

    private var gearPreviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.accentYellow)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Gear picks are coming soon")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("This tab is ready for future testers, funnels, containers, and ethanol-friendly shop essentials once the catalog is curated.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                gearPlaceholderRow(
                    title: "Testing & measuring",
                    subtitle: "Space for future ethanol-content testers and measuring tools."
                )
                gearPlaceholderRow(
                    title: "Fill-up equipment",
                    subtitle: "Reserved for containers, hoses, and practical garage accessories."
                )
                gearPlaceholderRow(
                    title: "Partner gear cards",
                    subtitle: "Ready for sponsor-safe highlights once product recommendations are finalized."
                )
            }

            Text("Find settings, legal screens, Fuel Log, and support in the More tab.")
                .font(.caption)
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

    private func gearPlaceholderRow(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
