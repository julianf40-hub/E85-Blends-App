// 85Blends 2.3.0 — Phase B1. RevenueCat REST API v2 client — canonical subscription refresh.
//
// Uses only standard Fetch API primitives (`fetch`, `AbortController`, `URL`, `Headers`) — no
// Deno-specific APIs. `fetchImpl` is injectable (defaults to the global `fetch`), so the
// pagination/validation/error-classification logic here is directly unit-testable under Node
// with a stub fetch — see revenuecat-api.test.ts. This module never touches Postgres, never
// touches the webhook's own auth secrets, and is the ONLY place in this function that calls out
// to RevenueCat's servers.
//
// IMPORTANT — not live-verified: the exact RevenueCat API v2 response shape (`gives_access`,
// `entitlements.items[].lookup_key`, `ends_at`, `current_period_ends_at`, pagination via
// `next_page`) is implemented from the task spec's description, not a live fetch against
// RevenueCat's current documentation (this environment has no internet access — see
// supabase/README.md's Phase B1 known-limitations note). Re-verify against a real API response
// before Phase C deployment.

import type {
  RevenueCatApiEnvironment,
  RevenueCatApiResult,
  RevenueCatSubscription,
  RevenueCatSubscriptionsPage,
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
 * Resolves a `next_page` value against the current request URL and verifies the result still
 * points at `https://api.revenuecat.com/v2/...` before it's ever followed — per Phase 12, never
 * accept an arbitrary external URL from response data, whether `next_page` arrives as an absolute
 * URL or a relative path/query string.
 */
function resolveAndValidateNextPage(nextPage: string, currentUrl: URL): URL | null {
  let resolved: URL;
  try {
    resolved = new URL(nextPage, currentUrl);
  } catch {
    return null;
  }
  if (resolved.origin !== API_ORIGIN) return null;
  if (!resolved.pathname.startsWith(`${API_BASE_PATH}/`)) return null;
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
 * Fetches the FULL, environment-filtered subscription list for one RevenueCat customer, paging
 * through `next_page` until exhausted or the defensive page cap is hit. Never throws — every
 * failure path (network error, timeout, non-2xx status, malformed page cap exceeded) is reported
 * through the `RevenueCatApiResult` union so callers can apply Phase 13's "never fail open" rule
 * uniformly.
 */
export async function fetchCustomerSubscriptions(
  config: RevenueCatApiClientConfig,
  appUserId: string,
  environment: RevenueCatApiEnvironment,
): Promise<RevenueCatApiResult> {
  const fetchFn = config.fetchImpl ?? fetch;
  const timeoutMs = config.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  const collected: RevenueCatSubscription[] = [];
  let currentUrl = buildInitialUrl(config.projectId, appUserId, environment);

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
      // Per Phase 13/this module's design note: RevenueCat has no record of this exact ID.
      // Treated as "no subscriptions for this ID," not a retryable failure — the caller still
      // has a valid identity from the webhook event itself, so this safely resolves to Free
      // rather than blocking the write or granting Pro from stale data.
      return { kind: "not_found" };
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

    collected.push(...body.items);

    if (!body.next_page) {
      return { kind: "ok", subscriptions: collected };
    }

    const nextUrl = resolveAndValidateNextPage(body.next_page, currentUrl);
    if (!nextUrl) {
      return {
        kind: "retryable_error",
        statusCategory: "invalid_next_page",
        detail: "RevenueCat API returned a next_page value outside the expected API host/path",
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
