import Foundation
import Testing
import WidgetKit
@testable import EightyFiveBlends

//  85Blends 2.4.0 — Nearby E85 widget Pro gate.
//
//  Every test here drives the actual production types (the App-Group store, the publisher's pure
//  mirroring rule / transition rule / publish + reset steps, the app-side entitlement route and
//  pending-URL gate, the Provider's access-gated builders, the access-aware widget URL, the non-Pro
//  copy, and the two AppIntents' injectable bodies) through their injectable seams — an isolated
//  UserDefaults suite per test, a counting closure in place of WidgetCenter, a failing loader in
//  place of the Provider's Pro-only reads — so nothing touches the real App Group, a live widget
//  host, RevenueCat, or any shared singleton. No test mutates `SubscriptionManager.shared`: the
//  Developer Pro Override is covered by composing its own pure rule (`effectivePro`) with the
//  publisher's pure rule (`mirroredStatus`), which is exactly how `isPro` feeds
//  `mirroredStatus(for:)` in production.
//
//  What this file cannot prove (same limits as SubscriptionManagerTests' header): that
//  EightyFiveBlendsApp's `.onChange(of:initial:)` actually fires on a real CustomerInfo application,
//  that `mirroredStatus(for:)`/`resolve(for:)` read the right `SubscriptionManager` properties (a
//  three-line, directly-inspectable adapter), or that a real Home Screen widget re-renders on
//  `WidgetCenter.reloadTimelines` — those are call-site facts verified by code inspection and the
//  on-device TestFlight matrix.

// MARK: - App-Group store

struct NearbyE85WidgetAccessStoreTests {
    private func isolatedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: "nearby-e85-access-test-\(UUID().uuidString)")
    }
    private func isolatedStore() -> NearbyE85WidgetAccessStore { NearbyE85WidgetAccessStore(defaults: isolatedDefaults()) }

    @Test func nothingStoredReadsAsUnknownNeverFree() {
        let store = isolatedStore()
        #expect(store.read() == .unknown)
        #expect(store.read().status == .unknown)
        #expect(store.read().status != .free)
    }

    @Test func freeWriteThenReadRoundTrips() {
        let store = isolatedStore()
        let writtenAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(store.write(NearbyE85WidgetAccessState(status: .free, updatedAt: writtenAt)))
        let state = store.read()
        #expect(state.status == .free)
        #expect(state.version == NearbyE85WidgetAccessState.currentVersion)
        #expect(abs(state.updatedAt.timeIntervalSince(writtenAt)) < 1)
    }

    @Test func proWriteThenReadRoundTrips() {
        let store = isolatedStore()
        let writtenAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(store.write(NearbyE85WidgetAccessState(status: .pro, updatedAt: writtenAt)))
        let state = store.read()
        #expect(state.status == .pro)
        #expect(state.version == NearbyE85WidgetAccessState.currentVersion)
        #expect(abs(state.updatedAt.timeIntervalSince(writtenAt)) < 1)
    }

    @Test func freeToProAndProToFreeBothChangeTheReadValue() {
        let store = isolatedStore()
        store.write(NearbyE85WidgetAccessState(status: .free, updatedAt: .now))
        #expect(store.read().status == .free)
        store.write(NearbyE85WidgetAccessState(status: .pro, updatedAt: .now))
        #expect(store.read().status == .pro)
        store.write(NearbyE85WidgetAccessState(status: .free, updatedAt: .now))
        #expect(store.read().status == .free)
    }

    @Test func missingAppGroupReadsAsUnknownAndWriteReportsFailureRatherThanCrashing() {
        let store = NearbyE85WidgetAccessStore(defaults: nil)
        #expect(store.write(NearbyE85WidgetAccessState(status: .pro, updatedAt: .now)) == false)
        #expect(store.read() == .unknown)
        #expect(store.clear() == false) // harmless no-op
        #expect(store.read() == .unknown)
    }

    @Test func corruptBytesReadAsUnknown() {
        let defaults = isolatedDefaults()
        defaults?.set(Data("definitely not json".utf8), forKey: NearbyE85WidgetAccessStore.key)
        #expect(NearbyE85WidgetAccessStore(defaults: defaults).read() == .unknown)
    }

    @Test func wrongTypeUnderTheKeyReadsAsUnknown() {
        let defaults = isolatedDefaults()
        defaults?.set("pro", forKey: NearbyE85WidgetAccessStore.key)
        #expect(NearbyE85WidgetAccessStore(defaults: defaults).read() == .unknown)
        defaults?.set(true, forKey: NearbyE85WidgetAccessStore.key)
        #expect(NearbyE85WidgetAccessStore(defaults: defaults).read() == .unknown)
    }

    @Test func unrecognisedStatusRawValueReadsAsUnknown() {
        // A well-formed payload from some hypothetical future build whose status vocabulary this
        // binary doesn't know — must fail closed to "unknown," never be coerced to either side.
        let defaults = isolatedDefaults()
        let json = #"{"version":1,"status":"lifetime","updatedAt":0}"#
        defaults?.set(Data(json.utf8), forKey: NearbyE85WidgetAccessStore.key)
        #expect(NearbyE85WidgetAccessStore(defaults: defaults).read() == .unknown)
    }

    @Test func unrecognisedVersionReadsAsUnknownEvenWithAValidStatus() {
        let store = isolatedStore()
        store.write(NearbyE85WidgetAccessState(version: NearbyE85WidgetAccessState.currentVersion + 1,
                                               status: .pro, updatedAt: .now))
        #expect(store.read() == .unknown)
    }

    // MARK: clear() — "did the widget-visible status change?"

    @Test func clearAfterProReturnsToUnknownAndReportsAChange() {
        let store = isolatedStore()
        store.write(NearbyE85WidgetAccessState(status: .pro, updatedAt: .now))
        #expect(store.clear())
        #expect(store.read() == .unknown)
    }

    @Test func clearAfterFreeReturnsToUnknownAndReportsAChange() {
        let store = isolatedStore()
        store.write(NearbyE85WidgetAccessState(status: .free, updatedAt: .now))
        #expect(store.clear())
        #expect(store.read() == .unknown)
    }

    @Test func clearWhenNothingIsStoredIsAHarmlessNoChange() {
        let store = isolatedStore()
        #expect(store.clear() == false)
        #expect(store.read() == .unknown)
        #expect(store.clear() == false) // and again — idempotent
    }

    @Test func clearRemovesUndecodableBytesButReportsNoVisibleChange() {
        // Corrupt bytes already read as .unknown, so removing them changes nothing the widget can
        // see — but they are still removed, so the key doesn't stay poisoned.
        let defaults = isolatedDefaults()
        defaults?.set(Data("garbage".utf8), forKey: NearbyE85WidgetAccessStore.key)
        let store = NearbyE85WidgetAccessStore(defaults: defaults)
        #expect(store.clear() == false)
        #expect(defaults?.object(forKey: NearbyE85WidgetAccessStore.key) == nil)
        #expect(store.read() == .unknown)
    }

    @Test func persistedPayloadContainsOnlyVersionStatusAndUpdatedAt() throws {
        // The "no PII / no product / no plan / no customer ID" rule, held to the actual bytes.
        let defaults = isolatedDefaults()
        NearbyE85WidgetAccessStore(defaults: defaults).write(NearbyE85WidgetAccessState(status: .pro, updatedAt: .now))
        let data = try #require(defaults?.data(forKey: NearbyE85WidgetAccessStore.key))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "status", "updatedAt"])
        #expect(object["status"] as? String == "pro")
    }
}

// MARK: - Status semantics

struct NearbyE85WidgetAccessStatusTests {
    @Test func onlyProPermitsWidgetInteraction() {
        #expect(NearbyE85WidgetAccessStatus.pro.permitsWidgetInteraction)
        #expect(NearbyE85WidgetAccessStatus.free.permitsWidgetInteraction == false)
        // The load-bearing half of "unknown is never Free" — it is also never Pro.
        #expect(NearbyE85WidgetAccessStatus.unknown.permitsWidgetInteraction == false)
    }
}

// MARK: - Publisher: mirroring rule

struct NearbyE85WidgetAccessMirroringRuleTests {
    @Test func nothingIsMirroredBeforeAnyAuthoritativeAnswer() {
        // Cold launch before RevenueCat answers, or a launch where the fetch failed: mirror nothing.
        #expect(NearbyE85WidgetAccessPublisher.mirroredStatus(isPro: false, hasAuthoritativeProStatus: false, isDebugProOverrideActive: false) == nil)
        // `isPro == true` without an authoritative answer is unreachable in production (revenueCatIsPro
        // is only ever set inside apply(_:)) — but the rule still refuses to mirror it, by construction.
        #expect(NearbyE85WidgetAccessPublisher.mirroredStatus(isPro: true, hasAuthoritativeProStatus: false, isDebugProOverrideActive: false) == nil)
    }

    @Test func authoritativeAnswersMirrorExactly() {
        #expect(NearbyE85WidgetAccessPublisher.mirroredStatus(isPro: false, hasAuthoritativeProStatus: true, isDebugProOverrideActive: false) == .free)
        #expect(NearbyE85WidgetAccessPublisher.mirroredStatus(isPro: true, hasAuthoritativeProStatus: true, isDebugProOverrideActive: false) == .pro)
    }

    @Test func theAppNeverMirrorsUnknown() {
        // Exhaustive over every input combination: the rule's only outputs are nil, .free, .pro.
        for isPro in [false, true] {
            for authoritative in [false, true] {
                for override in [false, true] {
                    let status = NearbyE85WidgetAccessPublisher.mirroredStatus(
                        isPro: isPro, hasAuthoritativeProStatus: authoritative, isDebugProOverrideActive: override)
                    #expect(status != .unknown)
                }
            }
        }
    }

    #if DEBUG || INTERNAL_BUILD
    // The Developer Pro Override, WITHOUT touching SubscriptionManager.shared: `effectivePro` is the
    // exact rule `SubscriptionManager.isPro` applies in Internal/Debug builds, and `override != .off`
    // is exactly `isDebugProOverrideActive`. Composing the two here is composing what
    // `mirroredStatus(for:)` reads in production — minus the singleton and its persisted state.
    private func mirrored(override: SubscriptionManager.DebugProOverride, revenueCatIsPro: Bool,
                          hasAuthoritativeProStatus: Bool) -> NearbyE85WidgetAccessStatus? {
        NearbyE85WidgetAccessPublisher.mirroredStatus(
            isPro: SubscriptionManager.effectivePro(override: override, revenueCatIsPro: revenueCatIsPro),
            hasAuthoritativeProStatus: hasAuthoritativeProStatus,
            isDebugProOverrideActive: override != .off)
    }

    @Test func forceProMirrorsProImmediatelyEvenBeforeRevenueCatAnswers() {
        #expect(mirrored(override: .forcePro, revenueCatIsPro: false, hasAuthoritativeProStatus: false) == .pro)
        // ...and still wins once RevenueCat has answered Free.
        #expect(mirrored(override: .forcePro, revenueCatIsPro: false, hasAuthoritativeProStatus: true) == .pro)
    }

    @Test func forceFreeMirrorsFreeImmediatelyEvenBeforeRevenueCatAnswers() {
        #expect(mirrored(override: .forceFree, revenueCatIsPro: true, hasAuthoritativeProStatus: false) == .free)
        // ...and still wins once RevenueCat has answered Pro.
        #expect(mirrored(override: .forceFree, revenueCatIsPro: true, hasAuthoritativeProStatus: true) == .free)
    }

    @Test func overrideOffWithAnAuthoritativeAnswerMirrorsTheRealValue() {
        #expect(mirrored(override: .off, revenueCatIsPro: true, hasAuthoritativeProStatus: true) == .pro)
        #expect(mirrored(override: .off, revenueCatIsPro: false, hasAuthoritativeProStatus: true) == .free)
    }

    @Test func overrideOffWithNoAuthoritativeAnswerMirrorsNothing() {
        // nil here is what `transition(previous:current:)` turns into either .hold (production /
        // launch) or .resetDebugForcedMirror (an override was just removed) — see the tests below.
        #expect(mirrored(override: .off, revenueCatIsPro: false, hasAuthoritativeProStatus: false) == nil)
        #expect(mirrored(override: .off, revenueCatIsPro: true, hasAuthoritativeProStatus: false) == nil)
    }
    #endif
}

// MARK: - Publisher: transition rule (what a previous → current change means for the App Group)

struct NearbyE85WidgetAccessTransitionTests {
    @Test func aCurrentValueAlwaysMeansPublish() {
        for previous: NearbyE85WidgetAccessStatus? in [nil, .free, .pro] {
            #expect(NearbyE85WidgetAccessPublisher.transition(previous: previous, current: .pro) == .publish(.pro))
            #expect(NearbyE85WidgetAccessPublisher.transition(previous: previous, current: .free) == .publish(.free))
        }
    }

    @Test func nilToNilHoldsWhateverIsMirrored() {
        // Production's cold launch before RevenueCat answers, and a failed refresh, both land here
        // (as does the `initial: true` launch call, where previous == current): nothing changes.
        #expect(NearbyE85WidgetAccessPublisher.transition(previous: nil, current: nil) == .hold)
    }

    #if DEBUG || INTERNAL_BUILD
    @Test func aValueToNilTransitionIsARemovedDebugOverrideAndResetsTheMirror() {
        // The only way a value can go back to nil: hasAuthoritativeProStatus is forward-only, so
        // this is a Force Pro / Force Free being switched Off before RevenueCat has answered.
        #expect(NearbyE85WidgetAccessPublisher.transition(previous: .pro, current: nil) == .resetDebugForcedMirror)
        #expect(NearbyE85WidgetAccessPublisher.transition(previous: .free, current: nil) == .resetDebugForcedMirror)
    }
    #endif
    // Production (`#else`): `.resetDebugForcedMirror` does not exist as a case at all, so a value →
    // nil transition can only be `.hold` — a compile-time fact, not something a DEBUG-compiled test
    // binary can execute.
}

// MARK: - Publisher: publish / sync / reset — the reload matrix

@MainActor
struct NearbyE85WidgetAccessPublisherTests {
    private func isolatedStore() -> NearbyE85WidgetAccessStore {
        NearbyE85WidgetAccessStore(defaults: UserDefaults(suiteName: "nearby-e85-access-publish-\(UUID().uuidString)"))
    }
    private func seed(_ store: NearbyE85WidgetAccessStore, _ status: NearbyE85WidgetAccessStatus?) {
        if let status { store.write(NearbyE85WidgetAccessState(status: status, updatedAt: .now)) }
    }

    @Test func publishReloadsExactlyWhenTheWidgetVisibleStatusChanges() {
        // (what is already mirrored, what is published) → reloads. nil = nothing mirrored yet.
        let matrix: [(String, NearbyE85WidgetAccessStatus?, NearbyE85WidgetAccessStatus, Int)] = [
            ("missing -> free", nil, .free, 1),
            ("missing -> pro", nil, .pro, 1),
            ("free -> pro", .free, .pro, 1),
            ("pro -> free", .pro, .free, 1),
            ("pro -> pro", .pro, .pro, 0),
            ("free -> free", .free, .free, 0),
        ]
        for (name, initial, published, expectedReloads) in matrix {
            let store = isolatedStore()
            seed(store, initial)
            var reloads = 0
            let didPublish = NearbyE85WidgetAccessPublisher.publish(published, store: store, now: .now) { reloads += 1 }
            #expect(reloads == expectedReloads, "\(name): expected \(expectedReloads) reload(s), got \(reloads)")
            #expect(didPublish == (expectedReloads == 1), "\(name)")
            #expect(store.read().status == published, "\(name)")
        }
    }

    @Test func publishOfAnUnchangedStatusDoesNotEvenTouchUpdatedAt() {
        let store = isolatedStore()
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let later = first.addingTimeInterval(3600)
        var reloads = 0
        NearbyE85WidgetAccessPublisher.publish(.pro, store: store, now: first) { reloads += 1 }
        // A stable Pro subscriber's every foreground refresh lands here: no write, no reload.
        #expect(NearbyE85WidgetAccessPublisher.publish(.pro, store: store, now: later) { reloads += 1 } == false)
        #expect(reloads == 1)
        #expect(abs(store.read().updatedAt.timeIntervalSince(first)) < 1)
    }

    @Test func aFailedRefreshCanNeverDowngradeAPreviouslyMirroredPro() {
        // Last launch mirrored .pro. This launch, the first CustomerInfo fetch FAILS: SubscriptionManager
        // then reads isPro == false (the safe default) and hasAuthoritativeProStatus == false. The
        // rule returns nil, the transition is .hold, nothing is published, and the widget keeps
        // rendering as Pro.
        let store = isolatedStore()
        seed(store, .pro)
        var reloads = 0
        let afterFailedRefresh = NearbyE85WidgetAccessPublisher.mirroredStatus(
            isPro: false, hasAuthoritativeProStatus: false, isDebugProOverrideActive: false)
        #expect(afterFailedRefresh == nil)
        // previous == current == nil: the `initial: true` launch call's shape.
        #expect(NearbyE85WidgetAccessPublisher.sync(previous: afterFailedRefresh, current: afterFailedRefresh, store: store) { reloads += 1 } == false)
        #expect(store.read().status == .pro)
        #expect(reloads == 0)
    }

    @Test func syncPublishesOnAValueAndHoldsOnNil() {
        let store = isolatedStore()
        var reloads = 0
        #expect(NearbyE85WidgetAccessPublisher.sync(previous: nil, current: .free, store: store) { reloads += 1 })
        #expect(store.read().status == .free)
        #expect(reloads == 1)
        #expect(NearbyE85WidgetAccessPublisher.sync(previous: .free, current: .pro, store: store) { reloads += 1 })
        #expect(store.read().status == .pro)
        #expect(reloads == 2)
        #expect(NearbyE85WidgetAccessPublisher.sync(previous: .pro, current: .pro, store: store) { reloads += 1 } == false)
        #expect(reloads == 2)
        #expect(NearbyE85WidgetAccessPublisher.sync(previous: nil, current: nil, store: store) { reloads += 1 } == false)
        #expect(store.read().status == .pro) // held, not cleared
        #expect(reloads == 2)
    }

    @Test func publishNeverReloadsWhenTheAppGroupWriteFails() {
        // Nothing the widget can see changed, so no reload is spent.
        var reloads = 0
        #expect(NearbyE85WidgetAccessPublisher.publish(.pro, store: NearbyE85WidgetAccessStore(defaults: nil), now: .now) { reloads += 1 } == false)
        #expect(NearbyE85WidgetAccessPublisher.sync(previous: nil, current: .pro, store: NearbyE85WidgetAccessStore(defaults: nil)) { reloads += 1 } == false)
        #expect(reloads == 0)
    }

    #if DEBUG || INTERNAL_BUILD
    @Test func removingADebugOverrideBeforeRevenueCatAnswersClearsTheForcedMirrorWithOneReload() {
        for forced in [NearbyE85WidgetAccessStatus.pro, .free] {
            let store = isolatedStore()
            var reloads = 0
            // Force Pro / Force Free while unresolved: mirrored immediately.
            #expect(NearbyE85WidgetAccessPublisher.sync(previous: nil, current: forced, store: store) { reloads += 1 })
            #expect(store.read().status == forced)
            #expect(reloads == 1)
            // Override → Off, still no authoritative answer: mirroredStatus is now nil.
            #expect(NearbyE85WidgetAccessPublisher.sync(previous: forced, current: nil, store: store) { reloads += 1 })
            #expect(store.read() == .unknown)
            #expect(reloads == 2)
        }
    }

    @Test func removingADebugOverrideOnceRevenueCatHasAnsweredPublishesTheRealValueInstead() {
        // Force Pro, then RevenueCat answers Free (still forced → .pro), then Off → the authoritative
        // .free is published; nothing is ever cleared.
        let store = isolatedStore()
        var reloads = 0
        NearbyE85WidgetAccessPublisher.sync(previous: nil, current: .pro, store: store) { reloads += 1 }
        #expect(NearbyE85WidgetAccessPublisher.sync(previous: .pro, current: .free, store: store) { reloads += 1 })
        #expect(store.read().status == .free)
        #expect(reloads == 2)
    }

    @Test func resettingAnAlreadyUnknownMirrorSpendsNoReload() {
        let store = isolatedStore()
        var reloads = 0
        #expect(NearbyE85WidgetAccessPublisher.resetDebugForcedMirror(store: store) { reloads += 1 } == false)
        #expect(NearbyE85WidgetAccessPublisher.resetDebugForcedMirror(store: NearbyE85WidgetAccessStore(defaults: nil)) { reloads += 1 } == false)
        #expect(reloads == 0)
    }
    #endif
}

// MARK: - App-side deep-link entitlement route

struct NearbyE85WidgetEntitlementRouteTests {
    @Test func anUnresolvedEntitlementWaitsRatherThanPaywalling() {
        #expect(NearbyE85WidgetEntitlementRoute.resolve(isPro: false, hasAuthoritativeProStatus: false, isDebugProOverrideActive: false) == .waitForEntitlement)
    }

    @Test func aCompletedButFailedFirstFetchStillWaitsItIsNotAConfirmedFree() {
        // The critical distinction: `isInitialEntitlementResolutionPending == false` (the first
        // attempt has COMPLETED) together with `hasAuthoritativeProStatus == false` (it FAILED — no
        // real CustomerInfo was ever applied) and `isProUser == false` (the safe default). This is
        // "we still don't actually know Free vs Pro", and it must never present the paywall.
        // `isInitialEntitlementResolutionPending` is deliberately NOT an input to this rule at all
        // (it is reached on a failed fetch too — see InitialEntitlementResolutionState.resolved),
        // so its value cannot turn this case into .presentProPaywall — only a real CustomerInfo
        // (hasAuthoritativeProStatus) can.
        #expect(NearbyE85WidgetEntitlementRoute.resolve(isPro: false, hasAuthoritativeProStatus: false, isDebugProOverrideActive: false) == .waitForEntitlement)
        #expect(NearbyE85WidgetEntitlementRoute.resolve(isPro: false, hasAuthoritativeProStatus: false, isDebugProOverrideActive: false) != .presentProPaywall)
    }

    @Test func aSuccessfulCustomerInfoWithNoProPresentsThePaywall() {
        #expect(NearbyE85WidgetEntitlementRoute.resolve(isPro: false, hasAuthoritativeProStatus: true, isDebugProOverrideActive: false) == .presentProPaywall)
    }

    @Test func aSuccessfulCustomerInfoWithProAllowsTheWidgetRoute() {
        #expect(NearbyE85WidgetEntitlementRoute.resolve(isPro: true, hasAuthoritativeProStatus: true, isDebugProOverrideActive: false) == .allowWidgetRoute)
    }

    @Test func aProUserIsNeverBlockedOrPaywalled() {
        #expect(NearbyE85WidgetEntitlementRoute.resolve(isPro: true, hasAuthoritativeProStatus: true, isDebugProOverrideActive: false) == .allowWidgetRoute)
        #expect(NearbyE85WidgetEntitlementRoute.resolve(isPro: true, hasAuthoritativeProStatus: false, isDebugProOverrideActive: true) == .allowWidgetRoute)
    }

    @Test func developerOverrideDecidesImmediately() {
        #expect(NearbyE85WidgetEntitlementRoute.resolve(isPro: true, hasAuthoritativeProStatus: false, isDebugProOverrideActive: true) == .allowWidgetRoute)
        #expect(NearbyE85WidgetEntitlementRoute.resolve(isPro: false, hasAuthoritativeProStatus: false, isDebugProOverrideActive: true) == .presentProPaywall)
    }

    @Test func mirroredStatusMappingIsExhaustiveAndUnknownHolds() {
        #expect(NearbyE85WidgetEntitlementRoute.resolve(mirroredStatus: nil) == .waitForEntitlement)
        #expect(NearbyE85WidgetEntitlementRoute.resolve(mirroredStatus: .unknown) == .waitForEntitlement)
        #expect(NearbyE85WidgetEntitlementRoute.resolve(mirroredStatus: .free) == .presentProPaywall)
        #expect(NearbyE85WidgetEntitlementRoute.resolve(mirroredStatus: .pro) == .allowWidgetRoute)
    }
}

// MARK: - Pending widget URL lifecycle (the pure half of ContentView.openPendingWidgetLink)

struct NearbyE85WidgetLinkGateTests {
    private let tappedURL = NearbyE85DeepLink.stationsURL()

    @Test func nothingPendingIsAlwaysAHoldWithNothingToDo() {
        for route in [NearbyE85WidgetEntitlementRoute.waitForEntitlement, .presentProPaywall, .allowWidgetRoute] {
            #expect(NearbyE85WidgetLinkGate.advance(pendingURL: nil, route: route) == .init(pendingURL: nil, action: .hold))
        }
    }

    @Test func anUnknownEntitlementHoldsTheSameURLIntact() {
        let step = NearbyE85WidgetLinkGate.advance(pendingURL: tappedURL, route: .waitForEntitlement)
        #expect(step.action == .hold)
        #expect(step.pendingURL == tappedURL)
    }

    @Test func unknownWidgetTapThenRevenueCatAnswersProRoutesTheOriginalTapExactlyOnce() {
        // 1-4. Tap arrives while the entitlement is unknown: held, URL intact.
        var pending: URL? = tappedURL
        var step = NearbyE85WidgetLinkGate.advance(pendingURL: pending, route: .waitForEntitlement)
        pending = step.pendingURL
        #expect(step.action == .hold)
        #expect(pending == tappedURL)
        // A failed first fetch changes nothing (route stays .waitForEntitlement): still held, not cleared.
        step = NearbyE85WidgetLinkGate.advance(pendingURL: pending, route: .waitForEntitlement)
        pending = step.pendingURL
        #expect(step.action == .hold)
        #expect(pending == tappedURL)
        // 5-8a. CustomerInfo succeeds as Pro: the SAME URL is retried and routed.
        step = NearbyE85WidgetLinkGate.advance(pendingURL: pending, route: .allowWidgetRoute)
        pending = step.pendingURL
        #expect(step.action == .route)
        #expect(pending == nil)
        // 9. Consumed exactly once: a further attempt (any later route change) does nothing.
        step = NearbyE85WidgetLinkGate.advance(pendingURL: pending, route: .allowWidgetRoute)
        #expect(step == .init(pendingURL: nil, action: .hold))
    }

    @Test func unknownWidgetTapThenRevenueCatAnswersFreePresentsThePaywallExactlyOnce() {
        var pending: URL? = tappedURL
        var step = NearbyE85WidgetLinkGate.advance(pendingURL: pending, route: .waitForEntitlement)
        pending = step.pendingURL
        #expect(step.action == .hold)
        #expect(pending == tappedURL)
        // 8b. CustomerInfo succeeds as Free: consumed, paywall — and NO widget route.
        step = NearbyE85WidgetLinkGate.advance(pendingURL: pending, route: .presentProPaywall)
        pending = step.pendingURL
        #expect(step.action == .presentPaywall)
        #expect(pending == nil)
        // 9. Consumed exactly once.
        step = NearbyE85WidgetLinkGate.advance(pendingURL: pending, route: .presentProPaywall)
        #expect(step == .init(pendingURL: nil, action: .hold))
    }

    @Test func aProTapThatArrivesAfterResolutionRoutesImmediately() {
        let step = NearbyE85WidgetLinkGate.advance(pendingURL: tappedURL, route: .allowWidgetRoute)
        #expect(step == .init(pendingURL: nil, action: .route))
    }

    @Test func aDirectionsURLIsHeldOrConsumedIdenticallyToAStationsURL() {
        // The gate never looks inside the URL — it holds/consumes whatever was tapped.
        let directions = NearbyE85DeepLink.directionsURL(stationID: "mobil")
        #expect(NearbyE85WidgetLinkGate.advance(pendingURL: directions, route: .waitForEntitlement).pendingURL == directions)
        #expect(NearbyE85WidgetLinkGate.advance(pendingURL: directions, route: .presentProPaywall) == .init(pendingURL: nil, action: .presentPaywall))
        #expect(NearbyE85WidgetLinkGate.advance(pendingURL: directions, route: .allowWidgetRoute) == .init(pendingURL: nil, action: .route))
    }
}

// MARK: - Provider: the non-Pro path is data-free

@MainActor
struct NearbyE85ProviderAccessGateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var readySnapshot: NearbyE85Snapshot {
        let station = NearbyE85Station(id: "mobil", name: "Mobil", address: "123 Main St", latitude: 33.45, longitude: -112.07,
                                       distanceMiles: 0.6, price: .init(dollarsPerGallon: 3.90, reportedAt: now, source: .community))
        return .make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now,
                     userLatitude: 33.44, userLongitude: -112.08)
    }
    /// Pro inputs that would be unmistakable if they ever leaked: a ready snapshot with a station, a
    /// non-default zoom, and a pending refresh inside the in-progress window.
    private var leakyInputs: NearbyE85Provider.ProInputs {
        .init(snapshot: readySnapshot, zoomLevel: .zoomedIn4, mapRender: nil, pendingRefreshAt: now)
    }

    private func assertDataFree(_ entry: NearbyE85Entry, access: NearbyE85WidgetAccessStatus) {
        #expect(entry.access == access)
        #expect(entry.date == now)
        #expect(entry.snapshot == nil)
        #expect(entry.snapshot?.stations == nil)                  // no station identity reachable
        #expect(entry.snapshot?.userCoordinate == nil)            // no user location reachable
        #expect(entry.mapRender == nil)
        #expect(entry.zoomLevel == .default)                      // never the user's stored zoom
        #expect(entry.isRefreshing == false)
        for family in [WidgetFamily.systemSmall, .systemMedium, .systemLarge] {
            // The widget-level tap can only ever be the generic Stations link — never a
            // station-derived directions URL.
            let url = NearbyE85WidgetURLResolver.widgetURL(family: family, snapshot: entry.snapshot, access: entry.access)
            #expect(NearbyE85DeepLink.parse(url) == .stations)
        }
    }

    @Test func aLockedEntryAndTimelineCarryNoStationDataMapZoomRefreshStateOrDirectionsLink() {
        for access in [NearbyE85WidgetAccessStatus.free, .unknown] {
            assertDataFree(NearbyE85Provider.lockedEntry(access: access, now: now), access: access)
            let timeline = NearbyE85Provider.lockedTimeline(access: access, now: now)
            #expect(timeline.entries.count == 1)
            for entry in timeline.entries { assertDataFree(entry, access: access) }
        }
    }

    @Test func aNonProRenderNeverLoadsTheProOnlyInputs() async {
        // The loader wraps every Pro-only read the Provider performs (station cache + location
        // authorization, zoom store, MKMapSnapshotter render, pending-refresh flag). For .free and
        // .unknown it must never be invoked at all — and even if it somehow were, the leaky inputs
        // it would return must not surface in the entry.
        for access in [NearbyE85WidgetAccessStatus.free, .unknown] {
            var loads = 0
            let entry = await NearbyE85Provider.entry(access: access, now: now) {
                loads += 1
                Issue.record("Pro inputs were loaded for a \(access.rawValue) snapshot render")
                return leakyInputs
            }
            let timeline = await NearbyE85Provider.timeline(access: access, now: now) {
                loads += 1
                Issue.record("Pro inputs were loaded for a \(access.rawValue) timeline render")
                return leakyInputs
            }
            #expect(loads == 0)
            assertDataFree(entry, access: access)
            #expect(timeline.entries.count == 1)
            for entry in timeline.entries { assertDataFree(entry, access: access) }
        }
    }

    @Test func aProRenderLoadsTheInputsExactlyOnceAndUsesThem() async {
        // The positive control for the test above, and a regression check on the moved Pro path.
        var loads = 0
        let entry = await NearbyE85Provider.entry(access: .pro, now: now) { loads += 1; return leakyInputs }
        #expect(loads == 1)
        #expect(entry.access == .pro)
        #expect(entry.snapshot == readySnapshot)
        #expect(entry.zoomLevel == .zoomedIn4)
        #expect(entry.isRefreshing) // pendingRefreshAt == now is inside NearbyE85RefreshFeedback.window

        let timeline = await NearbyE85Provider.timeline(access: .pro, now: now) { loads += 1; return leakyInputs }
        #expect(loads == 2)
        #expect(timeline.entries.isEmpty == false)
        #expect(timeline.entries.first?.date == now)
        #expect(timeline.entries.allSatisfy { $0.access == .pro })
        #expect(timeline.entries.allSatisfy { $0.zoomLevel == .zoomedIn4 })
        #expect(timeline.entries.first?.snapshot == readySnapshot)
        // Entries are ascending and unique, exactly as the pre-gate scheduling produced them.
        let dates = timeline.entries.map(\.date)
        #expect(dates == dates.sorted())
        #expect(Set(dates).count == dates.count)
    }
}

// MARK: - Widget-level tap target

struct NearbyE85WidgetURLResolverAccessTests {
    private let now = Date.now
    private var readySnapshot: NearbyE85Snapshot {
        let station = NearbyE85Station(id: "nearest", name: "Mobil", address: "Address", latitude: 33.45, longitude: -112.07,
                                       distanceMiles: 0.6, price: nil)
        return .make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now)
    }

    @Test func aNonProShellAlwaysOpensStationsNeverDirections() {
        // Even Small with a ready snapshot attached (which a locked entry never has in production —
        // this is the defensive case): no directions link can leak out of a locked/verify shell.
        for access in [NearbyE85WidgetAccessStatus.free, .unknown] {
            for family in [WidgetFamily.systemSmall, .systemMedium, .systemLarge] {
                let url = NearbyE85WidgetURLResolver.widgetURL(family: family, snapshot: readySnapshot, access: access)
                #expect(NearbyE85DeepLink.parse(url) == .stations)
            }
        }
    }

    @Test func proDelegatesToTheExistingRuleUnchanged() {
        for family in [WidgetFamily.systemSmall, .systemMedium, .systemLarge] {
            for snapshot: NearbyE85Snapshot? in [readySnapshot, nil] {
                #expect(NearbyE85WidgetURLResolver.widgetURL(family: family, snapshot: snapshot, access: .pro)
                        == NearbyE85WidgetURLResolver.widgetURL(family: family, snapshot: snapshot))
            }
        }
        #expect(NearbyE85DeepLink.parse(NearbyE85WidgetURLResolver.widgetURL(family: .systemSmall, snapshot: readySnapshot, access: .pro))
                == .directions(stationID: "nearest"))
    }
}

// MARK: - Non-Pro copy

struct NearbyE85WidgetAccessCopyTests {
    @Test func theUnverifiedShellNeverReadsAsFreeExpiredOrAnUpsell() {
        // `.unknown` is just as true for a Pro subscriber on a fresh install as for anyone else.
        let forbidden = ["free", "expired", "unlock", "purchase", "upgrade", "subscribe", "locked", "trial"]
        for string in NearbyE85WidgetAccessCopy.unverifiedStrings {
            let lowered = string.lowercased()
            for word in forbidden {
                #expect(lowered.contains(word) == false, "\"\(string)\" must not contain \"\(word)\"")
            }
        }
    }

    @Test func theLockedShellNamesProAndTellsTheUserToOpenTheApp() {
        #expect(NearbyE85WidgetAccessCopy.proName == "85Blends Pro")
        #expect(NearbyE85WidgetAccessCopy.lockedAvailability.contains("85Blends Pro"))
        #expect(NearbyE85WidgetAccessCopy.smallLockedAction.contains("Open 85Blends"))
        #expect(NearbyE85WidgetAccessCopy.lockedAction.contains("Open 85Blends"))
    }
}

// MARK: - AppIntents (refresh / zoom) — no-ops unless Pro

struct NearbyE85IntentAccessGateTests {
    @Test func theRefreshIntentIsACompleteNoOpUnlessPro() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for access in [NearbyE85WidgetAccessStatus.free, .unknown] {
            let requestStore = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-gate-refresh-\(UUID().uuidString)"))
            var reloads = 0
            #expect(NearbyE85RefreshIntent.handle(access: access, requestStore: requestStore, now: now) { reloads += 1 } == false)
            #expect(requestStore.pendingRequestDate() == nil) // the app will never refresh location on a locked widget's behalf
            #expect(reloads == 0)
        }

        let requestStore = NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-gate-refresh-\(UUID().uuidString)"))
        var reloads = 0
        #expect(NearbyE85RefreshIntent.handle(access: .pro, requestStore: requestStore, now: now) { reloads += 1 })
        #expect(abs((requestStore.pendingRequestDate() ?? .distantPast).timeIntervalSince(now)) < 1)
        #expect(reloads == 1)
    }

    @Test func theZoomIntentsAreCompleteNoOpsUnlessPro() {
        for access in [NearbyE85WidgetAccessStatus.free, .unknown] {
            let zoomStore = NearbyE85MapZoomStore(defaults: UserDefaults(suiteName: "nearby-e85-gate-zoom-\(UUID().uuidString)"))
            var reloads = 0
            #expect(NearbyE85ZoomIntentHandler.handle(.zoomIn, access: access, zoomStore: zoomStore) { reloads += 1 } == false)
            #expect(NearbyE85ZoomIntentHandler.handle(.zoomOut, access: access, zoomStore: zoomStore) { reloads += 1 } == false)
            #expect(zoomStore.read() == .default)
            #expect(reloads == 0)
        }

        let zoomStore = NearbyE85MapZoomStore(defaults: UserDefaults(suiteName: "nearby-e85-gate-zoom-\(UUID().uuidString)"))
        var reloads = 0
        #expect(NearbyE85ZoomIntentHandler.handle(.zoomIn, access: .pro, zoomStore: zoomStore) { reloads += 1 })
        #expect(zoomStore.read() == NearbyE85MapZoomLevel.default.zoomedInOneStep())
        #expect(reloads == 1)
    }
}
