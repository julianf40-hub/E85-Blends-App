//
//  AdManagerTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rule behind AdManager's centralized ad-readiness gate
//  (AdManager.canRequestAds(isAdsEnabled:isEntitlementResolutionPending:consentAllowsAdRequests:))
//  — the actual function the instance property `AdManager.shared.canRequestAds` calls, not a
//  duplicate reimplementation, so passing tests here directly verify production behavior. The
//  instance property itself (and `gatherConsent()`, `configureIfNeeded()`) read live
//  SubscriptionManager/ConsentInformation singleton state and are not exercised here — see
//  AdManager.swift's own header for why the decision rule is split out this way, mirroring
//  errorDescription(forAdapterStates:)'s existing precedent in the same file.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  2.3.2 public-release-readiness context: this gate is what Components/NativeAdView.swift's
//  `.task` checks before ever calling `loader.loadIfNeeded()` — see that file's `.task` and
//  AdManager.swift's header for the full "why centralized, not duplicated per placement"
//  reasoning. All three inputs must independently allow ads; this file pins that truth table.
//

import Testing
@testable import EightyFiveBlends

struct AdManagerTests {

    @Test("All three conditions favorable: ads are allowed")
    func canRequestAds_allFavorable_isTrue() {
        #expect(AdManager.canRequestAds(
            isAdsEnabled: true,
            isEntitlementResolutionPending: false,
            consentAllowsAdRequests: true
        ) == true)
    }

    @Test("Pro user (isAdsEnabled false): ads are never allowed, regardless of the other two flags")
    func canRequestAds_proUser_isAlwaysFalse() {
        #expect(AdManager.canRequestAds(
            isAdsEnabled: false,
            isEntitlementResolutionPending: false,
            consentAllowsAdRequests: true
        ) == false)
        #expect(AdManager.canRequestAds(
            isAdsEnabled: false,
            isEntitlementResolutionPending: true,
            consentAllowsAdRequests: true
        ) == false)
    }

    @Test("Entitlement resolution still pending: ads are not allowed even if everything else is favorable — a pending read must never be treated as \"definitely Free\"")
    func canRequestAds_entitlementResolutionPending_isFalse() {
        #expect(AdManager.canRequestAds(
            isAdsEnabled: true,
            isEntitlementResolutionPending: true,
            consentAllowsAdRequests: true
        ) == false)
    }

    @Test("UMP consent does not yet allow ad requests: ads are not allowed even if Pro status and entitlement resolution are both favorable")
    func canRequestAds_consentNotYetAllowed_isFalse() {
        #expect(AdManager.canRequestAds(
            isAdsEnabled: true,
            isEntitlementResolutionPending: false,
            consentAllowsAdRequests: false
        ) == false)
    }

    @Test("All three conditions unfavorable: ads are not allowed")
    func canRequestAds_allUnfavorable_isFalse() {
        #expect(AdManager.canRequestAds(
            isAdsEnabled: false,
            isEntitlementResolutionPending: true,
            consentAllowsAdRequests: false
        ) == false)
    }
}
