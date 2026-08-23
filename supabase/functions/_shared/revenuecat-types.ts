// 85Blends 2.3.0 — Phase B1. Shared RevenueCat type definitions.
//
// Plain type-only module — no runtime dependencies, no Deno-specific APIs.
//
// Field shapes below (`gives_access`, `environment`, `ends_at`, `current_period_ends_at`,
// `entitlements.items[].lookup_key`, `next_page`) are now verified against RevenueCat's current
// API v2 documentation (see the Phase B1 review-repair report). Timestamps are documented as
// integer milliseconds; defensive ISO-8601-string parsing is still kept in entitlement.ts as a
// harmless fallback, not because the shape is in doubt. Fields stay typed as `unknown` rather
// than their documented type and objects keep an index signature so unrecognized/future fields
// are tolerated rather than rejected (Phase 8).

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

/**
 * Normalizes a subscription object's own `environment` field to the API's lowercase form,
 * case-insensitively (RevenueCat's documented casing for this specific field was not
 * independently re-confirmed against a live response in this environment — accepting either
 * casing is a deliberately conservative choice: it never masks a genuine cross-environment leak,
 * since a real leak would carry the *other* environment's value, not merely different casing of
 * the *same* one). Returns `null` for anything else, including missing/malformed values — callers
 * must treat `null` as "cannot verify this item's environment," never as an implicit match.
 */
export function normalizeApiEnvironment(value: unknown): RevenueCatApiEnvironment | null {
  if (typeof value !== "string") return null;
  const lower = value.toLowerCase();
  return lower === "sandbox" || lower === "production" ? (lower as RevenueCatApiEnvironment) : null;
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
  /** sandbox/production, as reported by RevenueCat on the subscription itself — see
   *  normalizeApiEnvironment(). Every returned subscription is validated against the
   *  environment that was actually requested before it's ever used for entitlement (Phase B1
   *  review Finding 1) — defense in depth beyond the request's own `environment` query param, in
   *  case a pagination cursor ever silently drops that filter. */
  environment?: unknown;
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
  /** Transient/upstream failure — caller must not mutate entitlement state and should let the
   *  webhook be retried. Also covers 404 ("customer not found"): for a webhook RevenueCat itself
   *  just sent us, a 404 is not strong enough evidence to revoke an existing Pro entitlement — see
   *  the Phase B1 review report's Finding 2. There is deliberately no separate "not_found" /
   *  "treat as empty" result kind; a genuinely empty subscription list is represented as
   *  `{ kind: "ok", subscriptions: [] }` (a successful 200 with `items: []`), which is the only
   *  path that may ever compute Free from an empty list. */
  | { kind: "retryable_error"; statusCategory: string; detail: string }
  /** Our own configuration/auth is wrong (401/403) — also must not mutate entitlement state. */
  | { kind: "config_error"; statusCategory: string; detail: string };
