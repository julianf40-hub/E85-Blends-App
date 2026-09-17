//
//  EthanolRangeConfirmationOverlay.swift
//  EightyFiveBlends
//
//  2.4.0 Stations readability pass — a high-contrast, fully opaque replacement for the
//  out-of-range ethanol percentage confirmation, which previously used a native
//  `.confirmationDialog`. Device testing found that system confirmationDialog's
//  translucent/vibrancy chrome, combined with this app's own accent tint, made both the
//  explanatory text and the "Submit Anyway" action hard to read — the same class of problem
//  DestructiveConfirmationOverlay.swift already solved for destructive confirmations. This
//  mirrors that component's opaque-surface, 44pt-target, VoiceOver-modal architecture and its
//  plain-pre-formatted-String shape, but intentionally uses a cautionary (not destructive)
//  treatment: submitting an out-of-range ethanol percentage is still valid, user-submitted
//  data, never an error or a blocked action.
//
//  PRESENTATION ONLY: takes already-formatted text, exactly like DestructiveConfirmationOverlay
//  takes title/message/destructiveActionTitle — no knowledge of CommunityEthanolValidation, no
//  submission logic, no persistence. The caller (StationsView, where the E-notation formatting
//  and the typical-range constants already live) owns building that text, the pending
//  percentage, Cancel behavior, and the submit action.
//

import SwiftUI

struct EthanolRangeConfirmationOverlay: View {
    let title: String
    let message: String
    let submitActionTitle: String
    let cancelAction: () -> Void
    let submitAction: () -> Void

    var body: some View {
        ZStack {
            // Fully opaque dimming backdrop, matching DestructiveConfirmationOverlay — nothing
            // behind this card (the sheet's own price/ethanol fields) can bleed through. Tapping
            // the scrim cancels, mirroring that same implicit dismiss-to-cancel.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .onTapGesture(perform: cancelAction)

            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilitySortPriority(3)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilitySortPriority(2)

                VStack(spacing: 10) {
                    Button(action: cancelAction) {
                        Text("Go Back")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(AppTheme.Colors.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(AppTheme.Colors.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilitySortPriority(1)

                    // Warning-yellow, not destructive-red and not primaryGreen: this isn't a
                    // dangerous or blocked action (still valid, submittable data), and it must
                    // never repeat the green-on-translucent low-contrast pairing the native
                    // confirmationDialog had. Dark charcoal text on the solid yellow fill keeps
                    // this readable in both light and dark mode, matching how this app's own
                    // priceFreshnessBadge already pairs stationYellow with charcoal text.
                    Button(action: submitAction) {
                        Text(submitActionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.charcoal)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(AppTheme.Colors.stationYellow)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilitySortPriority(0)
                }
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(AppTheme.Colors.surfaceElevated) // fully opaque in light AND dark
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .padding(.horizontal, 32)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .zIndex(1)
    }
}
