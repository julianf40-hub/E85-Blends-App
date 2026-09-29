// 85Blends 2.3.0 — Phase B1. RevenueCat REST API v2 client — canonical subscription refresh.
//
// Uses only standard Fetch API primitives (`fetch`, `AbortController`, `URL`, `Headers`) — no
// Deno-specific APIs. `fetchImpl` is injectable (defaults to the global `fetch`), so the
// pagination/validation/error-classification logic here is directly unit-testable under Node
// with a stub fetch — see revenuecat-api.test.ts. This module never touches Postgres, never
// touches the webhook's own auth secrets, and is the ONLY place in this function that calls out
// to RevenueCat's servers.
//
// Response shape (`gives_access`, `entitlements.items[].lookup_key`, `ends_at`,
// `current_period_ends_at`, `environment`, pagination via `next_page`) is verified against
// RevenueCat's current API v2 documentation — see the Phase B1 review-repair report.
//
// ENVIRONMENT SAFETY (Phase B1 review Finding 1): 85Blends must never let a SANDBOX request
// collect PRODUCTION subscriptions or vice versa. Three independent layers enforce this:
//   1. Every page's URL — not just the first — has `environment=<requested>` explicitly
//      (re-)set before it is fetched, even when following a `next_page` cursor.
//   2. A followed `next_page` must resolve to the EXACT SAME pathname as the original request
//      (same project, same customer, same "subscriptions" resource) — not merely "some /v2/..."
//      path — so a cursor can never silently redirect this call to a different customer or
//      resource.
//   3. Every individual subscription item returned on every page has its own `environment` field
//      checked against the requested environment before being accepted into the result — if
//      RevenueCat's cursor ever drops the filter server-side despite (1)/(2), this catches it at
//      the data level instead of trusting the request layer alone.
//
// 85Blends 2.4.0 referral reward active-product resolution: RevenueCat API v2's subscription
// `product_id` is RevenueCat's INTERNAL product id, not Apple's store product identifier. The
// customer-subscriptions response is sufficient to decide whether Pro is active, but live testing
// showed its embedded entitlement product expansion is not reliable enough to identify the store
// product on every response. For an active `pro` subscription only, this client therefore resolves
// the same subscription's entitlements through the customer-information endpoint
// `/subscriptions/{subscription_id}/entitlements`, then maps the internal product id to that
// entitlement product's `store_identifier`. This endpoint uses the same
// `customer_information:subscriptions:read` permission already required by the subscription list,
// avoiding a separate Project Configuration permission. Mapping failure is non-fatal to canonical
// entitlement refresh: the referral resolver simply fails closed and refuses to issue a plan-
// specific reward until the mapping is available. A small module cache avoids repeated lookups of
// immutable product metadata on a warm Edge Function instance.

import {
  normalizeApiEnvironment,
  type RevenueCatApiEnvironment,
  type RevenueCatApiResult,
  type RevenueCatSubscription,
  type RevenueCatSubscriptionsPage,
} from "./revenuecat-types.ts";

const API_ORIGIN = "https://api.revenuecat.com";
const API_BASE_PATH = "/v2";
const PAGE_LIMIT = 100;
/** Defensive cap per Phase 12 — prevents an unbounded loop if `next_page` never terminates. */
const MAX_PAGES = 10;
const DEFAULT_TIMEOUT_MS = 10_000;
const productStoreIdentifierCache = new Map<string, string>();

export interface RevenueCatApiClientConfig {
  projectId: string;
  secretApiKey: string;
  /** Injected for testability — defaults to the runtime's global `fetch`. */
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

/**
 * Resolves a `next_page` value against the current request URL, verifies it still points at the
 * EXACT SAME `https://api.revenuecat.com` pathname the original request used (never merely "some
 * path under /v2/"), then forces `environment`/`limit` back onto it regardless of whatever the
 * cursor itself carried — per Phase B1 review Finding 1, a returned cursor URL must never be
 * trusted to have preserved the originally requested environment.
 */
function resolveAndValidateNextPage(
  nextPage: string,
  currentUrl: URL,
  expectedPathname: string,
  environment: RevenueCatApiEnvironment,
): URL | null {
  let resolved: URL;
  try {
    resolved = new URL(nextPage, currentUrl);
  } catch {
    return null;
  }
  if (resolved.origin !== API_ORIGIN) return null;
  if (resolved.pathname !== expectedPathname) return null;

  resolved.searchParams.set("environment", environment);
  resolved.searchParams.set("limit", String(PAGE_LIMIT));
  return resolved;
}

function buildInitialUrl(projectId: string, appUserId: string, environment: RevenueCatApiEnvironment): URL {
  const url = new URL(
    `${API_BASE_PATH}/projects/${encodeURIComponent(projectId)}/customers/${encodeURIComponent(appUserId)}/subscriptions`,
    API_ORIGIN,
  );
  url.searchParams.set("environment", environment);
  url.searchParams.set("limit", String(PAGE_LIMIT));
  return url;
}

function isPlausibleSubscriptionsPage(value: unknown): value is RevenueCatSubscriptionsPage {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return Array.isArray(record.items);
}

function normalizedNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function isActiveProSubscription(subscription: RevenueCatSubscription): boolean {
  if (subscription.gives_access !== true) return false;
  const entitlements = subscription.entitlements?.items;
  return Array.isArray(entitlements) && entitlements.some((entitlement) => entitlement?.lookup_key === "pro");
}

/**
 * Resolves one RevenueCat-internal Product id to its store-facing identifier by asking for the
 * entitlements attached to the SAME active subscription. This stays inside RevenueCat's Customer
 * Information permission domain (`customer_information:subscriptions:read`), which the existing
 * customer-subscriptions lookup already requires.
 *
 * Never throws and never exposes response bodies/errors to callers. A failure is simply `null`;
 * canonical entitlement refresh must not be made dependent on this secondary product-metadata
 * lookup.
 */
async function fetchStoreProductIdentifierForSubscription(
  config: RevenueCatApiClientConfig,
  subscription: RevenueCatSubscription,
): Promise<string | null> {
  const revenueCatProductId = normalizedNonEmptyString(subscription.product_id);
  const subscriptionId = normalizedNonEmptyString(subscription.id);
  if (!revenueCatProductId || !subscriptionId) return null;

  const cached = productStoreIdentifierCache.get(revenueCatProductId);
  if (cached) return cached;

  const fetchFn = config.fetchImpl ?? fetch;
  const timeoutMs = config.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const initialUrl = new URL(
    `${API_BASE_PATH}/projects/${encodeURIComponent(config.projectId)}/subscriptions/${encodeURIComponent(subscriptionId)}/entitlements`,
    API_ORIGIN,
  );
  initialUrl.searchParams.set("limit", String(PAGE_LIMIT));
  const expectedPathname = initialUrl.pathname;
  let currentUrl = initialUrl;
  const matchedStoreIdentifiers = new Set<string>();

  for (let page = 0; page < MAX_PAGES; page++) {
    const controller = new AbortController();
    const timeoutHandle = setTimeout(() => controller.abort(), timeoutMs);

    let response: Response;
    try {
      response = await fetchFn(currentUrl.toString(), {
        method: "GET",
        headers: {
          Authorization: `Bearer ${config.secretApiKey}`,
          Accept: "application/json",
        },
        signal: controller.signal,
      });
    } catch {
      return null;
    } finally {
      clearTimeout(timeoutHandle);
    }

    if (!response.ok) return null;

    let body: unknown;
    try {
      body = await response.json();
    } catch {
      return null;
    }
    if (typeof body !== "object" || body === null) return null;
    const record = body as Record<string, unknown>;
    if (!Array.isArray(record.items)) return null;

    for (const rawEntitlement of record.items) {
      if (typeof rawEntitlement !== "object" || rawEntitlement === null) continue;
      const entitlement = rawEntitlement as Record<string, unknown>;
      if (normalizedNonEmptyString(entitlement.lookup_key) !== "pro") continue;

      const products = entitlement.products;
      if (typeof products !== "object" || products === null) continue;
      const productItems = (products as Record<string, unknown>).items;
      if (!Array.isArray(productItems)) continue;

      for (const rawProduct of productItems) {
        if (typeof rawProduct !== "object" || rawProduct === null) continue;
        const product = rawProduct as Record<string, unknown>;
        if (normalizedNonEmptyString(product.id) !== revenueCatProductId) continue;
        const storeIdentifier = normalizedNonEmptyString(product.store_identifier);
        if (storeIdentifier) matchedStoreIdentifiers.add(storeIdentifier);
      }
    }

    const nextPage = normalizedNonEmptyString(record.next_page);
    if (!nextPage) break;

    let resolved: URL;
    try {
      resolved = new URL(nextPage, currentUrl);
    } catch {
      return null;
    }
    if (resolved.origin !== API_ORIGIN || resolved.pathname !== expectedPathname) return null;
    resolved.searchParams.set("limit", String(PAGE_LIMIT));
    currentUrl = resolved;
  }

  if (matchedStoreIdentifiers.size !== 1) return null;
  const storeIdentifier = [...matchedStoreIdentifiers][0];
  productStoreIdentifierCache.set(revenueCatProductId, storeIdentifier);
  return storeIdentifier;
}

/**
 * Adds `store_product_id` only where referral reward product resolution can actually need it:
 * active subscriptions that grant the `pro` entitlement and carry a RevenueCat-internal product id.
 * Metadata failure is deliberately non-fatal; callers still receive the untouched subscription and
 * canonical Pro entitlement refresh semantics remain exactly as before.
 */
async function enrichActiveProStoreProductIds(
  config: RevenueCatApiClientConfig,
  subscriptions: RevenueCatSubscription[],
): Promise<void> {
  for (const subscription of subscriptions) {
    if (!isActiveProSubscription(subscription)) continue;
    if (normalizedNonEmptyString(subscription.store_product_id)) continue;

    const storeIdentifier = await fetchStoreProductIdentifierForSubscription(config, subscription);
    if (storeIdentifier) {
      subscription.store_product_id = storeIdentifier;
    }
  }
}

/**
 * Validates that every subscription on this page actually belongs to the requested environment.
 * Returns the (unmodified) items on success, or `null` if any item is missing/has an unparseable
 * `environment` field or belongs to the OTHER environment — callers must treat `null` as a hard
 * failure, never silently filter the offending items out and proceed with the rest.
 */
function validatePageEnvironment(
  items: RevenueCatSubscription[],
  requestedEnvironment: RevenueCatApiEnvironment,
): RevenueCatSubscription[] | null {
  for (const item of items) {
    const itemEnvironment = normalizeApiEnvironment(item.environment);
    if (itemEnvironment === null || itemEnvironment !== requestedEnvironment) {
      return null;
    }
  }
  return items;
}

/**
 * Fetches the FULL, environment-filtered subscription list for one RevenueCat customer, paging
 * through `next_page` until exhausted or the defensive page cap is hit. Never throws — every
 * failure path (network error, timeout, non-2xx status, environment-validation failure, malformed
 * page cap exceeded) is reported through the `RevenueCatApiResult` union so callers can apply
 * Phase 13's "never fail open" rule uniformly.
 */
export async function fetchCustomerSubscriptions(
  config: RevenueCatApiClientConfig,
  appUserId: string,
  environment: RevenueCatApiEnvironment,
): Promise<RevenueCatApiResult> {
  const fetchFn = config.fetchImpl ?? fetch;
  const timeoutMs = config.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  const collected: RevenueCatSubscription[] = [];
  const initialUrl = buildInitialUrl(config.projectId, appUserId, environment);
  const expectedPathname = initialUrl.pathname;
  let currentUrl = initialUrl;

  for (let page = 0; page < MAX_PAGES; page++) {
    const controller = new AbortController();
    const timeoutHandle = setTimeout(() => controller.abort(), timeoutMs);

    let response: Response;
    try {
      response = await fetchFn(currentUrl.toString(), {
        method: "GET",
        headers: {
          Authorization: `Bearer ${config.secretApiKey}`,
          Accept: "application/json",
        },
        signal: controller.signal,
      });
    } catch (error) {
      return {
        kind: "retryable_error",
        statusCategory: "network_error",
        detail: error instanceof Error ? error.message : "unknown fetch failure",
      };
    } finally {
      clearTimeout(timeoutHandle);
    }

    if (response.status === 404) {
      // Phase B1 review Finding 2: a 404 means RevenueCat couldn't resolve the customer
      // resource itself — that is NOT strong enough evidence to revoke an existing Pro
      // entitlement for a webhook RevenueCat itself just sent us. Never treated as "empty
      // subscriptions"; always retryable, never mutates entitlement state.
      return {
        kind: "retryable_error",
        statusCategory: "404_customer_not_found",
        detail: "RevenueCat API could not resolve this customer",
      };
    }

    if (response.status === 401 || response.status === 403) {
      return {
        kind: "config_error",
        statusCategory: String(response.status),
        detail: "RevenueCat API rejected our credentials/authorization",
      };
    }

    if (response.status === 429 || response.status === 423 || response.status >= 500) {
      return {
        kind: "retryable_error",
        statusCategory: String(response.status),
        detail: "RevenueCat API returned a transient/upstream error",
      };
    }

    if (!response.ok) {
      // Any other non-2xx we didn't specifically classify above — safest default is retryable,
      // never a silent "treat as empty" that could hide an active Pro subscription.
      return {
        kind: "retryable_error",
        statusCategory: String(response.status),
        detail: "RevenueCat API returned an unclassified non-success status",
      };
    }

    let body: unknown;
    try {
      body = await response.json();
    } catch (error) {
      return {
        kind: "retryable_error",
        statusCategory: "invalid_json",
        detail: error instanceof Error ? error.message : "failed to parse RevenueCat API response",
      };
    }

    if (!isPlausibleSubscriptionsPage(body)) {
      return {
        kind: "retryable_error",
        statusCategory: "unexpected_shape",
        detail: "RevenueCat API response did not contain an \"items\" array",
      };
    }

    const validatedItems = validatePageEnvironment(body.items, environment);
    if (validatedItems === null) {
      return {
        kind: "retryable_error",
        statusCategory: "unexpected_environment",
        detail: `RevenueCat API returned a subscription item outside the requested "${environment}" environment`,
      };
    }

    await enrichActiveProStoreProductIds(config, validatedItems);
    collected.push(...validatedItems);

    if (!body.next_page) {
      return { kind: "ok", subscriptions: collected };
    }

    const nextUrl = resolveAndValidateNextPage(body.next_page, currentUrl, expectedPathname, environment);
    if (!nextUrl) {
      return {
        kind: "retryable_error",
        statusCategory: "invalid_next_page",
        detail: "RevenueCat API returned a next_page value outside the expected customer/resource path",
      };
    }
    currentUrl = nextUrl;
  }

  // Exceeded MAX_PAGES while next_page was still non-null — we have incomplete data. Never
  // proceed with a partial subscription list to compute entitlement (Phase 13's "never fail
  // open" applies just as much to incomplete data as to an outright error).
  return {
    kind: "retryable_error",
    statusCategory: "max_pages_exceeded",
    detail: `subscriptions list did not terminate within ${MAX_PAGES} pages`,
  };
}
