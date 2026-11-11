//
//  ReleaseNotes.swift
//  EightyFiveBlends
//
//  Single source of truth for the CURRENT release's customer-facing changelog highlights.
//  AboutView's "What's New" section and WhatsNewView (the one-time update popup) both read
//  currentHighlights, so the two can never drift into independently maintained copies — update
//  this file when preparing a new release's changelog, and both surfaces pick it up.
//
//  The highlights are written for one specific release, `highlightsVersion`. When preparing a new
//  release's changelog, update `currentHighlights` and `highlightsVersion` together: the title
//  names that version, and the What's New popup only presents when it matches the running app
//  version, so a version bump that ships without new notes never shows the previous release's
//  notes under the new version number.
//

import Foundation

enum ReleaseNotes {
    /// The app version `currentHighlights` was written for. Not read from the bundle on purpose.
    static let highlightsVersion = "2.4.1"

    /// This release's customer-facing highlights, in display order. Keep these short, concrete,
    /// and free of internal engineering/branch/build/QA language — this is shown directly to
    /// users in both AboutView and the What's New popup.
    static let currentHighlights: [String] = [
        "Improved Nearby E85 Widgets — refresh nearby stations without opening the app, with improved location handling, freshness information, and better readability in tinted Home Screen layouts.",
        "Refreshed Recommended Gear — explore featured eFlexFuel products and RVP Supply wheels, including access to the custom-wheel configurator.",
        "Easier Pro Activation — use Activate Pro after redeeming an Offer Code outside the app, with clearer purchase and Restore Purchases feedback.",
        "More Accurate Fill-Up Logging — E85 and gasoline prices entered in At The Pump now carry into your Fuel Log.",
        "Clearer Calculator Validation — blank or invalid numeric inputs now show a warning instead of being treated as zero.",
        "Improved Garage Reliability — better protection against accidentally linking a new vehicle to a removed vehicle's history, plus improved save-error handling.",
        "Simpler Getting Started — a streamlined quick-start screen with improved support for larger text.",
    ]

    /// "What's New in X.Y.Z" — names the version the highlights were written for, never the
    /// running app version, so older notes are not labeled with a newer version number.
    static var currentHighlightsTitle: String {
        "What's New in \(highlightsVersion)"
    }

    /// CFBundleShortVersionString (MARKETING_VERSION at build time), with a safe fallback for
    /// contexts where the bundle's Info dictionary isn't populated (e.g. SwiftUI previews).
    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
