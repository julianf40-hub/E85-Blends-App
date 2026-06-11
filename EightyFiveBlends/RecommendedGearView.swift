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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                sponsorCard
                gearPreviewCard

                Text("Sponsored links and partner recommendations may help support 85Blends.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Recommended Gear")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GEAR")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text("Recommended Gear")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("Recommended E85 tools, accessories, and sponsor picks for ethanol-focused builds.")
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
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.accentYellow)
                .frame(width: 44, height: 44)
                .background(AppTheme.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("More Gear Coming Soon")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("Ethanol testers, funnels, and shop essentials will appear here as picks are finalized.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
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
