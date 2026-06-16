//
//  ProLimitBannerView.swift
//  EightyFiveBlends
//
//  Informational soft-limit nudge shown in Garage, Fuel Log, and Stations. It never blocks
//  any free functionality — tapping it simply presents the single 85Blends Pro paywall.
//

import SwiftUI

struct ProLimitBannerView: View {
    let message: String

    @State private var isShowingUpgrade = false

    var body: some View {
        Button {
            AppHaptics.selection()
            isShowingUpgrade = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "crown.fill")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.stationYellow)

                VStack(alignment: .leading, spacing: 2) {
                    Text("You're getting more out of 85Blends")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text(message)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text("View Pro")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppTheme.Colors.stationYellow.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.stationYellow.opacity(0.30), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingUpgrade) {
            NavigationStack {
                ProUpgradeView(presentationMode: .modal)
            }
        }
    }
}
