//
//  PriceAlertsEntryViews.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B). The two ways a station card offers its Price Alert
//  sheet, each a thin view over PriceAlertsEntryPresentation (which is unit-tested):
//
//    PriceAlertsBellButton  an icon button in the icon row of the Classic station cards, beside Share
//    PriceAlertsEntryRow    a full-width row in the Pro map's selected-station details, where a fifth
//                           equal-width action button would not fit at larger text sizes
//
//  Both show NOTHING for a station with no community UUID — there is nothing an alert could be keyed
//  by, and no explanation worth the space on a card. Both carry a small lock for a Free user (the
//  sheet then shows the Pro card), and neither shows one while RevenueCat has not answered, because
//  an unresolved entitlement is not Free.
//
//  They only report a tap. Building the sheet's target, and presenting it, is StationsView's job.
//

import SwiftUI

/// Reads the entitlement the same way the Price Alerts service does, without constructing the service.
@MainActor
private var currentPriceAlertsEntitlement: PriceAlertsEntitlement {
    SubscriptionManagerEntitlementProvider().entitlement
}

struct PriceAlertsBellButton: View {
    let communityStationID: UUID?
    let stationName: String
    let action: () -> Void

    var body: some View {
        let presentation = PriceAlertsEntryPresentation.resolve(
            communityStationID: communityStationID,
            entitlement: currentPriceAlertsEntitlement
        )
        if presentation.isVisible {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if presentation.showsProCue {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(3)
                            .background(AppTheme.Colors.stationYellow)
                            .clipShape(Circle())
                            .offset(x: 4, y: -4)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.accessibilityLabel(stationName: stationName))
            .accessibilityHint(presentation.accessibilityHint ?? "")
        }
    }
}

struct PriceAlertsEntryRow: View {
    let communityStationID: UUID?
    let stationName: String
    let action: () -> Void

    var body: some View {
        let presentation = PriceAlertsEntryPresentation.resolve(
            communityStationID: communityStationID,
            entitlement: currentPriceAlertsEntitlement
        )
        if presentation.isVisible {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: "bell")
                        .font(.body.weight(.semibold))
                        .accessibilityHidden(true)

                    Text("Price Alert")
                        .font(.subheadline.weight(.semibold))

                    if presentation.showsProCue {
                        Image(systemName: "lock.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.Colors.stationYellow)
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(AppTheme.Colors.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.accessibilityLabel(stationName: stationName))
            .accessibilityHint(presentation.accessibilityHint ?? "")
        }
    }
}
