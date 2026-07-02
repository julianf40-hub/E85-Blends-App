//
//  AboutView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct AboutView: View {
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ABOUT")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text("85Blends")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Blend planning, saved stations, and local-first tracking in a cleaner OLED presentation.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                InfoCard(
                    title: "85Blends",
                    message: "A local-first ethanol blend toolkit for tracking vehicles, planning mixes, saving stations, and keeping fuel history organized."
                )

                InfoCard(
                    title: "Build",
                    message: versionText
                )

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(
                        title: "Changelog",
                        subtitle: "Recent product-facing updates."
                    )

                    changelogItem("Introduces 85Blends Pro.")
                    changelogItem("Adds Pro feature previews for Trip Planner, Advanced Fuel Analytics, and Station Price Alerts.")
                    changelogItem("Adds refreshed onboarding with a Pro introduction.")
                    changelogItem("Enables CloudKit-backed Cloud Sync support.")
                    changelogItem("Improves subscription restore and entitlement refresh handling.")
                    changelogItem("Removed public Add Station submission for launch reliability. Station discovery now prioritizes live search and local saved stations.")
                    changelogItem("Trip Planner active destination banner — shows resolved city name, auto-switches to Nearby filter, and raises destination search limit to 50 results.")
                    changelogItem("Trip Planner Clear Trip — resets destination context, cancels in-flight search, and returns to normal browse mode.")
                    changelogItem("Destination-aware empty states — empty Nearby results now name the searched location and suggest increasing the radius.")
                    changelogItem("Stability hardening — neutralized silent store deletion, vehicle rename propagation, location auth, and subscription refresh guard.")
                    changelogItem("Improved Add Vehicle button responsiveness on the Garage screen.")
                    changelogItem("Combined Favorites into Saved stations with favorites pinned first.")
                    changelogItem("Fixed persistent sideways drag movement on the Stations screen.")
                    changelogItem("Completed light theme consistency pass across major screens.")
                    changelogItem("Polished More and Preferences light theme styling.")
                    changelogItem("Polished Stations light theme cards, filters, and action hierarchy.")
                    changelogItem("Refined Blend Guide card styling for better light theme readability.")
                    changelogItem("Improved light theme accent consistency across buttons, tabs, chips, and highlights.")
                    changelogItem("Polished light theme foundation with cleaner surfaces, borders, and text contrast.")
                    changelogItem("Cleaned up 85Blends Pro navigation controls.")
                    changelogItem("Improved maintenance reminders with clearer vehicle-specific filtering and assignment.")
                    changelogItem("Fixed unintended sideways movement on the Stations screen.")
                    changelogItem("Improved Trip Planner keyboard dismissal on the Stations screen.")
                    changelogItem("Added Trip Planner to Stations — search by city/state or ZIP to find E85 stops near any location before leaving, without replacing the current-location search.")
                    changelogItem("Stations unified list — saved, nearby, and favorite stations now share one list with All / Favorites / Saved / Nearby filter chips; no more competing sections.")
                    changelogItem("Added Pro status row to Preferences showing current subscription status.")
                    changelogItem("Pro soft-limit banners now show context-specific copy in Garage, Fuel Log, and Stations — banners are informational only and do not block access.")
                    changelogItem("Pro paywall copy and safety polish — App Store-safe wording, loading/error/success states, always-visible Restore Purchases, and non-pushy limit banners.")
                    changelogItem("Pro upgrade infrastructure added — SubscriptionManager, upgrade screen, and soft-limit banners in Garage, Fuel Log, and Stations.")
                    changelogItem("Performance Blue visual QA — range badge now uses gold in Performance Blue to avoid competing with the primary blue accent.")
                    changelogItem("Accent Theme coverage audit — confirmed all interactive UI correctly follows selected theme.")
                    changelogItem("Added Accent Theme selector with Original Green and Performance Blue options.")
                    changelogItem("Prepared internal TestFlight build with versioning cleanup and release-readiness checks.")
                    changelogItem("Audited and documented API key safety for App Store release.")
                    changelogItem("Removed unused reminder draft purchase-link compatibility state.")
                    changelogItem("Documented and hardened reminder purchase-link compatibility handling.")
                    changelogItem("Clarified location permission wording for nearby station and fuel logging features.")
                    changelogItem("Finished consolidating shared location handling across fuel logging and station views.")
                    changelogItem("Shared the station location manager across views to avoid duplicate location updates.")
                    changelogItem("Improved haptic feedback reliability by reusing prepared feedback generators.")
                    changelogItem("Fixed Pump mode E60/E70 selection, corrected average MPG math, and aligned default blend values to E30.")
                    changelogItem("Onboarding safety acknowledgement simplified.")
                    changelogItem("Final App Store readiness QA fixes.")
                    changelogItem("Improved data container recovery handling.")
                    changelogItem("Improved save error handling.")
                    changelogItem("Station map fallback improved for all regions.")
                    changelogItem("Onboarding simplified for faster first launch.")
                    changelogItem("Main tab bar simplified for App Store readiness.")
                    changelogItem("Removed unfinished saved blend placeholder before release.")
                    changelogItem("Recommended Gear navigation back button fixed.")
                    changelogItem("Improved iOS 17.6 compatibility for map directions.")
                    changelogItem("Onboarding modernized with premium feature walkthrough.")
                    changelogItem("Blend cost comparison expanded.")
                    changelogItem("At the Pump mode polished for faster fueling.")
                    changelogItem("Fuel Log recent trend insights added.")
                    changelogItem("Fuel Log analytics summary expanded.")
                    changelogItem("Maintenance reminders can now save multiple parts links.")
                    changelogItem("Fixed purchase link field focus and paste interaction behavior.")
                    changelogItem("Release candidate stability and polish improvements.")
                    changelogItem("App Store readiness safety fixes added.")
                    changelogItem("Maintenance reminders can now save parts links.")
                    changelogItem("E85 vs gas cost calculator added.")
                    changelogItem("Station map price summary now shows community prices.")
                    changelogItem("Reminder titles now default to category when left blank.")
                    changelogItem("App Store readiness stabilization and polish pass — empty states, onboarding, At the Pump, and UI consistency.")
                    changelogItem("App Store readiness polish, privacy copy, and stability checks completed.")
                    changelogItem("At the Pump blend guide can now collapse after selecting a target.")
                    changelogItem("At the Pump mode active vehicle detection fixed.")
                    changelogItem("At the Pump blend presets now use guided range-versus-power cards.")
                    changelogItem("At the Pump mode now includes quick target blend, fuel level, and ethanol presets.")
                    changelogItem("At the Pump mode now recognizes the active Garage vehicle.")
                    changelogItem("OLED Dark theme refined with true-black backgrounds.")
                    changelogItem("At the Pump mode added for one-handed blend guidance near saved stations.")
                    changelogItem("Vehicle tank size lookup helper added.")
                    changelogItem("Garage vehicle photo support added.")
                    changelogItem("First-launch onboarding refreshed with friendlier guidance.")
                    changelogItem("Community E85 price reporting thank-you confirmation added.")
                    changelogItem("Station price freshness badges added.")
                    changelogItem("Smart reminder quick-start templates added.")
                    changelogItem("iCloud sync stability fallback added.")
                    changelogItem("Reminder quick start templates added.")
                    changelogItem("Saved station price freshness badges added.")
                    changelogItem("Fixed Supabase community price request path.")
                    changelogItem("Community price report upload diagnostics improved.")
                    changelogItem("Station price updates can now report community prices.")
                    changelogItem("Fuel Log can detect nearby station name.")
                    changelogItem("Latest community E85 prices now show on station cards.")
                    changelogItem("Fuel Log can prompt users to report E85 prices.")
                    changelogItem("Community E85 price sync foundation added.")
                    changelogItem("Local E85 price reporting added to Stations.")
                    changelogItem("Garage active vehicle odometer quick update added.")
                    changelogItem("Completed reminder history swipe-delete fixed.")
                    changelogItem("Onboarding now lets users choose visible tabs.")
                    changelogItem("Saved station filter simplified into a gold toggle button.")
                    changelogItem("Reminder completion history added for recurring service.")
                    changelogItem("Saved station filter moved to top action area.")
                    changelogItem("More tab restored alongside Gear tab.")
                    changelogItem("Recommended Gear added as a main tab.")
                    changelogItem("Reminder completion confirmation and history details added.")
                    changelogItem("Garage vehicle cards now show odometer.")
                    changelogItem("Fuel Log back navigation from More fixed.")
                    changelogItem("Saved station favorites filter restored.")
                    changelogItem("Onboarding safety acknowledgements now guide users to missing items.")
                    changelogItem("Onboarding safety acknowledgment Finish button fixed.")
                    changelogItem("RVP Supply sponsor card linked.")
                    changelogItem("Sponsor section moved to More.")
                    changelogItem("Onboarding disclaimer acknowledgements added.")
                    changelogItem("Stations header fixed and duplicate live saves prevented.")
                    changelogItem("MapKit deprecation warnings cleaned up.")
                    changelogItem("Stations header layout refined.")
                    changelogItem("Station directions now open in the selected maps app.")
                    changelogItem("Stations map user-location centering fixed.")
                    changelogItem("Live nearby E85 station search connected.")
                    changelogItem("Live station service target compatibility cleaned up.")
                    changelogItem("Use My Location map centering added.")
                    changelogItem("Stations map UI polished.")
                    changelogItem("Stations now shows a real MapKit map.")
                    changelogItem("MapKit station map foundation added.")
                    changelogItem("Final polish verification before TestFlight upload.")
                    changelogItem("Stations layout decluttered for faster station access.")
                    changelogItem("Keyboard Done controls added to app inputs.")
                    changelogItem("Calculator Blend Guide made compact and collapsed by default.")
                    changelogItem("Stations UI refreshed with OLED station cards.")
                    changelogItem("Blend Guide tap-to-select interaction added.")
                    changelogItem("Stations OLED polish improvements")
                    changelogItem("Calculator UI polish improvements")
                    changelogItem("OLED visual polish inspired by the original 85Blends interface.")
                    changelogItem("Native SwiftUI rebuild")
                    changelogItem("E85 blend calculator")
                    changelogItem("Garage vehicle profiles")
                    changelogItem("Fuel log")
                    changelogItem("Maintenance reminders")
                    changelogItem("Local saved stations")
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
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func changelogItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.Colors.accentGreen)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }
}
