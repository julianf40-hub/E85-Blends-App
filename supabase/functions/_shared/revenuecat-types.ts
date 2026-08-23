// 85Blends 2.3.0 — Phase B1. Shared RevenueCat type definitions.
//
// Plain type-only module — no runtime dependencies, no Deno-specific APIs. Types are
// deliberately permissive (lots of `unknown`/optional fields) because RevenueCat's webhook
// payload and API v2 responses are NOT fully re-verified against live documentation in this
// environment (see supabase/README.md's "Phase B1 known limitations" section) and because
// Phase 8 requires tolerating unknown/future fields rather than rejecting on them.

/** The two RevenueCat environments this app cares about, exactly as RevenueCat's webhook sends them. */
export type RevenueCatWebhookEnvironment = "SANDBOX" | "PRODUCTION";

/** The lowercase form RevenueCat's REST API v2 expects as a query parameter. */
export type RevenueCatApiEnvironment = "sandbox" | "production";

/**
 * Maps a webhook-shaped environment string to the API's query-parameter casing. Returns `null`
 * for anything that isn't exactly one of the two known values — callers must treat that as
 * "insufficient data," never guess.
 */
export function toApiEnvironment(value: unknown): RevenueCatApiEnvironment | null {
  if (value === "SANDBOX") return "sandbox";
  if (value === "PRODUCTION") return "production";
  return null;
}

export function isValidWebhookEnvironment(value: unknown): value is RevenueCatWebhookEnvironment {
  return value === "SANDBOX" || value === "PRODUCTION";
}

/** The raw top-level envelope RevenueCat POSTs: `{ api_version, event }`. */
export interface RevenueCatWebhookEnvelope {
  api_version?: unknown;
  event?: unknown;
}

/**
 * The minimal fields every RevenueCat webhook event is expected to carry, regardless of type.
 * Everything else is read defensively, field-by-field, from the raw `unknown` event object —
 * see revenuecat-webhook-parser.ts.
 */
export interface RevenueCatWebhookEventCore {
  id: string;
  type: string;
  event_timestamp_ms: number;
}

/** One page of RevenueCat API v2's subscriptions list response. */
export interface RevenueCatSubscriptionsPage {
  items: RevenueCatSubscription[];
  next_page: string | null;
}

export interface RevenueCatSubscription {
  /** Whether RevenueCat says the customer should currently receive access via this subscription. */
  gives_access?: unknown;
  status?: unknown;
  ends_at?: unknown;
  current_period_ends_at?: unknown;
  entitlements?: {
    items?: RevenueCatEntitlementRef[];
  };
  [key: string]: unknown;
}

export interface RevenueCatEntitlementRef {
  lookup_key?: unknown;
  [key: string]: unknown;
}

/** Outcome of fetching the canonical subscription state for one (app_user_id, environment) pair. */
export type RevenueCatApiResult =
  | { kind: "ok"; subscriptions: RevenueCatSubscription[] }
  /** RevenueCat has no record of this exact ID — treated as "no subscriptions," not a failure. */
  | { kind: "not_found" }
  /** Transient/upstream failure — caller must not mutate entitlement state and should let the
   *  webhook be retried. */
  | { kind: "retryable_error"; statusCategory: string; detail: string }
  /** Our own configuration/auth is wrong (401/403) — also must not mutate entitlement state. */
  | { kind: "config_error"; statusCategory: string; detail: string };
