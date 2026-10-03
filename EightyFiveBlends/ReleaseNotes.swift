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
    static let highlightsVersion = "2.4.0"

    /// This release's customer-facing highlights, in display order. Keep these short, concrete,
    /// and free of internal engineering/branch/build/QA language — this is shown directly to
    /// users in both AboutView and the What's New popup.
    static let currentHighlights: [String] = [
        "New Nearby E85 Widget — see nearby E85 stations right from your Home Screen with Small, Medium, and Large layouts.",
        "Community Ethanol Reports — share the ethanol percentage you find at the pump and see recent community readings at supported stations.",
        "Smarter Community Price Reporting — reporting an E85 price is now faster and clearer, with improved post-trip prompts and station validation.",
        "Referral Rewards — invite other drivers to 85Blends Pro with the new Refer & Earn program, working toward a free month of Pro with every 5 successful referrals.",
        "More Pro Plan Options — 85Blends Pro now offers Monthly, 3 Months, and Annual billing, giving you new ways to save on Pro.",
        "Improved Pro Experience — a refreshed upgrade and subscriber experience makes managing Pro, restoring purchases, and accessing benefits easier.",
        "Refreshed More & Settings — important Pro, referral, preference, help, and support options are easier to find.",
        "Review & Share 85Blends — easier ways to leave feedback on the App Store and share 85Blends with other E85 drivers.",
        "Widget & UI Polish — improved widget layouts, map presentation, ethanol displays, and how quickly your Pro status updates.",
        "Bug Fixes & Reliability — improvements across station reporting, referrals, subscriptions, navigation, and general app stability.",
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
