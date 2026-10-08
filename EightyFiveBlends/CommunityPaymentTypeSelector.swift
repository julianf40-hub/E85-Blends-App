//
//  CommunityPaymentTypeSelector.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 (Phase 3C) — the Payment Type choice in the community price-report sheets (the Stations sheet in
//  both layouts, and the Fuel Log report prompt):
//
//      Payment Type
//      [ Cash ] [ Credit ] [ Same for Both ]
//      Select the price shown at the pump or on the sign.
//
//  NOTHING IS PRESELECTED, and the choice is not remembered between reports: a person states which price they are
//  reporting every time, so a price is never silently labelled Credit (or Cash). The wording and the rule
//  ("`.unknown` is not an answer") live in CommunityPaymentTypeValidation; this file is only the control.
//
//  Selected state is carried by a check mark, a thicker border and the selected accessibility trait, never by colour
//  alone. The three buttons sit in an adaptive grid, so at large Dynamic Type sizes they wrap onto more rows instead of
//  truncating; every label scales with its text style.
//

import SwiftUI

struct CommunityPaymentTypeSelector: View {
    @Binding var selection: CommunityPaymentType?
    /// Shown, in the warning colour, when the person tried to submit without choosing.
    var message: String?
    var isDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CommunityPaymentTypeValidation.sectionTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(CommunityPaymentType.reportChoices, id: \.self) { choice in
                    option(choice)
                }
            }

            Text(CommunityPaymentTypeValidation.helpText)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(red: 0.98, green: 0.54, blue: 0.54))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: selection) { _, newValue in
            if newValue != nil {
                AppHaptics.selection()
            }
        }
    }

    private func option(_ choice: CommunityPaymentType) -> some View {
        let isSelected = selection == choice
        let traits: AccessibilityTraits = isSelected ? [.isSelected] : []
        return Button {
            selection = choice
        } label: {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                        .accessibilityHidden(true)
                }
                Text(choice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? AppTheme.Colors.softGreenBackground : AppTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        message != nil && selection == nil
                            ? AppTheme.Colors.warningRed
                            : (isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.border),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(choice.title)
        .accessibilityHint(choice.reportAccessibilityHint)
        .accessibilityAddTraits(traits)
    }
}
