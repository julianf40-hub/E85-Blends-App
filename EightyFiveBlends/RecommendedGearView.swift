//
//  RecommendedGearView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct RecommendedGearView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("GEAR")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text("Recommended Gear")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }

                InfoCard(
                    title: "Recommended Gear",
                    bodyText: "Coming soon. This section will highlight useful ethanol-focused testers, containers, and accessories once curated recommendations are ready."
                )
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Recommended Gear")
        .navigationBarTitleDisplayMode(.inline)
    }
}
