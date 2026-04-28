//
//  PrivacyView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PRIVACY")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text("Privacy")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }

                InfoCard(
                    title: "Local-First",
                    bodyText: "85Blends is currently designed as a local-first app. Your vehicle, fuel log, reminder, and saved station data live on your device."
                )
                InfoCard(
                    title: "No Account Required",
                    bodyText: "There is no sign-in flow, no required account, and no backend service needed to use the current version of the app."
                )
                InfoCard(
                    title: "No Backend Yet",
                    bodyText: "This version does not send your garage, blend, reminder, or station data to a remote server because there is no backend connected yet."
                )
                InfoCard(
                    title: "Personal Data",
                    bodyText: "85Blends does not sell your personal data. The current build focuses on local storage and offline-first usage."
                )
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
