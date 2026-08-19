//
//  DestructiveConfirmationOverlay.swift
//  EightyFiveBlends
//
//  Shared, app-owned replacement for native SwiftUI `.alert` on destructive confirmations
//  (Delete Vehicle, Delete Reminder, reminder completion-history undo/delete, Delete Station,
//  Delete Fill-Up). Extracted from GarageView's original GarageDeleteConfirmationOverlay — the
//  first instance, device-validated in a prior TestFlight build — so every destructive
//  confirmation in the app now shares the exact same visual/interaction language instead of
//  three more copy-pasted variants.
//
//  Why this exists instead of the system `.alert`: in light mode, the native alert's
//  translucent/vibrancy chrome let background content (a colored button, a card) bleed through,
//  making the Cancel label hard to read (device-observed). That's standard system-alert
//  material, not something the app can safely restyle, so this uses fully opaque AppTheme
//  surface colors and a strong dimming backdrop instead.
//
//  PRESENTATION ONLY: this view displays text and invokes closures. It has no knowledge of
//  Vehicle, Reminder, Station, FuelLogEntry, or any model type, performs no persistence, and
//  makes no deletion decisions — every caller owns its own pending-state, cancel behavior, and
//  destructive action exactly as it did with the native alert it replaces.
//
//  2.3.0 — Build 96 compile-risk note: do NOT add `.onExitCommand` or any other
//  iOS-unavailable/platform-specific modifier here. Visible Cancel + scrim-tap cancellation are
//  sufficient; see commit acb3ad3 for why `.onExitCommand` was removed.
//

import SwiftUI

struct DestructiveConfirmationOverlay: View {
    let title: String
    let message: String
    let destructiveActionTitle: String
    let cancelAction: () -> Void
    let destructiveAction: () -> Void

    var body: some View {
        ZStack {
            // Fully opaque dimming backdrop — guarantees nothing behind the dialog (a colored
            // button, a card) can show through underneath it. Tapping the scrim cancels,
            // mirroring a system alert's implicit dismiss-to-cancel.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .onTapGesture(perform: cancelAction)

            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .accessibilitySortPriority(3)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilitySortPriority(2)

                HStack(spacing: 10) {
                    Button(action: cancelAction) {
                        Text("Cancel")
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

                    // Always the destructive treatment (red fill, .destructive role), regardless
                    // of the label text — an "Undo Completion" action that removes history is
                    // still a destructive mutation and must never read as a safe/green action
                    // just because its label starts with "Undo."
                    Button(role: .destructive, action: destructiveAction) {
                        Text(destructiveActionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(AppTheme.Colors.warningRed)
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
