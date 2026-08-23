// 85Blends 2.3.0 — Phase B1. Logging helpers — privacy-safe by construction where practical.
//
// Pure functions; no Deno-specific APIs (the actual `console.log` calls at real call sites use
// the standard `console` global, available in both Deno and Node).

/**
 * Masks an identifier as `first4…last4`, mirroring the exact convention already used elsewhere
 * in this codebase for the same purpose (RevenueCatSubscriptionService.maskedAppUserID and
 * CommunityPriceService.maskedReporterID on the iOS side). Short values collapse to `***` rather
 * than reveal their (short) full length.
 */
export function maskIdentifier(value: string | null | undefined): string {
  if (!value) return "—";
  if (value.length <= 8) return "***";
  return `${value.slice(0, 4)}…${value.slice(-4)}`;
}

/**
 * A structured log line for this function's own events — deliberately never accepts a raw
 * secret/credential field name. Never pass HMAC secrets, the Authorization secret, the RevenueCat
 * API key, SUPABASE_DB_URL, database passwords, full APNs tokens, or full installation secrets
 * into `details` — see this repo's Phase B1 task spec (Phase 24) for the exact list.
 */
export function logWebhookEvent(
  level: "info" | "warn" | "error",
  message: string,
  details: Record<string, string | number | boolean | null | undefined> = {},
): void {
  const line = JSON.stringify({ level, message, ...details, ts: new Date().toISOString() });
  if (level === "error") {
    console.error(line);
  } else if (level === "warn") {
    console.warn(line);
  } else {
    console.log(line);
  }
}
