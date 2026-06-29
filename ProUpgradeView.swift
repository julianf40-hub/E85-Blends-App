//
//  ProUpgradeView.swift
//  EightyFiveBlends
//
//  The single 85Blends Pro paywall for the whole app. Presented as a native sheet from
//  Pro lock cards and soft-limit banners, and pushed from the More screen. There is
//  intentionally only ONE paywall so the Pro experience stays consistent everywhere.
//

import SwiftUI
import StoreKit

enum ProPresentationMode {
    case pushed
    case modal
}

struct ProUpgradeView: View {
    @Environment(\.dismiss) private var dismiss

    let presentationMode: ProPresentationMode

    init(presentationMode: ProPresentationMode = .pushed) {
        self.presentationMode = presentationMode
    }

    private var manager: SubscriptionManager { SubscriptionManager.shared }

    // Benefit list — copy matches the v2.1.2 product spec. SF Symbols scale with Dynamic Type.
    private let benefits: [(icon: String, title: String, detail: String)] = [
        ("map.fill",        "Intelligent E85 Trip Planning", "Plan smarter routes built around ethanol availability."),
        ("arrow.triangle.turn.up.right.diamond.fill", "Route-Based Fuel Stops", "See the best E85 stops along the way, not just nearby."),
        ("chart.bar.fill",  "Advanced Fuel Analytics",       "Go deeper on blend history, MPG, and spending trends."),
        ("bell.badge.fill", "Station Price Alerts",          "Get notified when E85 prices move at your stations."),
        ("car.2.fill",      "Unlimited Vehicles",            "Track your whole garage with no vehicle limit."),
        ("icloud.fill",     "Cloud Sync Ready",              "Built to keep your data in sync across devices."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                priceCard
                benefitsCard
                actionsSection
                footerNote
            }
            .padding(16)
            // Cap content width on iPad so it doesn't stretch awkwardly on wide displays.
            // The outer frame centers the capped block within the scroll view's full width.
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("85Blends Pro")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentationMode == .modal {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .task {
            // Wait for any in-progress startup product fetch to settle before we try.
            // Without this yield + loop, our call hits the isLoadingProducts guard and
            // silently no-ops when SubscriptionManager.init()'s Task is still in flight —
            // leaving the paywall permanently on the error state if that startup load fails.
            await Task.yield()
            while manager.isLoadingProducts {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Load (or re-fetch for freshness) on every paywall presentation.
            await manager.loadProducts()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "crown.fill")
                    .font(.system(.title, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .accessibilityHidden(true)

                Text("85Blends Pro")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }

            Text("Drive farther. Plan smarter. Fuel with confidence.")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Price

    private var priceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(manager.displayPrice)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("/ month")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Text("Cancel anytime.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.stationYellow.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Benefits

    private var benefitsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "What's included")

            ForEach(benefits, id: \.title) { benefit in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: benefit.icon)
                        .font(.body)
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                        .frame(width: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(benefit.title)
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text(benefit.detail)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
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

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        let isWorking = manager.purchaseState == .purchasing || manager.purchaseState == .restoring

        VStack(spacing: 12) {
            if manager.isProUser {
                activeProRow
            } else {
                // The CTA is disabled until a real StoreKit product is loaded, so it never
                // looks tappable when there's nothing to buy (offline / product missing).
                unlockButton(disabled: isWorking || !manager.canPurchase)

                if !manager.canPurchase {
                    availabilityNote
                }

                continueFreeButton(disabled: isWorking)
            }

            purchaseStateRow

            // Restore stays visible in every paywall state (including when already Pro), as
            // App Review expects. Tapping while Pro just re-verifies and confirms active status.
            Divider()
                .background(AppTheme.Colors.border)
                .padding(.vertical, 2)

            restoreButton(disabled: isWorking)
        }
    }

    /// Shown when no purchasable product is available.
    /// Shows a loading indicator until the first fetch has completed; only then surfaces
    /// the error + retry so the user never sees "unavailable" before any attempt is made.
    @ViewBuilder
    private var availabilityNote: some View {
        if manager.isLoadingProducts || !manager.hasAttemptedProductLoad {
            statusRow(icon: "arrow.triangle.2.circlepath", text: "Loading subscription…", color: AppTheme.Colors.textSecondary, spinning: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    icon: "wifi.exclamationmark",
                    text: "Subscriptions are temporarily unavailable. Check your connection and try again.",
                    color: AppTheme.Colors.textSecondary
                )

                Button {
                    Task { await manager.loadProducts() }
                } label: {
                    Text("Try Again")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func unlockButton(disabled: Bool) -> some View {
        Button {
            Task { await manager.purchasePro() }
        } label: {
            VStack(spacing: 3) {
                Text("Unlock 85Blends Pro")
                    .font(.headline)
                    .foregroundStyle(.black)
                // Show subscription title, duration, and price once the product is loaded
                // so the user knows exactly what they're buying before tapping.
                if let product = manager.monthlyProduct {
                    Text("\(product.displayName) · \(subscriptionPeriodLabel(for: product)) · \(product.displayPrice)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.black.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(AppTheme.Colors.stationYellow)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func subscriptionPeriodLabel(for product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "Monthly" }
        switch period.unit {
        case .month: return period.value == 1 ? "Monthly" : "\(period.value)-Month"
        case .year:  return period.value == 1 ? "Yearly"  : "\(period.value)-Year"
        case .week:  return period.value == 1 ? "Weekly"  : "\(period.value)-Week"
        case .day:   return period.value == 1 ? "Daily"   : "\(period.value)-Day"
        @unknown default: return "Monthly"
        }
    }

    private func continueFreeButton(disabled: Bool) -> some View {
        Button {
            AppHaptics.selection()
            dismiss()
        } label: {
            Text("Continue with Free Version")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var activeProRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.primaryGreen)
                .accessibilityHidden(true)

            Text("You have 85Blends Pro. Thanks for your support!")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.primaryGreen.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var purchaseStateRow: some View {
        switch manager.purchaseState {
        case .purchasing:
            statusRow(icon: "arrow.triangle.2.circlepath", text: "Processing your purchase…", color: AppTheme.Colors.textSecondary, spinning: true)
        case .restoring:
            statusRow(icon: "arrow.triangle.2.circlepath", text: "Restoring purchases…", color: AppTheme.Colors.textSecondary, spinning: true)
        case .succeeded:
            EmptyView() // Purchase success is reflected by the active-Pro row above.
        case .restored:
            statusRow(icon: "checkmark.seal.fill", text: "85Blends Pro restored.", color: AppTheme.Colors.primaryGreen)
        case .info(let msg):
            statusRow(icon: "info.circle.fill", text: msg, color: AppTheme.Colors.textSecondary)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                statusRow(icon: "exclamationmark.circle.fill", text: "Something went wrong.", color: AppTheme.Colors.warningRed)
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .idle:
            EmptyView()
        }
    }

    private func statusRow(icon: String, text: String, color: Color, spinning: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spinning {
                ProgressView()
                    .tint(color)
                    .scaleEffect(0.85)
            } else {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func restoreButton(disabled: Bool) -> some View {
        Button {
            Task { await manager.restorePurchases() }
        } label: {
            Text("Restore Purchases")
                .font(.caption.weight(.medium))
                .foregroundStyle(disabled ? AppTheme.Colors.textMuted.opacity(0.5) : AppTheme.Colors.textMuted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Footer

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("85Blends Pro is a $3.99/month auto-renewable subscription. Payment is charged to your Apple ID at purchase confirmation. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Cancel anytime in App Store settings.")
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            legalLinksRow
        }
    }

    private var legalLinksRow: some View {
        HStack(spacing: 16) {
            // Standard Apple EULA — used because the app has no custom Terms of Use.
            if let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                Link("Terms of Use", destination: termsURL)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
            }

            // In-app privacy screen (already shipped under More → Privacy).
            NavigationLink {
                PrivacyView()
            } label: {
                Text("Privacy Policy")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
            }

            Spacer(minLength: 0)
        }
    }
}
