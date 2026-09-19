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
