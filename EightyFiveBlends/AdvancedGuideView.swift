//
//  AdvancedGuideView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct AdvancedGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("GUIDANCE")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text("Advanced Guide")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Practical blend strategy, pump order, and cautionary notes for ethanol-focused setups.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                InfoCard(
                    title: "Use Estimates Carefully",
                    message: "These recommendations are meant to help you make cleaner fueling decisions, but final ethanol content and drivability still depend on your actual fuel, tune, and hardware."
                )

                InfoCard(
                    title: "Daily Blend Guidance",
                    message: "Lower and mid-level ethanol blends can be easier to source consistently and often provide a better balance of range, drivability, and cost for everyday use."
                )
                InfoCard(
                    title: "Performance Blend Guidance",
                    message: "Higher blends can improve knock resistance and charge cooling, but they usually require the right tune, proper fueling support, and tighter consistency from pump to pump."
                )
                InfoCard(
                    title: "Pump Order Guidance",
                    message: "When targeting a custom blend, add the calculated ethanol-heavy fuel first and then top off with gasoline so the final mix lands closer to the expected target."
                )
                WarningInfoCard(
                    title: "Safety / Warranty Warning",
                    bodyText: "Running the wrong ethanol content for your setup can cause drivability issues, lean conditions, hardware stress, or warranty disputes. Verify compatibility before use."
                )
                WarningInfoCard(
                    title: "Emissions / Legal Warning",
                    bodyText: "Fuel, tuning, and emissions rules vary by state and region. You are responsible for understanding local laws, inspection requirements, and on-road compliance."
                )
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Advanced Guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}
