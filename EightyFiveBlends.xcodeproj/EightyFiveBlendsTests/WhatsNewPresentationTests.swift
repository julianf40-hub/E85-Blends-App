//
//  WhatsNewPresentationTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rules behind the version-aware "What's New" popup. These are the
//  actual functions ContentView calls (WhatsNewPresentation.shouldPresent,
//  versionToPersistOnDismiss) — not a duplicate reimplementation — so passing tests here directly
//  verify production behavior.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.

import Testing
@testable import EightyFiveBlends

struct WhatsNewPresentationTests {

    // MARK: Current version already presented → no presentation

    @Test("Matching last-presented version never presents again")
    func shouldPresent_versionAlreadyPresented_isFalse() {
        #expect(
            WhatsNewPresentation.shouldPresent(
                currentAppVersion: "2.3.0",
                lastPresentedVersion: "2.3.0",
                hasCompletedOnboarding: true,
                onboardingJustCompletedThisLaunch: false
            ) == false
        )
    }

    // MARK: Current version not presented + existing user → present

    @Test("An existing user on a new version, who did not just onboard, is presented")
    func shouldPresent_newVersionExistingUser_isTrue() {
        #expect(
            WhatsNewPresentation.shouldPresent(
                currentAppVersion: "2.3.0",
                lastPresentedVersion: "2.2.2",
                hasCompletedOnboarding: true,
                onboardingJustCompletedThisLaunch: false
            )
        )
    }

    @Test("An existing user upgrading from a version that predates this feature (empty last-presented version) is presented")
    func shouldPresent_neverPresentedBefore_existingUser_isTrue() {
        #expect(
            WhatsNewPresentation.shouldPresent(
                currentAppVersion: "2.3.0",
                lastPresentedVersion: "",
                hasCompletedOnboarding: true,
                onboardingJustCompletedThisLaunch: false
            )
        )
    }

    // MARK: Onboarding incomplete → do not present

    @Test("Never presented while onboarding is incomplete, regardless of version state")
    func shouldPresent_onboardingIncomplete_isFalse() {
        #expect(
            WhatsNewPresentation.shouldPresent(
                currentAppVersion: "2.3.0",
                lastPresentedVersion: "",
                hasCompletedOnboarding: false,
                onboardingJustCompletedThisLaunch: false
            ) == false
        )
    }

    // MARK: Fresh install (just completed onboarding this launch) → do not present

    @Test("Not presented immediately after onboarding completes in the same launch")
    func shouldPresent_onboardingJustCompletedThisLaunch_isFalse() {
        #expect(
            WhatsNewPresentation.shouldPresent(
                currentAppVersion: "2.3.0",
                lastPresentedVersion: "",
                hasCompletedOnboarding: true,
                onboardingJustCompletedThisLaunch: true
            ) == false
        )
    }

    @Test("onboardingJustCompletedThisLaunch suppresses presentation even when the version genuinely differs")
    func shouldPresent_onboardingJustCompletedThisLaunch_overridesVersionMismatch() {
        #expect(
            WhatsNewPresentation.shouldPresent(
                currentAppVersion: "2.3.0",
                lastPresentedVersion: "2.2.2",
                hasCompletedOnboarding: true,
                onboardingJustCompletedThisLaunch: true
            ) == false
        )
    }

    // MARK: After dismissal → current version stored

    @Test("The value persisted on dismissal is always the version that was actually shown")
    func versionToPersistOnDismiss_returnsCurrentAppVersion() {
        #expect(WhatsNewPresentation.versionToPersistOnDismiss(currentAppVersion: "2.3.0") == "2.3.0")
        #expect(WhatsNewPresentation.versionToPersistOnDismiss(currentAppVersion: "2.4.1") == "2.4.1")
    }

    // MARK: Future versions become eligible automatically, without new presentation logic

    @Test("A future version (e.g. 3.0.0) not yet presented is eligible using the exact same rule as any other version")
    func shouldPresent_futureVersion_worksWithoutCodeChanges() {
        #expect(
            WhatsNewPresentation.shouldPresent(
                currentAppVersion: "3.0.0",
                lastPresentedVersion: "2.4.1",
                hasCompletedOnboarding: true,
                onboardingJustCompletedThisLaunch: false
            )
        )
    }
}
