//
//  HelpFAQView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct HelpFAQView: View {
    private let faqs = [
        (
            question: "What is E85?",
            answer: "E85 is a high-ethanol fuel blend that can offer more knock resistance and cooling, but the actual ethanol content at the pump can vary by season and station."
        ),
        (
            question: "Why does E85 percentage vary?",
            answer: "Pump fuel labeled E85 is not always exactly 85 percent ethanol. Seasonal blending, region, and station supply can shift the actual content significantly."
        ),
        (
            question: "Is this calculator exact?",
            answer: "No. It is a practical estimate based on the information you enter. Real-world tank shape, residual fuel, and pump content can all change the final blend."
        ),
        (
            question: "Should I tune my car for ethanol?",
            answer: "Many vehicles need the correct tune and supporting hardware before running higher ethanol blends safely. Always confirm your setup before increasing ethanol content."
        ),
        (
            question: "Why should I log fill-ups?",
            answer: "Logging helps you track cost, mileage, blend consistency, and how your car responds over time so you can make better fueling decisions."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SUPPORT")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text("Help / FAQ")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Quick answers about ethanol blends, app estimates, and why logging matters.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                InfoCard(
                    title: "Before You Blend",
                    message: "Use the calculator as a practical estimate, not a guarantee. Pump ethanol content, residual fuel, and vehicle setup can all move the final result."
                )

                ForEach(faqs, id: \.question) { item in
                    InfoCard(title: item.question, message: item.answer)
                }
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Help / FAQ")
        .navigationBarTitleDisplayMode(.inline)
    }
}
