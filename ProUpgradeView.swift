//
//  ProUpgradeView.swift
//  EightyFiveBlends
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

    private let features: [(icon: String, title: String, detail: String)] = [
        ("car.2.fill",          "More garage vehicles",        "Track more vehicles beyond the free-tier limit."),
        ("fuelpump.fill",       "More fill-up history",        "Log more fill-ups and keep a longer blend history."),
        ("mappin.and.ellipse",  "More saved stations",         "Save more of your regular E85 stops."),
        ("chart.bar.fill",      "Advanced fuel insights",      "Deeper analytics on blend history and spending trends."),
        ("square.and.arrow.up", "Export and backup tools",     "Planned for a future update."),
        ("heart.fill",          "Support 85Blends development","Help keep an independent E85 app growing."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                featuresCard
                plansCard
                footerNote
            }
            .padding(16)
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
            await manager.loadProducts()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(AppTheme.Colors.stationYellow)

                Text("85Blends Pro")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }

            Text("Expand what you can track. Support an independently-built app for E85 drivers.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: - Features

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "What Pro includes", subtitle: "Features may expand over time.")

            ForEach(features, id: \.title) { feature in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: feature.icon)
                        .font(.body)
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text(feature.detail)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
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

    // MARK: - Plans (always visible — handles all states)

    private var plansCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Choose a plan")

            if manager.isLoadingProducts {
                loadingRow
            } else if manager.availableProducts.isEmpty {
                plansUnavailableRow
            } else {
                let isWorking = manager.purchaseState == .purchasing || manager.purchaseState == .restoring
                ForEach(manager.availableProducts, id: \.id) { product in
                    productRow(product, disabled: isWorking)
                }
            }

            purchaseStateRow

            Divider()
                .background(AppTheme.Colors.border)
                .padding(.vertical, 2)

            restoreButton
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

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.Colors.textSecondary)
            Text("Loading plans…")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var plansUnavailableRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plans are temporarily unavailable.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Text("Check your connection and try again, or use Restore Purchases if you already have Pro.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var purchaseStateRow: some View {
        switch manager.purchaseState {
        case .purchasing:
            statusRow(icon: "arrow.triangle.2.circlepath", text: "Processing your purchase…", color: AppTheme.Colors.textSecondary, spinning: true)
        case .restoring:
            statusRow(icon: "arrow.triangle.2.circlepath", text: "Restoring purchases…", color: AppTheme.Colors.textSecondary, spinning: true)
        case .succeeded:
            statusRow(icon: "checkmark.circle.fill", text: "Your Pro access is active. Thank you for supporting 85Blends!", color: AppTheme.Colors.primaryGreen)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                statusRow(icon: "exclamationmark.circle.fill", text: "Something went wrong.", color: AppTheme.Colors.warningRed)
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        }
    }

    private var restoreButton: some View {
        let isWorking = manager.purchaseState == .purchasing || manager.purchaseState == .restoring
        return Button {
            Task { await manager.restorePurchases() }
        } label: {
            Text("Restore Purchases")
                .font(.caption.weight(.medium))
                .foregroundStyle(isWorking ? AppTheme.Colors.textMuted.opacity(0.5) : AppTheme.Colors.textMuted)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    @ViewBuilder
    private func productRow(_ product: Product, disabled: Bool) -> some View {
        Button {
            Task { await manager.purchase(product) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(disabled ? AppTheme.Colors.textMuted : AppTheme.Colors.textPrimary)

                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Spacer()

                Text(product.displayPrice)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(disabled ? AppTheme.Colors.textMuted : AppTheme.Colors.stationYellow)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Footer

    private var footerNote: some View {
        Text("Payment is charged to your Apple ID account at purchase confirmation. Subscriptions automatically renew unless cancelled at least 24 hours before the end of the current period. You can manage or cancel subscriptions in your Apple ID account settings. One-time purchases do not auto-renew.")
            .font(.caption2)
            .foregroundStyle(AppTheme.Colors.textMuted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
