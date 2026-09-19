// 85Blends 2.4.0 — Referral client API. Pure request parsing/validation/normalization — no
// Deno-specific APIs, Node-testable (see referral-api-validation.test.ts). The Edge Function entry
// point (referral-api/index.ts) is the only real caller; every action's request body is validated
// here before any database call is ever made.

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Matches private.generate_referral_code's own alphabet/length exactly (see the referral baseline
// migration) — 8 characters from a 33-symbol alphabet that deliberately excludes 0/1/I/O for
// human-transcription safety.
const REFERRAL_CODE_PATTERN = /^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$/;

export const MIN_INSTALLATION_SECRET_LENGTH = 32;

// Generous headroom over any real RevenueCat app_user_id (typically a UUID or a short opaque
// string) without allowing pathological input into a text column with no other length bound.
export const MAX_REVENUECAT_APP_USER_ID_LENGTH = 256;

export const MAX_APP_VERSION_LENGTH = 64;

export function isValidUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

/** Length-only check — the secret is client-generated opaque entropy, never a format this backend
 *  interprets. Raw value is never logged; see referral-api/index.ts, which only ever handles it
 *  long enough to hash it. */
export function isValidInstallationSecret(value: unknown): value is string {
  return typeof value === "string" && value.length >= MIN_INSTALLATION_SECRET_LENGTH;
}

export function isValidRevenueCatAppUserId(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= MAX_REVENUECAT_APP_USER_ID_LENGTH;
}

export type RevenueCatEnvironment = "SANDBOX" | "PRODUCTION";

export function isValidRevenueCatEnvironment(value: unknown): value is RevenueCatEnvironment {
  return value === "SANDBOX" || value === "PRODUCTION";
}

export function isValidReferralCodeFormat(value: unknown): value is string {
  return typeof value === "string" && REFERRAL_CODE_PATTERN.test(value);
}

/** trim + uppercase — the exact normalization private.apply_referral_code itself applies
 *  (`upper(btrim(p_referral_code))`), performed here too so referral-api's own pre-checks compare
 *  against the same normalized form the database will. */
export function normalizeReferralCode(value: string): string {
  return value.trim().toUpperCase();
}

export interface BootstrapRequest {
  action: "bootstrap";
  clientInstallationId: string;
  installationSecret: string;
  revenueCatAppUserId: string;
  revenueCatEnvironment: RevenueCatEnvironment;
  appVersion: string | null;
}

export interface StatusRequest {
  action: "status";
  clientInstallationId: string;
  installationSecret: string;
}

export interface ApplyCodeRequest {
  action: "apply_code";
  clientInstallationId: string;
  installationSecret: string;
  referralCode: string;
}

export type ReferralApiRequest = BootstrapRequest | StatusRequest | ApplyCodeRequest;

export type ParsedApiRequest =
  | { ok: true; request: ReferralApiRequest }
  /** No `action` field, or a value other than bootstrap/status/apply_code — maps to the API's own
   *  `400 unknown_action` per the task spec. */
  | { ok: false; code: "unknown_action" }
  /** Any other structural problem — missing/malformed field, wrong type. Deliberately collapses
   *  every such case to one generic code, mirroring this codebase's existing "don't reveal which
   *  specific check failed" philosophy (see auth.ts's WebhookAuthResult). The one exception is a
   *  malformed referral_code, which gets its own specific `invalid_referral_code` code per the
   *  task spec — see referral-api/index.ts's apply_code handler, which checks that separately
   *  AFTER this function accepts any non-empty string through. */
  | { ok: false; code: "invalid_request_body" };

/** Parses+validates a decoded JSON body into one of the three supported actions. Returns a
 *  specific failure code rather than throwing. */
export function parseApiRequest(body: unknown): ParsedApiRequest {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, code: "invalid_request_body" };
  }
  const record = body as Record<string, unknown>;
  const action = record.action;

  if (action !== "bootstrap" && action !== "status" && action !== "apply_code") {
    return { ok: false, code: "unknown_action" };
  }

  const clientInstallationId = record.client_installation_id;
  const installationSecret = record.installation_secret;
  if (!isValidUuid(clientInstallationId) || !isValidInstallationSecret(installationSecret)) {
    return { ok: false, code: "invalid_request_body" };
  }

  if (action === "status") {
    return { ok: true, request: { action, clientInstallationId, installationSecret } };
  }

  if (action === "apply_code") {
    const rawCode = record.referral_code;
    if (typeof rawCode !== "string" || rawCode.trim().length === 0) {
      return { ok: false, code: "invalid_request_body" };
    }
    return {
      ok: true,
      request: {
        action,
        clientInstallationId,
        installationSecret,
        referralCode: normalizeReferralCode(rawCode),
      },
    };
  }

  // action === "bootstrap"
  const revenueCatAppUserId = record.revenuecat_app_user_id;
  const revenueCatEnvironment = record.revenuecat_environment;
  if (
    !isValidRevenueCatAppUserId(revenueCatAppUserId) ||
    !isValidRevenueCatEnvironment(revenueCatEnvironment)
  ) {
    return { ok: false, code: "invalid_request_body" };
  }

  const rawAppVersion = record.app_version;
  const appVersion =
    typeof rawAppVersion === "string" && rawAppVersion.trim().length > 0
      ? rawAppVersion.trim().slice(0, MAX_APP_VERSION_LENGTH)
      : null;

  return {
    ok: true,
    request: {
      action,
      clientInstallationId,
      installationSecret,
      revenueCatAppUserId: (revenueCatAppUserId as string).trim(),
      revenueCatEnvironment,
      appVersion,
    },
  };
}
