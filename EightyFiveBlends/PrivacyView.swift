//
//  PrivacyView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct PrivacyView: View {
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
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
