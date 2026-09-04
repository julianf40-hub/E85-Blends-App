//
//  PrivacyView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct PrivacyView: View {
    @Environment(\.openURL) private var openURL
    @State private var privacyPolicyLinkMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PRIVACY")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text("Privacy")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }

                InfoCard(
                    title: "Local-First",
                    message: "85Blends keeps your vehicles, fuel logs, reminders, saved stations, and app preferences on your device first."
                )
                InfoCard(
                    title: "No Account Required",
                    message: "There is no sign-in flow and no required account to use the app."
                )
                InfoCard(
                    title: "iCloud Sync",
                    message: "If iCloud is available on your device, SwiftData can sync supported app data through your private CloudKit storage."
                )
                InfoCard(
                    title: "Location Usage",
                    message: "Calculator and Stations use your location only while 85Blends is open, to find nearby E85 stations and detect when you're near a saved one in At the Pump mode. If you turn on Automatic Pump Detection, 85Blends may also use your location in the background to recognize arrival at a saved station and send an alert — it never tracks or stores your travel history."
                )
                InfoCard(
                    title: "Advertising",
                    message: "Free-tier screens show native ads served by Google Mobile Ads. 85Blends doesn't add extra tracking to personalize them, and a consent prompt lets you control ad privacy where required by law — see Preferences for privacy options. 85Blends Pro removes ads entirely."
                )
                InfoCard(
                    title: "Community Price Reports",
                    message: "If you choose to share an E85 price, the app sends the station details, reported price, report time, optional note, and app version to the community pricing service."
                )
                InfoCard(
                    title: "Anonymous Reporter ID",
                    message: "Community price reports use a locally generated anonymous reporter ID so reports can be attributed without requiring your name, email, or account."
                )
                InfoCard(
                    title: "Vehicle Photos",
                    message: "If you add a vehicle photo, the selected image is stored with your Garage profile and may sync through iCloud if CloudKit is enabled."
                )
                InfoCard(
                    title: "Personal Data",
                    message: "85Blends does not sell your personal data. The app is built around local storage, optional iCloud sync, and opt-in community price sharing."
                )

                // The cards above are this screen's own in-app summary — kept exactly as they
                // were; this link only adds a way to reach the full, official, hosted policy,
                // it never replaces the summary. https://85blends.app/privacy.html is 85Blends'
                // existing, live, official privacy policy (already the URL used in the App Store
                // listing) — verified reachable during the 2.3.2 release-readiness correction
                // pass; not a new or invented URL.
                Button {
                    openFullPrivacyPolicy()
                } label: {
                    HStack {
                        Text("View Full Privacy Policy")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(14)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .accessibilityHint("Opens 85Blends' full privacy policy in your browser.")

                if let privacyPolicyLinkMessage {
                    Text(privacyPolicyLinkMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openFullPrivacyPolicy() {
        privacyPolicyLinkMessage = nil
        guard let url = URL(string: "https://85blends.app/privacy.html") else {
            privacyPolicyLinkMessage = "Privacy policy link is unavailable right now."
            return
        }
        openURL(url) { accepted in
            if accepted == false {
                privacyPolicyLinkMessage = "Unable to open the privacy policy right now."
            }
        }
    }
}
