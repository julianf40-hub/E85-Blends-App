//
//  WhatsNewView.swift
//  EightyFiveBlends
//
//  The one-time "What's New in X.Y.Z" sheet shown to an existing user after they update to a
//  new app version. See WhatsNewPresentation.swift for the presentation rule and ContentView.swift
//  for where this is wired up. Content comes from ReleaseNotes.currentHighlights — the same
//  source AboutView's "What's New" section reads — so the two are never independently
//  maintained copies.
//
//  Presentation-agnostic on purpose: this view only renders content and calls onContinue when
//  the user taps through. The caller (ContentView) owns the sheet's isPresented state and
//  persists lastPresentedWhatsNewVersion via .sheet's onDismiss, so both an explicit tap and a
//  swipe-to-dismiss are recorded identically.
//

import SwiftUI

struct WhatsNewView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("WHAT'S NEW")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text(ReleaseNotes.currentHighlightsTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ReleaseNotes.currentHighlights, id: \.self) { highlight in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AppTheme.Colors.accentGreen)
                                .accessibilityHidden(true)

                            Text(highlight)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Button {
                onContinue()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.Colors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Colors.oledBackground.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            WhatsNewView(onContinue: {})
        }
}
