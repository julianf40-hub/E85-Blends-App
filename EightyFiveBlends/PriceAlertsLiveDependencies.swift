//
//  PriceAlertsLiveDependencies.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). The production implementations of the
//  Price Alerts seams — everything that touches an Apple framework or another feature's singleton —
//  and the app's one PriceAlertsService built from them. Deliberately free of decisions: each type is
//  a thin pass-through whose logic is tested elsewhere against a fake (the entitlement mapping
//  through PriceAlertsEntitlementProviding, and so on). The real Keychain is SystemKeychain.swift.
//
//  Nothing in this file runs at launch. `PriceAlertsService.shared` is a lazily initialized static
//  that nothing references until a future Price Alerts screen does, and even then constructing it
//  reads no Keychain item, makes no request, asks for no permission and creates no installation.
//
//  WHAT IT REUSES, UNCHANGED
//    - SubscriptionManager (the single Pro source of truth) — read only; no purchase, restore or
//      RevenueCat behavior is touched.
//    - The referral feature's RevenueCat identity and verified App Store environment providers
//      (ReferralRevenueCatIdentityProviding / ReferralRevenueEnvironmentProviding). They are generic
//      — the anonymous RevenueCat App User ID and the verified SANDBOX/PRODUCTION answer — and carry
//      subtle rules (verified-only, bounded wait) that must not be duplicated.
//    - PushRegistrationService.shared, Phase 2's APNs token capture.
//    - SupabaseConfig, for the Supabase URL and the client-safe key already shipped in Info.plist.
//

import Foundation

// MARK: - Entitlement

/// Maps SubscriptionManager onto the three answers Price Alerts needs. `canAccessStationAlerts` is
/// the feature-level gate that already exists for this feature (it routes through `isPro`), so the
/// Developer Pro Override in Debug/Internal builds applies here exactly as it does to every other Pro
/// gate. NOTE that the override changes only this CLIENT answer: the backend decides Pro from
/// RevenueCat itself, so a forced-Pro dev build is refused by `set_alert` unless RevenueCat agrees
/// (surfaced as `proRequiredByServer`).
struct SubscriptionManagerEntitlementProvider: PriceAlertsEntitlementProviding {
    var entitlement: PriceAlertsEntitlement {
        let subscriptions = SubscriptionManager.shared
        if subscriptions.canAccessStationAlerts {
            return .active
        }
        // A false `isPro` is only "Free" once RevenueCat has genuinely answered.
        return subscriptions.hasAuthoritativeProStatus ? .inactive : .unresolved
    }
}

// MARK: - RevenueCat identity

/// The RevenueCat App User ID and the verified store environment, as `bootstrap` wants them. `nil`
/// until both are known; never a placeholder.
struct LivePriceAlertsRevenueCatIdentityProvider: PriceAlertsRevenueCatIdentityProviding {
    var identityProvider: any ReferralRevenueCatIdentityProviding = LiveReferralRevenueCatIdentityProvider()
    var environmentProvider: any ReferralRevenueEnvironmentProviding = StoreKitReferralRevenueEnvironmentProvider()

    func currentIdentity() async -> PriceAlertsRevenueCatIdentity? {
        guard let appUserID = identityProvider.currentAppUserID() else { return nil }
        guard let storeEnvironment = await environmentProvider.currentEnvironment(),
              let environment = PriceAlertsRevenueCatEnvironment(rawValue: storeEnvironment.rawValue)
        else { return nil }
        return PriceAlertsRevenueCatIdentity(appUserID: appUserID, environment: environment)
    }
}

// MARK: - The app's service

extension PriceAlertsService {
    /// The app's single Price Alerts service. Nothing references it at launch; a Price Alerts screen
    /// does, when the user opens one.
    static let shared = PriceAlertsService.make(
        transport: URLSessionPriceAlertsTransport(),
        credentialStore: KeychainPriceAlertsCredentialStore(keychain: SystemKeychain()),
        revenueCatIdentity: LivePriceAlertsRevenueCatIdentityProvider(),
        push: PushRegistrationService.shared,
        metadata: BundlePushDeviceRegistrationMetadataProvider(),
        registrationRecords: UserDefaultsPriceAlertsDeviceRegistrationRecordStore(),
        entitlement: SubscriptionManagerEntitlementProvider(),
        appVersion: { PriceAlertsAppVersion.current() }
    )
}
