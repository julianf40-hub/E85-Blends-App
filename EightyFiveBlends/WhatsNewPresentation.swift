//
//  WhatsNewPresentation.swift
//  EightyFiveBlends
//
//  Pure decision logic behind the version-aware "What's New" popup: whether to present it, and
//  what to persist once it's dismissed. Kept independent of SwiftUI/@AppStorage, mirroring
//  AppExperienceNavigation/ReminderScheduling's separation of pure rules from the views that call
//  them, so the actual rules ContentView depends on are directly unit-testable. See
//  EightyFiveBlendsTests/WhatsNewPresentationTests.swift.
//

import Foundation

enum WhatsNewPresentation {
    /// True only when all of the following hold:
    /// - Onboarding has been completed (never present over active onboarding).
    /// - Onboarding was NOT completed during this same launch — a brand-new user who just
    ///   finished onboarding has already been introduced to the current app and should not
    ///   immediately see a second "what's new" screen. `onboardingJustCompletedThisLaunch` is a
    ///   snapshot taken once at launch by the caller (see ContentView), not derived here.
    /// - No required consent presentation is still pending (see `isRequiredConsentPresentationPending`).
    /// - The current app version differs from the last version this sheet was shown for.
    ///
    /// An existing user upgrading from a version that predates this feature has
    /// `lastPresentedVersion == ""` (the key never existed for them) and
    /// `onboardingJustCompletedThisLaunch == false` (they didn't just onboard) — this correctly
    /// resolves to `true`, showing them the sheet once on their first launch of the new version,
    /// which is the intended behavior for that case.
    static func shouldPresent(
        currentAppVersion: String,
        lastPresentedVersion: String,
        hasCompletedOnboarding: Bool,
        onboardingJustCompletedThisLaunch: Bool,
        isRequiredConsentPresentationPending: Bool
    ) -> Bool {
        guard hasCompletedOnboarding else { return false }
        guard onboardingJustCompletedThisLaunch == false else { return false }
        // 2.3.2 release-polish fix: at launch, AdManager may still be gathering/presenting
        // required UMP consent (see AdManager.gatherConsent()) via a raw UIKit `present(...)` on
        // the same window ContentView's own SwiftUI `.sheet` would use. Presenting both around
        // the same moment risks a dropped/broken presentation ("Attempt to present ... whose
        // view is not in the window hierarchy"). Required consent UI always takes priority —
        // What's New is purely informational and can wait; the caller (ContentView) re-evaluates
        // this once consent resolution is no longer pending, so this never permanently suppresses
        // the sheet, only delays it within the same launch.
        guard isRequiredConsentPresentationPending == false else { return false }
        return currentAppVersion != lastPresentedVersion
    }

    /// The value to persist for `lastPresentedWhatsNewVersion` once the sheet is dismissed
    /// (by any means — CTA tap or swipe-away). Trivial by design: dismissal always records the
    /// version that was actually shown. Kept as its own named step, rather than inlined at the
    /// call site, so "record what was shown" has one clear place to read and verify.
    static func versionToPersistOnDismiss(currentAppVersion: String) -> String {
        currentAppVersion
    }
}
