//
//  OnboardingQuickStart.swift
//  EightyFiveBlends
//
//  Pure decision rules behind the one-screen onboarding quick start (85Blends 2.4.1): whether
//  onboarding should be shown, whether it may complete, and exactly what completing it persists.
//  Kept independent of SwiftUI, mirroring WhatsNewPresentation, so the rules OnboardingView and
//  ContentView depend on are directly unit-testable. See
//  EightyFiveBlendsTests/OnboardingQuickStartTests.swift.
//

import Foundation

enum OnboardingQuickStart {
    /// The complete set of values onboarding completion writes — the same three keys, with the
    /// same meanings, the previous multi-step flow wrote. Nothing else (vehicles, tab visibility,
    /// App Experience mode, blend defaults, subscriptions) is ever touched by completion.
    struct Completion: Equatable {
        let hasCompletedOnboarding: Bool
        let hasAcknowledgedDisclaimer: Bool
        let disclaimerAcknowledgedAt: Double
    }

    /// Onboarding is shown only while `hasCompletedOnboarding` is false — a returning user who
    /// completed it in any past session is never re-onboarded. (Preferences → Reset Onboarding
    /// clears the flag deliberately, which is the only way back in.)
    static func shouldPresent(hasCompletedOnboarding: Bool) -> Bool {
        hasCompletedOnboarding == false
    }

    /// At accessibility Dynamic Type sizes the screen switches to a stacked layout: the
    /// acknowledgment label sits above its switch, and the Start action scrolls with the content
    /// instead of being pinned, so a tall footer can never cover the safety items.
    static func usesStackedLayout(isAccessibilitySize: Bool) -> Bool {
        isAccessibilitySize
    }

    /// Completion requires explicit acknowledgment of the safety disclaimer. A vehicle is never
    /// required — it can be added later in Garage.
    static func canComplete(disclaimerAcknowledged: Bool) -> Bool {
        disclaimerAcknowledged
    }

    /// The values to persist on completion, or nil when the disclaimer hasn't been acknowledged.
    static func completion(disclaimerAcknowledged: Bool, now: Date) -> Completion? {
        guard canComplete(disclaimerAcknowledged: disclaimerAcknowledged) else { return nil }
        return Completion(
            hasCompletedOnboarding: true,
            hasAcknowledgedDisclaimer: true,
            disclaimerAcknowledgedAt: now.timeIntervalSince1970
        )
    }

    /// Writes `completion` to `defaults`. `hasCompletedOnboarding` is written last, matching the
    /// previous flow's order, so the acknowledgment is already persisted by the time ContentView
    /// swaps onboarding out for the main TabView.
    static func persist(_ completion: Completion, to defaults: UserDefaults) {
        defaults.set(completion.hasAcknowledgedDisclaimer, forKey: AppPreferenceKey.hasAcknowledgedDisclaimer)
        defaults.set(completion.disclaimerAcknowledgedAt, forKey: AppPreferenceKey.disclaimerAcknowledgedAt)
        defaults.set(completion.hasCompletedOnboarding, forKey: AppPreferenceKey.hasCompletedOnboarding)
    }

    /// Completes onboarding if allowed. Returns false (and writes nothing) when the disclaimer
    /// hasn't been acknowledged.
    @discardableResult
    static func complete(disclaimerAcknowledged: Bool, defaults: UserDefaults, now: Date = .now) -> Bool {
        guard let completion = completion(disclaimerAcknowledged: disclaimerAcknowledged, now: now) else {
            return false
        }
        persist(completion, to: defaults)
        return true
    }
}
