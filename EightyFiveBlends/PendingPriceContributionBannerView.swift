//
//  PendingPriceContributionBannerView.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — the compact, non-modal "Did you visit X?" banner ContentView hosts via a
//  `.safeAreaInset(edge: .bottom)`, mirroring the same pattern EightyFiveBlendsApp.swift's own
//  degradedStorageBanner already uses. Deliberately never a sheet/alert/fullScreenCover — a
//  StationsView-owned sheet already showing (its own StationPriceUpdateSheet, AddEditStationView,
//  etc.) structurally covers/obscures this without either view needing to know the other exists.
//
//  Copy is deliberately neutral: no guilt ("don't let others down"), no manufactured urgency or
//  scarcity, and no reward promise — reporting a price is presented as a small, optional favor
//  to nearby drivers, nothing more.
//

import SwiftUI

struct PendingPriceContributionBannerView: View {
    let stationName: String
    let onReportPrice: () -> Void
    let onNotNow: () -> Void

    private var displayName: String {
        stationName.isEmpty ? "this station" : stationName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Did you visit \(displayName)?")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Help drivers nearby — what was the E85 price?")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                Button(action: onNotNow) {
                    Text("Not Now")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AppTheme.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not now, dismiss this station's price prompt")

                Button(action: onReportPrice) {
                    Text("Report Price")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AppTheme.Colors.primaryGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Report the E85 price for \(displayName)")
            }
        }
        .padding(16)
        .background(AppTheme.Colors.elevatedCardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}
