//
//  VehicleLimitUpsellView.swift
//  EightyFiveBlends
//
//  A compact, purpose-built explanation for why "Add Vehicle" was blocked, replacing a plain
//  system .alert whose translucency/contrast made it noticeably harder to read than the rest of
//  the app. Presented as a small, content-sized sheet — a quick explanation, not another
//  paywall. Tapping through dismisses itself and hands off to the app's single existing Pro
//  paywall (ProUpgradeView) via the onUpgrade callback; this view never talks to StoreKit or
//  SubscriptionManager directly. Purely presentational — VehicleCreationPolicy's Free/Pro
//  entitlement logic is entirely unaffected by this file.
//

import SwiftUI

struct VehicleLimitUpsellView: View {
    @Environment(\.dismiss) private var dismiss

    /// Passed in rather than read from SubscriptionManager directly, so this view stays a pure
    /// presentation component with no entitlement logic of its own — GarageView remains the one
    /// place that decides when to show it.
    let freeLimit: Int
    let onUpgrade: () -> Void

    // Sized to its own content rather than a fixed system detent (.medium), so the sheet reads
    // as a quick, compact explanation rather than a half-screen presentation with empty space
    // below short content. Measured via GeometryReader + PreferenceKey (below); the ScrollView
    // wrapper is a safety net so nothing clips if a measurement is briefly stale (e.g. the very
    // first render frame) or if extreme Dynamic Type ever makes the content taller than expected.
    @State private var measuredContentHeight: CGFloat = 0
    private let fallbackHeight: CGFloat = 380

    private var vehicleWord: String {
        freeLimit == 1 ? "vehicle" : "vehicles"
    }

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ContentHeightKey.self) { measuredContentHeight = $0 }
        .background(AppTheme.Colors.charcoal)
        .presentationDetents([.height(max(measuredContentHeight, fallbackHeight))])
        .presentationDragIndicator(.visible)
    }

    private var content: some View {
        VStack(spacing: 20) {
            iconBadge

            VStack(spacing: 8) {
                Text("Add More Vehicles with Pro")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Free includes \(freeLimit) \(vehicleWord). 85Blends Pro unlocks unlimited vehicles.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            comparisonRow

            actions
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity)
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Colors.stationYellow.opacity(0.16))
                .frame(width: 64, height: 64)

            Image(systemName: "car.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(AppTheme.Colors.stationYellow)
        }
        .accessibilityHidden(true)
    }

    private var comparisonRow: some View {
        HStack(spacing: 10) {
            comparisonTile(
                label: "FREE",
                value: "\(freeLimit) \(freeLimit == 1 ? "Vehicle" : "Vehicles")",
                isPro: false
            )
            comparisonTile(label: "PRO", value: "Unlimited Vehicles", isPro: true)
        }
    }

    private func comparisonTile(label: String, value: String, isPro: Bool) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(1.0)
                // Label is always readable text, not just a color cue — FREE/PRO status never
                // relies on color alone (see the accessibility checklist in the final report).
                .foregroundStyle(isPro ? AppTheme.Colors.stationYellow : AppTheme.Colors.textMuted)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(isPro ? AppTheme.Colors.stationYellow.opacity(0.10) : AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isPro ? AppTheme.Colors.stationYellow.opacity(0.4) : AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                AppHaptics.selection()
                dismiss()
                onUpgrade()
            } label: {
                Text("View 85Blends Pro")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.Colors.stationYellow)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the 85Blends Pro screen.")

            Button {
                AppHaptics.selection()
                dismiss()
            } label: {
                Text("Not Now")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            VehicleLimitUpsellView(freeLimit: 1, onUpgrade: {})
        }
}
