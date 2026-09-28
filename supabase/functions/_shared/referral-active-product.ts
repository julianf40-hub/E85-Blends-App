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
  /** The product id of the qualifying subscription with the latest expiration, when `proIsActive`
   *  is true — mirrors entitlement.ts's calculatePro's own tie-break rule exactly, so "which
   *  subscription is THE active one" is decided identically everywhere this codebase asks. `null`
   *  when `proIsActive` is false, OR when true but every qualifying subscription's own `product_id`
   *  field is missing/malformed (never guessed — see referral-api/index.ts's claim_reward handler,
   *  which treats this exactly like "active product unknown" and fails the claim safely rather than
   *  ever issuing a code for a guessed product). This is independent of whether that product is one
   *  of the three this feature actually supports — see `isSupportedReferralRewardProduct` below for
   *  that separate check (a legacy-quarterly active subscriber IS reported here, with their real
   *  product id, so the caller can fail safely with a specific "legacy product active" outcome
   *  rather than a generic "unknown").
   */
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

function subscriptionProductId(subscription: RevenueCatSubscription): string | null {
  const raw = subscription.product_id;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/**
 * Resolves whether this participant currently has Pro, and if so, the product id of their active
 * subscription — from a full, already environment-filtered subscription list (see
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
      activeProductId = subscriptionProductId(subscription);
    }
  }
  // Defensive fallback: every qualifying subscription lacked a resolvable expiration (should not
  // happen for a real active subscription, but entitlement.ts's own calculatePro tolerates the
  // identical case for proIsActive) — report the FIRST qualifying subscription's product id rather
  // than none at all, since proIsActive is still unambiguously true here.
  if (activeProductId === null && latestExpiration === null) {
    activeProductId = subscriptionProductId(qualifying[0]);
  }

  return { proIsActive: true, activeProductId };
}

export function isSupportedReferralRewardProduct(productId: string | null): boolean {
  return productId !== null && REFERRAL_REWARD_SUPPORTED_PRODUCT_IDS.includes(productId);
}
