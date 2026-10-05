// 85Blends 2.4.1 — price-alerts-worker caller authentication.
//
// Pure (no Deno APIs) so it is unit-testable under Node — see auth.test.ts — and lives in the
// worker's own directory so deploying the function with just its own files still bundles it.
//
// The worker is a private, server-to-server endpoint. A caller is accepted if it presents EITHER:
//   * the dedicated scheduler secret in the `x-85blends-cron-secret` header (what the pg_cron/pg_net
//     job sends — see private.invoke_price_alerts_worker()), OR
//   * the project service-role key as `Authorization: Bearer <key>` (the worker's original
//     contract, kept so a manual/operator invocation keeps working).
// Both comparisons are always computed (no early return between them) and use a constant-time
// compare. Nothing here logs or returns a credential, and a missing/short configured secret can
// never match: an unset PRICE_ALERTS_WORKER_CRON_SECRET simply disables that path.

export const CRON_SECRET_HEADER = "x-85blends-cron-secret";

/** Floor for the configured scheduler secret. Matches the length guard in
 *  private.invoke_price_alerts_worker(), so a placeholder/weak value is rejected on both sides. */
export const MIN_CRON_SECRET_LENGTH = 32;

export interface WorkerAuthConfig {
  /** SUPABASE_SERVICE_ROLE_KEY (empty string when unset). */
  serviceRoleKey: string;
  /** PRICE_ALERTS_WORKER_CRON_SECRET (empty string when unset). */
  cronSecret: string;
}

export function constantTimeEqual(a: string, b: string): boolean {
  const len = Math.max(a.length, b.length, 1);
  let diff = a.length === b.length ? 0 : 1;
  for (let i = 0; i < len; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

export function bearerToken(headers: Headers): string {
  const value = headers.get("authorization")?.trim() ?? "";
  return value.toLowerCase().startsWith("bearer ") ? value.slice(7).trim() : "";
}

export function isAuthorizedWorkerCall(headers: Headers, config: WorkerAuthConfig): boolean {
  const presentedCronSecret = headers.get(CRON_SECRET_HEADER)?.trim() ?? "";
  const cronOk = config.cronSecret.length >= MIN_CRON_SECRET_LENGTH &&
    presentedCronSecret.length > 0 &&
    constantTimeEqual(config.cronSecret, presentedCronSecret);

  const presentedBearer = bearerToken(headers);
  const bearerOk = config.serviceRoleKey.length > 0 &&
    presentedBearer.length > 0 &&
    constantTimeEqual(config.serviceRoleKey, presentedBearer);

  return cronOk || bearerOk;
}
