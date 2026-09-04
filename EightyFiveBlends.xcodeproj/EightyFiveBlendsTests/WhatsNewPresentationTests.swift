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
                onboardingJustCompletedThisLaunch: false,
                isRequiredConsentPresentationPending: false
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
                onboardingJustCompletedThisLaunch: false,
                isRequiredConsentPresentationPending: false
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
                onboardingJustCompletedThisLaunch: false,
                isRequiredConsentPresentationPending: false
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
                onboardingJustCompletedThisLaunch: false,
                isRequiredConsentPresentationPending: false
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
                onboardingJustCompletedThisLaunch: true,
                isRequiredConsentPresentationPending: false
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
                onboardingJustCompletedThisLaunch: true,
                isRequiredConsentPresentationPending: false
            ) == false
        )
    }

    // MARK: Required consent presentation pending (2.3.2 release-polish fix) → do not present yet

    @Test("Not presented while a required consent presentation (e.g. UMP) is still pending, even when every other condition favors presenting")
    func shouldPresent_requiredConsentPending_isFalse() {
        #expect(
            WhatsNewPresentation.shouldPresent(
                currentAppVersion: "2.3.2",
                lastPresentedVersion: "2.3.1",
                hasCompletedOnboarding: true,
                onboardingJustCompletedThisLaunch: false,
                isRequiredConsentPresentationPending: true
            ) == false
        )
    }

    @Test("Once required consent presentation is no longer pending, an otherwise-eligible user is presented")
    func shouldPresent_requiredConsentNoLongerPending_isTrue() {
        #expect(
            WhatsNewPresentation.shouldPresent(
                currentAppVersion: "2.3.2",
                lastPresentedVersion: "2.3.1",
                hasCompletedOnboarding: true,
                onboardingJustCompletedThisLaunch: false,
                isRequiredConsentPresentationPending: false
            )
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
                onboardingJustCompletedThisLaunch: false,
                isRequiredConsentPresentationPending: false
            )
        )
    }

    // MARK: - 85Blends 2.3.0 release-blocker fix: two-launch scenario walkthroughs
    //
    // ContentView.attemptWhatsNewPresentation() is SwiftUI/@AppStorage-coupled orchestration
    // outside these pure functions' reach (same class of gap already documented in
    // VehicleDraftTests/VehicleActivationTests) — verified by direct code inspection rather than
    // a unit test; see the final report. What IS directly testable, and exercised below, is the
    // exact sequence that method now performs: on the launch where onboarding completes, persist
    // versionToPersistOnDismiss(currentAppVersion) as lastPresentedWhatsNewVersion BEFORE calling
    // shouldPresent — then simulate a second, later launch reading that persisted value back.
    // isRequiredConsentPresentationPending is false throughout this section — these scenarios are
    // about version/onboarding sequencing, not the 2.3.2 consent-priority guard (covered above).

    @Test("CASE A — brand-new 2.3.0 user: does not get What's New on launch 2")
    func scenario_brandNewUser_doesNotGetWhatsNewOnLaunch2() {
        // Launch 1: onboarding completes this launch under 2.3.0.
        var lastPresented = ""
        let onboardingJustCompletedThisLaunch = true
        lastPresented = onboardingJustCompletedThisLaunch
            ? WhatsNewPresentation.versionToPersistOnDismiss(currentAppVersion: "2.3.0")
            : lastPresented
        let launch1ShouldPresent = WhatsNewPresentation.shouldPresent(
            currentAppVersion: "2.3.0",
            lastPresentedVersion: lastPresented,
            hasCompletedOnboarding: true,
            onboardingJustCompletedThisLaunch: onboardingJustCompletedThisLaunch,
            isRequiredConsentPresentationPending: false
        )
        #expect(launch1ShouldPresent == false) // suppressed this launch regardless

        // Launch 2: fresh launch, onboarding already complete, nothing just happened.
        let launch2ShouldPresent = WhatsNewPresentation.shouldPresent(
            currentAppVersion: "2.3.0",
            lastPresentedVersion: lastPresented,
            hasCompletedOnboarding: true,
            onboardingJustCompletedThisLaunch: false,
            isRequiredConsentPresentationPending: false
        )
        #expect(launch2ShouldPresent == false)
    }

    @Test("CASE B — existing 2.2.2 user upgrades to 2.3.0: sees What's New once, then never again for 2.3.0")
    func scenario_existingUpgrader_getsCurrentVersionOnce() {
        // At launch: already onboarded from a version that predates this feature.
        var lastPresented = ""
        let launch1ShouldPresent = WhatsNewPresentation.shouldPresent(
            currentAppVersion: "2.3.0",
            lastPresentedVersion: lastPresented,
            hasCompletedOnboarding: true,
            onboardingJustCompletedThisLaunch: false,
            isRequiredConsentPresentationPending: false
        )
        #expect(launch1ShouldPresent)

        // Dismissed — persists the version that was actually shown.
        lastPresented = WhatsNewPresentation.versionToPersistOnDismiss(currentAppVersion: "2.3.0")

        // Next launch: does not appear again.
        let launch2ShouldPresent = WhatsNewPresentation.shouldPresent(
            currentAppVersion: "2.3.0",
            lastPresentedVersion: lastPresented,
            hasCompletedOnboarding: true,
            onboardingJustCompletedThisLaunch: false,
            isRequiredConsentPresentationPending: false
        )
        #expect(launch2ShouldPresent == false)
    }

    @Test("CASE C — a user who onboarded under 2.3.0 later upgrades to 2.3.1: What's New in 2.3.1 remains eligible")
    func scenario_newUserOnboardedUnderCurrentVersion_stillGetsFutureVersionWhatsNew() {
        // Onboarded under 2.3.0 — the fix records 2.3.0 as already handled.
        let lastPresented = WhatsNewPresentation.versionToPersistOnDismiss(currentAppVersion: "2.3.0")

        // App later updates to 2.3.1.
        let shouldPresentForNewVersion = WhatsNewPresentation.shouldPresent(
            currentAppVersion: "2.3.1",
            lastPresentedVersion: lastPresented,
            hasCompletedOnboarding: true,
            onboardingJustCompletedThisLaunch: false,
            isRequiredConsentPresentationPending: false
        )
        #expect(shouldPresentForNewVersion)
    }

    @Test("Current version already recorded as handled → shouldPresent is false")
    func scenario_currentVersionAlreadyHandled_isFalse() {
        let lastPresented = WhatsNewPresentation.versionToPersistOnDismiss(currentAppVersion: "2.3.0")
        #expect(
            WhatsNewPresentation.shouldPresent(
                currentAppVersion: "2.3.0",
                lastPresentedVersion: lastPresented,
                hasCompletedOnboarding: true,
                onboardingJustCompletedThisLaunch: false,
                isRequiredConsentPresentationPending: false
            ) == false
        )
    }

    // MARK: - 2.3.2 release-polish: consent-priority retry scenario

    @Test("CASE D — existing user upgrades, but UMP consent is still resolving on first launch: What's New waits, then presents once consent resolves on a later attempt within the same launch")
    func scenario_consentPendingThenResolved_presentsOnceConsentClears() {
        let lastPresented = ""

        // First attempt (e.g. ContentView's .onAppear): consent is still being gathered.
        let firstAttemptShouldPresent = WhatsNewPresentation.shouldPresent(
            currentAppVersion: "2.3.2",
            lastPresentedVersion: lastPresented,
            hasCompletedOnboarding: true,
            onboardingJustCompletedThisLaunch: false,
            isRequiredConsentPresentationPending: true
        )
        #expect(firstAttemptShouldPresent == false)

        // Second attempt (e.g. ContentView's .onChange once AdManager reports resolution done),
        // same launch, nothing else about the user's state changed.
        let secondAttemptShouldPresent = WhatsNewPresentation.shouldPresent(
            currentAppVersion: "2.3.2",
            lastPresentedVersion: lastPresented,
            hasCompletedOnboarding: true,
            onboardingJustCompletedThisLaunch: false,
            isRequiredConsentPresentationPending: false
        )
        #expect(secondAttemptShouldPresent)
    }
}
