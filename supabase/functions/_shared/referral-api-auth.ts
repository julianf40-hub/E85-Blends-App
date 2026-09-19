// 85Blends 2.4.0 — Referral client API. Pure HTTP-credential extraction/matching — no
// Deno-specific APIs, Node-testable (see referral-api-auth.test.ts). Used by referral-api/index.ts's
// top-level client-safe API key gate (see referral-api-env.ts's header comment for what this key
// is and, importantly, is NOT).

import { constantTimeEqual } from "./hmac.ts";

/** Extracts the token from an `Authorization: Bearer <token>` header value — the legacy-compatible
 *  path when a caller sends the API key via `Authorization` instead of the `apikey` header. Returns
 *  null for a missing header or any other scheme/shape; never throws. */
export function extractBearerToken(authorizationHeader: string | null): string | null {
  if (!authorizationHeader) return null;
  const match = /^Bearer\s+(.+)$/i.exec(authorizationHeader.trim());
  return match ? match[1] : null;
}

/** True if `suppliedKey` matches ANY entry in `configuredKeys`, compared with
 *  hmac.ts's constantTimeEqual (never `===`). `configuredKeys` holds PUBLIC, client-safe API keys
 *  (see referral-api-env.ts) — the constant-time comparison here is routine defensive hygiene for
 *  any credential compare in this codebase, not because these particular values are secret.
 *  Returns false immediately for a null suppliedKey without touching configuredKeys. */
export function matchesAnyApiKey(suppliedKey: string | null, configuredKeys: readonly string[]): boolean {
  if (suppliedKey === null) return false;
  return configuredKeys.some((configured) => constantTimeEqual(suppliedKey, configured));
}

/**
 * A request is authenticated at gate A if EITHER the raw `apikey` header value OR the
 * `Authorization: Bearer` token matches any configured key — the two credential sources have NO
 * precedence over each other. A caller may legitimately send either one; a wrong/absent value in
 * ONE source must never suppress a genuinely valid value in the OTHER (see referral-api's own
 * task spec's exact truth table: apikey-only, bearer-only, valid-apikey+invalid-bearer, and
 * invalid-apikey+valid-bearer must ALL be accepted; only both-invalid/both-absent are rejected).
 * Deliberately does NOT use `??` between the two header values — that operator only falls through
 * on null/undefined, so a PRESENT-but-wrong `apikey` header would otherwise permanently hide a
 * valid bearer token from ever being checked at all.
 */
export function hasMatchingClientApiKey(
  apiKeyHeader: string | null,
  authorizationHeader: string | null,
  configuredKeys: readonly string[],
): boolean {
  if (matchesAnyApiKey(apiKeyHeader, configuredKeys)) return true;
  return matchesAnyApiKey(extractBearerToken(authorizationHeader), configuredKeys);
}
