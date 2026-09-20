//
//  ReferralCodeEntrySheet.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — Refer & Earn UI. The sheet for entering someone else's referral code.
//  One referrer for life is immutable, so this sheet never lets a tap on "Apply Code" reach the
//  backend directly — it always confirms first (Phase 14) and never dismisses or shows success
//  until ReferralManager.applyReferralCode(_:) has actually returned a backend-confirmed result
//  (see that method's own "PURCHASE-ORDERING SAFETY" header). A failed attempt keeps the sheet
//  open with the entered code preserved, never silently clearing it.
//

import SwiftUI

struct ReferralCodeEntrySheet: View {
    @Environment(\.dismiss) private var dismiss

    // Deliberately not injected via a default parameter value — see ReferEarnView.swift's own
    // header for why a default argument expression referencing the @MainActor-isolated
    // `ReferralManager.shared` is unsafe here. `ReferralManager.shared` is read directly from
    // `submit()` below instead, which (like every other member of a View) is already
    // @MainActor-isolated via View's own protocol requirement.
    @State private var code = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var isShowingConfirmation = false

    private var normalizedCode: String {
        ReferralPresentation.normalizedReferralCode(code)
    }

    private var isCodeValid: Bool {
        ReferralPresentation.referralCodeIsValid(code)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Enter the code you received before subscribing to 85Blends Pro.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)

                    codeField

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(AppTheme.Colors.warningRed)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Error: \(errorMessage)")
                    }

                    applyButton

                    Text("Referral codes can't be changed once applied, so double-check the code before continuing.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationTitle("Enter Referral Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .confirmationDialog(
            "Apply referral code?",
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply Code") {
                Task { await submit() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apply \(normalizedCode)?\n\nReferral codes can't be changed after they're applied. Make sure this is the code you want to use.")
        }
    }

    private var codeField: some View {
        TextField("ABCD2345", text: $code)
            .font(.system(.title2, design: .monospaced).weight(.semibold))
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .tracking(4)
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled(true)
            .keyboardType(.asciiCapable)
            .disabled(isSubmitting)
            .onChange(of: code) { _, newValue in
                let normalized = ReferralPresentation.normalizedReferralCode(newValue)
                code = String(normalized.prefix(ReferralPresentation.referralCodeLength))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(AppTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel("Referral code")
            .accessibilityHint("Enter the 8 character referral code you received, using letters and numbers")
    }

    private var applyButton: some View {
        Button {
            AppHaptics.selection()
            isShowingConfirmation = true
        } label: {
            Group {
                if isSubmitting {
                    ProgressView()
                        .tint(AppTheme.Colors.textPrimary)
                } else {
                    Text("Apply Code")
                        .font(.headline)
                }
            }
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isCodeValid ? AppTheme.Colors.primaryGreen : AppTheme.Colors.primaryGreen.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isCodeValid == false || isSubmitting)
        .accessibilityLabel(isSubmitting ? "Applying referral code" : "Apply Code")
    }

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            // The manager never returns/updates state until the backend confirms — see
            // ReferralManager.applyReferralCode(_:)'s own "PURCHASE-ORDERING SAFETY" header. This
            // sheet mirrors that guarantee: no dismiss, no success feedback, and no locally
            // "applied" state until this call actually succeeds.
            _ = try await ReferralManager.shared.applyReferralCode(normalizedCode)
            AppHaptics.success()
            dismiss()
        } catch let error as ReferralServiceError {
            AppHaptics.warning()
            errorMessage = ReferralPresentation.userFacingMessage(for: error)
        } catch {
            AppHaptics.warning()
            errorMessage = ReferralPresentation.userFacingMessage(for: .network(error.localizedDescription))
        }
    }
}

#Preview {
    ReferralCodeEntrySheet()
}
