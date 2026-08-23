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
