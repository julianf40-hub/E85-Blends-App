// 85Blends 2.4.0 — Referral Reward Redemption. Pure resolution of "is this participant currently
// an active Pro subscriber, and if so, for which of the three supported products" from an
// already-fetched RevenueCat subscription list.
//
// Deliberately a SEPARATE file from entitlement.ts, not an extension of calculatePro: entitlement.ts
// is the already-reviewed, load-bearing source of `pro_is_active`/`pro_expires_at` for the
// canonical RevenueCat customer mirror (private.revenuecat_customers) and is never touched by this
// feature. This module answers a narrower, referral-reward-specific question calculatePro was never
// asked to answer — WHICH product — using the identical qualifying-subscription rule (`pro`
// entitlement + `gives_access === true`) so the two can never disagree about whether Pro is active,
// while keeping the "which product" logic isolated to the one feature that actually needs it.
//
// IMPORTANT RevenueCat API v2 detail: subscription.product_id is RevenueCat's INTERNAL product id,
// not the App Store product identifier. The store-facing identifier lives on the entitlement's
// embedded product object as product.store_identifier. Referral reward issuance must therefore map
// the active subscription's internal product id to that store_identifier before comparing against
// 85Blends' Apple product ids. Failing closed on missing/ambiguous mapping is intentional.
//
// Pure — no I/O, no Deno-specific APIs. Fully unit-testable under Node (see
// referral-active-product.test.ts).

import type { RevenueCatSubscription } from "./revenuecat-types.ts";
import { parseRevenueCatTimestamp } from "./entitlement.ts";

export const REFERRAL_REWARD_SUPPORTED_PRODUCT_IDS: readonly string[] = [
  "com.85blends.subscription.monthly",
  "com.85blends.subscription.threemonth",
  "com.85blends.subscription.annual",
];

export interface ActiveProProductResult {
  proIsActive: boolean;
  /** The STORE product id (Apple product identifier for App Store subscriptions) of the qualifying
   *  subscription with the latest expiration, when `proIsActive` is true — mirrors
   *  entitlement.ts's calculatePro tie-break rule exactly. `null` when Pro is inactive OR when the
   *  active subscription's RevenueCat-internal product id cannot be mapped unambiguously to a
   *  `store_identifier`. Never guesses/falls back to RevenueCat's internal id. */
  activeProductId: string | null;
}

function hasEntitlement(subscription: RevenueCatSubscription, lookupKey: string): boolean {
  const items = subscription.entitlements?.items;
  if (!Array.isArray(items)) return false;
  return items.some((entitlement) => entitlement?.lookup_key === lookupKey);
}

function givesAccess(subscription: RevenueCatSubscription): boolean {
  // Same deliberate `=== true` (never truthy) as entitlement.ts's own givesAccess — see that
  // file's header for why an absent/malformed value must never be treated as granting access.
  return subscription.gives_access === true;
}

function subscriptionExpiration(subscription: RevenueCatSubscription): Date | null {
  return parseRevenueCatTimestamp(subscription.ends_at) ?? parseRevenueCatTimestamp(subscription.current_period_ends_at);
}

function normalizedNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/**
 * RevenueCat API v2's subscription.product_id is an internal RevenueCat id. Resolve it to the
 * store-facing identifier from the embedded products on the SAME qualifying entitlement.
 *
 * There should be exactly one matching product object. If there are zero matches, a malformed
 * store_identifier, or conflicting duplicate matches, fail closed with null rather than guessing
 * which Apple subscription should receive a referral Offer Code.
 */
function subscriptionStoreProductId(
  subscription: RevenueCatSubscription,
  entitlementLookupKey: string,
): string | null {
  const revenueCatProductId = normalizedNonEmptyString(subscription.product_id);
  if (!revenueCatProductId) return null;

  const entitlements = subscription.entitlements?.items;
  if (!Array.isArray(entitlements)) return null;

  const matchedStoreIdentifiers = new Set<string>();
  for (const entitlement of entitlements) {
    if (entitlement?.lookup_key !== entitlementLookupKey) continue;
    const products = entitlement.products?.items;
    if (!Array.isArray(products)) continue;

    for (const product of products) {
      if (normalizedNonEmptyString(product?.id) !== revenueCatProductId) continue;
      const storeIdentifier = normalizedNonEmptyString(product?.store_identifier);
      if (storeIdentifier) matchedStoreIdentifiers.add(storeIdentifier);
    }
  }

  if (matchedStoreIdentifiers.size !== 1) return null;
  return [...matchedStoreIdentifiers][0];
}

/**
 * Resolves whether this participant currently has Pro, and if so, the STORE product id of their
 * active subscription — from a full, already environment-filtered subscription list (see
 * revenuecat-api.ts's fetchCustomerSubscriptions, the only production source of this input).
 * When more than one qualifying subscription exists (should not happen in practice for a single
 * customer, but never assumed away), the one with the LATEST expiration wins — identical tie-break
 * to entitlement.ts's calculatePro, so this can never report a DIFFERENT active state than the
 * canonical entitlement mirror would for the same raw data.
 */
export function resolveActiveProAndProduct(
  subscriptions: RevenueCatSubscription[],
  entitlementLookupKey: string = "pro",
): ActiveProProductResult {
  const qualifying = subscriptions.filter(
    (subscription) => hasEntitlement(subscription, entitlementLookupKey) && givesAccess(subscription),
  );

  if (qualifying.length === 0) {
    return { proIsActive: false, activeProductId: null };
  }

  let latestExpiration: Date | null = null;
  let activeProductId: string | null = null;
  for (const subscription of qualifying) {
    const expiration = subscriptionExpiration(subscription);
    if (expiration && (!latestExpiration || expiration.getTime() > latestExpiration.getTime())) {
      latestExpiration = expiration;
      activeProductId = subscriptionStoreProductId(subscription, entitlementLookupKey);
    }
  }
  // Defensive fallback: every qualifying subscription lacked a resolvable expiration (should not
  // happen for a real active subscription, but entitlement.ts's own calculatePro tolerates the
  // identical case for proIsActive) — resolve the FIRST qualifying subscription's store id rather
  // than choosing a different entitlement rule. Still fails closed if the internal->store mapping
  // itself is absent or ambiguous.
  if (activeProductId === null && latestExpiration === null) {
    activeProductId = subscriptionStoreProductId(qualifying[0], entitlementLookupKey);
  }

  return { proIsActive: true, activeProductId };
}

export function isSupportedReferralRewardProduct(productId: string | null): boolean {
  return productId !== null && REFERRAL_REWARD_SUPPORTED_PRODUCT_IDS.includes(productId);
}
