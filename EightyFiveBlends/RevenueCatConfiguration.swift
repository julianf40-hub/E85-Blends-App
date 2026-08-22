//
//  RevenueCatConfiguration.swift
//  EightyFiveBlends
//
//  Public SDK key plumbing for RevenueCat, 85Blends' authoritative subscription entitlement
//  source (see RevenueCatSubscriptionService.swift for the integration itself, and that file's
//  own header for the full public-vs-secret key distinction). Mirrors SupabaseConfig.swift's
//  established load()/blank-is-missing pattern, this app's one other externally-configured
//  integration.
//
//  Internal (com.e85blends.app.ios.internal) and Debug+Release (both com.e85blends.app.ios)
//  carry different bundle IDs and therefore need separate RevenueCat "app" entries — and so
//  separate public SDK keys — in RevenueCat's dashboard. Selected here, once, centrally, via the
//  same #if INTERNAL_BUILD flag SubscriptionManager.debugProOverride already uses for the same
//  Internal-vs-everything-else distinction, rather than scattering bundle-ID checks through
//  application code.
//

import Foundation

enum RevenueCatConfiguration {
    /// The Info.plist key this build reads. Both keys are checked into the repo as empty-string
    /// placeholders (see Info.plist) — real values are supplied at build/config time, never
    /// invented here. An empty or missing value is treated identically to "not configured" (see
    /// `publicSDKKey` below), which is what keeps a missing key safe: nothing in this app throws
    /// or crashes when this returns `nil` — RevenueCat simply never configures, and
    /// `RevenueCatSubscriptionService.revenueCatIsPro` stays at its safe default of `false`
    /// (Free) rather than any code guessing at entitlement.
    private static var infoPlistKeyName: String {
        #if INTERNAL_BUILD
        "REVENUECAT_PUBLIC_SDK_KEY_INTERNAL"
        #else
        "REVENUECAT_PUBLIC_SDK_KEY_PRODUCTION"
        #endif
    }

    /// `nil` if the key is missing or blank. Never throws — a missing key must only ever result
    /// in RevenueCat staying unconfigured (and the user seeing Free), never crash app launch or
    /// wedge any other feature. See `RevenueCatSubscriptionService.configureIfNeeded()`, the only
    /// caller.
    static var publicSDKKey: String? {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: infoPlistKeyName) as? String,
            raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        return raw
    }
}
