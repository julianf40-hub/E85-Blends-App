//
//  OnboardingQuickStartTests.swift
//  EightyFiveBlendsTests
//
//  Regression coverage for the 85Blends 2.4.1 one-screen onboarding quick start. These exercise
//  the actual OnboardingQuickStart functions OnboardingView calls — not a reimplementation — and
//  persist into an isolated UserDefaults suite, never UserDefaults.standard.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct OnboardingQuickStartTests {

    private static let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "OnboardingQuickStartTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: First launch / acknowledgment gating

    @Test("First launch with no stored flag presents onboarding")
    func firstLaunch_presentsOnboarding() {
        let defaults = makeIsolatedDefaults()
        let stored = defaults.bool(forKey: AppPreferenceKey.hasCompletedOnboarding)
        #expect(OnboardingQuickStart.shouldPresent(hasCompletedOnboarding: stored))
    }

    @Test("Completion is blocked until the disclaimer is acknowledged")
    func completion_requiresAcknowledgment() {
        #expect(OnboardingQuickStart.canComplete(disclaimerAcknowledged: false) == false)
        #expect(OnboardingQuickStart.completion(disclaimerAcknowledged: false, now: Self.fixedNow) == nil)
        #expect(OnboardingQuickStart.canComplete(disclaimerAcknowledged: true))
    }

    @Test("Unacknowledged completion attempt writes nothing")
    func unacknowledgedComplete_writesNothing() {
        let defaults = makeIsolatedDefaults()

        let completed = OnboardingQuickStart.complete(
            disclaimerAcknowledged: false,
            defaults: defaults,
            now: Self.fixedNow
        )

        #expect(completed == false)
        #expect(defaults.object(forKey: AppPreferenceKey.hasCompletedOnboarding) == nil)
        #expect(defaults.object(forKey: AppPreferenceKey.hasAcknowledgedDisclaimer) == nil)
        #expect(defaults.object(forKey: AppPreferenceKey.disclaimerAcknowledgedAt) == nil)
    }

    @Test("Acknowledged completion persists the same three values as before")
    func acknowledgedComplete_persistsExistingSemantics() {
        let defaults = makeIsolatedDefaults()

        let completed = OnboardingQuickStart.complete(
            disclaimerAcknowledged: true,
            defaults: defaults,
            now: Self.fixedNow
        )

        #expect(completed)
        #expect(defaults.bool(forKey: AppPreferenceKey.hasCompletedOnboarding))
        #expect(defaults.bool(forKey: AppPreferenceKey.hasAcknowledgedDisclaimer))
        #expect(defaults.double(forKey: AppPreferenceKey.disclaimerAcknowledgedAt) == Self.fixedNow.timeIntervalSince1970)
        #expect(OnboardingQuickStart.shouldPresent(hasCompletedOnboarding: true) == false)
    }

    // MARK: Completion with no vehicle

    @Test("Completion needs no vehicle input")
    func completion_withNoVehicle_succeeds() {
        // The completion API has no vehicle parameter at all: acknowledgment alone is sufficient.
        #expect(
            OnboardingQuickStart.completion(disclaimerAcknowledged: true, now: Self.fixedNow)
                == .init(
                    hasCompletedOnboarding: true,
                    hasAcknowledgedDisclaimer: true,
                    disclaimerAcknowledgedAt: Self.fixedNow.timeIntervalSince1970
                )
        )
    }

    // MARK: Settings remain unchanged

    @Test("Completion leaves every other stored setting untouched")
    func completion_leavesOtherSettingsUnchanged() {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: AppPreferenceKey.showGarageTab)
        defaults.set(false, forKey: AppPreferenceKey.showRemindersTab)
        defaults.set(AppExperienceMode.simple.rawValue, forKey: AppPreferenceKey.appExperienceMode)
        defaults.set("unrelated-value", forKey: "OnboardingQuickStartTests.sentinel")

        let onboardingKeys: Set<String> = [
            AppPreferenceKey.hasCompletedOnboarding,
            AppPreferenceKey.hasAcknowledgedDisclaimer,
            AppPreferenceKey.disclaimerAcknowledgedAt
        ]
        let before = defaults.dictionaryRepresentation().filter { onboardingKeys.contains($0.key) == false }

        OnboardingQuickStart.complete(disclaimerAcknowledged: true, defaults: defaults, now: Self.fixedNow)

        let after = defaults.dictionaryRepresentation().filter { onboardingKeys.contains($0.key) == false }
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
        #expect(defaults.bool(forKey: AppPreferenceKey.showGarageTab) == false)
        #expect(defaults.bool(forKey: AppPreferenceKey.showRemindersTab) == false)
        #expect(defaults.string(forKey: AppPreferenceKey.appExperienceMode) == AppExperienceMode.simple.rawValue)
    }

    @Test("Completion on a fresh install does not create default settings keys")
    func completion_doesNotSeedDefaults() {
        let defaults = makeIsolatedDefaults()

        OnboardingQuickStart.complete(disclaimerAcknowledged: true, defaults: defaults, now: Self.fixedNow)

        #expect(defaults.object(forKey: AppPreferenceKey.showGarageTab) == nil)
        #expect(defaults.object(forKey: AppPreferenceKey.showRemindersTab) == nil)
        #expect(defaults.object(forKey: AppPreferenceKey.appExperienceMode) == nil)
    }

    // MARK: Returning users

    @Test("Returning user who already completed onboarding is not re-onboarded")
    func returningUser_isNotReonboarded() {
        let defaults = makeIsolatedDefaults()
        let originalAcknowledgedAt = 1_700_000_000.0
        defaults.set(true, forKey: AppPreferenceKey.hasCompletedOnboarding)
        defaults.set(true, forKey: AppPreferenceKey.hasAcknowledgedDisclaimer)
        defaults.set(originalAcknowledgedAt, forKey: AppPreferenceKey.disclaimerAcknowledgedAt)

        let stored = defaults.bool(forKey: AppPreferenceKey.hasCompletedOnboarding)

        #expect(OnboardingQuickStart.shouldPresent(hasCompletedOnboarding: stored) == false)
        // Nothing about deciding presentation rewrites the original acknowledgment timestamp.
        #expect(defaults.double(forKey: AppPreferenceKey.disclaimerAcknowledgedAt) == originalAcknowledgedAt)
        #expect(defaults.bool(forKey: AppPreferenceKey.hasAcknowledgedDisclaimer))
    }

    @Test("Reset Onboarding state presents onboarding again")
    func resetOnboarding_presentsAgain() {
        // Mirrors PreferencesView's Reset Onboarding, which sets the flag back to false.
        #expect(OnboardingQuickStart.shouldPresent(hasCompletedOnboarding: false))
    }

    // MARK: Dynamic Type layout

    @Test("Accessibility text sizes use the stacked, scrolling-footer layout")
    func accessibilitySizes_useStackedLayout() {
        #expect(OnboardingQuickStart.usesStackedLayout(isAccessibilitySize: true))
        #expect(OnboardingQuickStart.usesStackedLayout(isAccessibilitySize: false) == false)
    }
}
