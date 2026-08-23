// 85Blends 2.3.0 — Phase B1. Canonical Pro calculation from RevenueCat API v2 subscription data.
//
// Pure — no I/O, no Deno-specific APIs. Operates only on already-fetched subscription objects
// (see revenuecat-api.ts for how they're fetched). Fully unit-testable under Node — see
// entitlement.test.ts.
//
// Per the task spec's canonical-state design decision: this is the ONLY place that decides
// pro_is_active. The webhook event's own type/fields are never used as the entitlement decision
// (see revenuecat-webhook-parser.ts, which never reports an entitlement boolean at all) — only
// `gives_access` + entitlement `lookup_key` from a fresh RevenueCat API response.

import type { RevenueCatSubscription } from "./revenuecat-types.ts";

export const PRO_ENTITLEMENT_LOOKUP_KEY = "pro";

export interface EntitlementCalculationResult {
  proIsActive: boolean;
  /** `null` when there is no active Pro subscription, or no resolvable expiration timestamp. */
  proExpiresAt: Date | null;
}

function hasEntitlement(subscription: RevenueCatSubscription, lookupKey: string): boolean {
  const items = subscription.entitlements?.items;
  if (!Array.isArray(items)) return false;
  return items.some((entitlement) => entitlement?.lookup_key === lookupKey);
}

function givesAccess(subscription: RevenueCatSubscription): boolean {
  // Deliberately `=== true`, not truthy — an absent/malformed gives_access must never be treated
  // as granting access. RevenueCat's own model is explicit here (see Phase 14 of the task spec):
  // never infer access from `status === "active"` alone, and never fail open on ambiguous data.
  return subscription.gives_access === true;
}

/**
 * Parses a RevenueCat API timestamp field defensively: RevenueCat's v2 API documentation was not
 * re-verified live in this environment (see supabase/README.md's Phase B1 limitations note), so
 * this accepts either an ISO 8601 string or an epoch-milliseconds number rather than assuming one
 * shape. Returns `null` for anything else, including `undefined`/`null`/malformed strings — never
 * throws, and never silently produces an invalid Date.
 */
export function parseRevenueCatTimestamp(value: unknown): Date | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
  }
  if (typeof value === "string" && value.trim().length > 0) {
    const parsedMs = Date.parse(value);
    return Number.isNaN(parsedMs) ? null : new Date(parsedMs);
  }
  return null;
}

/**
 * The one subscription-level expiration signal used for `pro_expires_at`: prefer `ends_at`
 * (RevenueCat's documented "actual/effective end" field per the task spec), falling back to
 * `current_period_ends_at` only when `ends_at` isn't present/parseable.
 */
function subscriptionExpiration(subscription: RevenueCatSubscription): Date | null {
  return parseRevenueCatTimestamp(subscription.ends_at) ?? parseRevenueCatTimestamp(subscription.current_period_ends_at);
}

/**
 * Computes `pro_is_active`/`pro_expires_at` from a full, already environment-filtered list of a
 * customer's subscriptions. `pro_is_active` is true iff at least one subscription both carries
 * the `pro` entitlement (by lookup_key) and has `gives_access === true` — this single rule
 * correctly covers trials, grace periods, billing retry, and "cancelled but still paid through
 * period end" without needing to special-case any of those states individually (see Phase 14).
 */
export function calculatePro(
  subscriptions: RevenueCatSubscription[],
  entitlementLookupKey: string = PRO_ENTITLEMENT_LOOKUP_KEY,
): EntitlementCalculationResult {
  const qualifying = subscriptions.filter(
    (subscription) => hasEntitlement(subscription, entitlementLookupKey) && givesAccess(subscription),
  );

  if (qualifying.length === 0) {
    return { proIsActive: false, proExpiresAt: null };
  }

  let latestExpiration: Date | null = null;
  for (const subscription of qualifying) {
    const expiration = subscriptionExpiration(subscription);
    if (expiration && (!latestExpiration || expiration.getTime() > latestExpiration.getTime())) {
      latestExpiration = expiration;
    }
  }

  return { proIsActive: true, proExpiresAt: latestExpiration };
}
