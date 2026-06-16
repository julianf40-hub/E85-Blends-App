//
//  ProFeatureLockView.swift
//  EightyFiveBlends
//
//  Reusable 85Blends Pro gating components. Everything here presents the single
//  ProUpgradeView paywall for locked users, so there is one consistent upgrade path.
//

import SwiftUI

/// A locked-feature card: lock icon, feature title, short benefit description, and an
/// "Unlock 85Blends Pro" button that presents the paywall.
///
/// Used directly as a "coming to Pro" preview, and as the locked half of `ProFeatureGate`.
struct ProFeatureLockView: View {
    let icon: String
    let title: String
    let description: String

    @State private var isShowingPaywall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.Colors.stationYellow.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(4)
                        .background(AppTheme.Colors.stationYellow)
                        .clipShape(Circle())
                        .offset(x: 5, y: -5)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            Button {
                AppHaptics.selection()
                isShowingPaywall = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill")
                        .font(.caption.weight(.bold))
                    Text("Unlock 85Blends Pro")
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.Colors.stationYellow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .sheet(isPresented: $isShowingPaywall) {
            NavigationStack {
                ProUpgradeView(presentationMode: .modal)
            }
        }
    }
}

/// State-aware Pro entry point. Free users see the locked preview card (tapping it opens the
/// paywall); Pro users get a live card that navigates to the real feature.
///
/// Must be hosted inside a `NavigationStack` so the unlocked card can push its destination.
struct ProFeatureGate<Destination: View>: View {
    let icon: String
    let title: String
    let description: String
    @ViewBuilder var destination: () -> Destination

    // Reading the observable singleton here means the gate flips automatically when
    // entitlement changes (purchase, restore, or the dev override).
    private var isUnlocked: Bool { SubscriptionManager.shared.isProUser }

    var body: some View {
        if isUnlocked {
            NavigationLink {
                destination()
            } label: {
                unlockedCard
            }
            .buttonStyle(.plain)
        } else {
            ProFeatureLockView(icon: icon, title: title, description: description)
        }
    }

    private var unlockedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.stationYellow)
                .frame(width: 44, height: 44)
                .background(AppTheme.Colors.stationYellow.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    ProBadge()
                }

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textMuted)
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
}

/// Small gold "PRO" capsule used to mark unlocked Pro features.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppTheme.Colors.stationYellow)
            .clipShape(Capsule())
            .accessibilityLabel("Pro feature")
    }
}

// MARK: - Shared shell building blocks (used by the Pro feature placeholder screens)

/// A row describing an upcoming capability inside a Pro feature shell.
struct ProShellRow: View {
    let icon: String
    let title: String
    let detail: String
    var badge: String? = "Coming soon"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(AppTheme.Colors.stationYellow)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.Colors.cardBackground)
                            .overlay(Capsule().stroke(AppTheme.Colors.border, lineWidth: 1))
                            .clipShape(Capsule())
                    }
                }

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A labeled metric tile for the analytics shell. Defaults to a placeholder value.
struct ProMetricTile: View {
    let title: String
    let systemImage: String
    var value: String = "—"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            ProFeatureLockView(
                icon: "map.fill",
                title: "Trip Planner",
                description: "Intelligent E85 trip planning with route-based fuel stops."
            )
            ProMetricTile(title: "Monthly fuel spend", systemImage: "dollarsign.circle.fill")
            ProShellRow(icon: "fuelpump.fill", title: "Intelligent fuel stops", detail: "Pick the best E85 stops along your route.")
        }
        .padding(16)
    }
    .background(AppTheme.Colors.charcoal)
}
