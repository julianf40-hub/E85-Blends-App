// 85Blends 2.4.0 — Generic promo campaign backend foundation. Pure request parsing/validation/
// normalization — no Deno-specific APIs, Node-testable (see promo-api-validation.test.ts). The
// future promo-api Edge Function entry point is the only real caller; every action's request body
// is validated here before any database call is ever made.
//
// REUSES referral-api-validation.ts's installation-credential primitives directly (isValidUuid,
// isValidInstallationSecret, isValidAppVersion, the two length constants) rather than redefining
// them — this is the SAME durable installation-possession credential referral-api already
// authenticates against (private.referral_client_installations), never a second Keychain secret
// system. See this repo's promo-foundation task spec: "Do NOT create a second Keychain secret
// system." referral-api-validation.ts itself is never modified by this addition.

import {
  isValidUuid,
  isValidInstallationSecret,
  isValidAppVersion,
  MIN_INSTALLATION_SECRET_LENGTH,
  MAX_INSTALLATION_SECRET_LENGTH,
} from "./referral-api-validation.ts";

export { isValidUuid, isValidInstallationSecret, MIN_INSTALLATION_SECRET_LENGTH, MAX_INSTALLATION_SECRET_LENGTH };

// Conservative marketing-code alphabet — mirrors promo_campaigns.normalized_public_code's own SQL
// CHECK constraint exactly (see the promo campaign foundation migration): uppercase A-Z, digits
// 0-9, hyphen; 3-32 characters. Applied to the ALREADY-normalized (trim+uppercase) code, exactly
// like referral-api-validation.ts's own REFERRAL_CODE_PATTERN is applied post-normalization by its
// callers — see this module's own header on why the pure parser below does not apply this pattern
// itself (mirrors referral-api's established split).
const PROMO_CODE_PATTERN = /^[A-Z0-9-]{3,32}$/;

// Generous headroom over any real App Store product identifier (reverse-DNS style, e.g.
// "com.85blends.subscription.annual") without allowing pathological input into a text column with
// no other length bound. The SPECIFIC allow-list of the three current shipping products is
// enforced authoritatively at the database layer (promo_campaign_plan_offers.product_id's own CHECK
// constraint — see the migration) — never duplicated here, so there is exactly one place a future
// fourth product (or the permanent exclusion of legacy quarterly) needs to change.
export const MAX_PRODUCT_ID_LENGTH = 128;

/** trim + uppercase — the exact same normalization private.normalize_promo_code applies
 *  server-side (see the migration's own header: "the ONE canonical normalization rule"). Performed
 *  here too so promo-api's own pre-database lookups/pre-checks compare against the same normalized
 *  form the database will, exactly mirroring referral-api-validation.ts's normalizeReferralCode. */
export function normalizePromoCode(value: string): string {
  return value.trim().toUpperCase();
}

/** Format check against the ALREADY-NORMALIZED code — mirrors the migration's own
 *  normalized_public_code CHECK constraint exactly. Deliberately not applied inside
 *  parsePromoApiRequest itself; the dedicated invalid_campaign_code error code is produced by the
 *  future promo-api/index.ts handlers, AFTER parsing succeeds — same split this codebase already
 *  established for isValidReferralCodeFormat (see referral-api-validation.ts's own header). */
export function isValidPromoCodeFormat(normalizedCode: string): boolean {
  return PROMO_CODE_PATTERN.test(normalizedCode);
}

export function isValidProductId(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= MAX_PRODUCT_ID_LENGTH;
}

export interface ValidatePromoRequest {
  action: "validate";
  clientInstallationId: string;
  installationSecret: string;
  publicCode: string; // already normalized (trim + uppercase)
  selectedProductId: string;
  appVersion: string | null;
}

export interface ClaimPromoRequest {
  action: "claim";
  clientInstallationId: string;
  installationSecret: string;
  publicCode: string; // already normalized
  selectedProductId: string;
  appVersion: string | null;
}

export interface StatusPromoRequest {
  action: "status";
  clientInstallationId: string;
  installationSecret: string;
  publicCode: string; // already normalized
}

export type PromoApiRequest = ValidatePromoRequest | ClaimPromoRequest | StatusPromoRequest;

export type ParsedPromoApiRequest =
  | { ok: true; request: PromoApiRequest }
  | { ok: false; code: "unknown_action" }
  /** Every other structural problem (missing/malformed field, wrong type) — collapses to one
   *  generic code, exactly mirroring referral-api-validation.ts's own ParsedApiRequest philosophy.
   *  A malformed public_code gets its own specific invalid_campaign_code code instead — see this
   *  module's own header — applied by the caller AFTER this function accepts any non-empty string
   *  through. */
  | { ok: false; code: "invalid_request_body" };

/** Parses+validates a decoded JSON body into one of the three supported promo actions. Returns a
 *  specific failure code rather than throwing — never touches the database. */
export function parsePromoApiRequest(body: unknown): ParsedPromoApiRequest {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, code: "invalid_request_body" };
  }
  const record = body as Record<string, unknown>;
  const action = record.action;

  if (action !== "validate" && action !== "claim" && action !== "status") {
    return { ok: false, code: "unknown_action" };
  }

  const clientInstallationId = record.installation_id;
  const installationSecret = record.installation_secret;
  if (!isValidUuid(clientInstallationId) || !isValidInstallationSecret(installationSecret)) {
    return { ok: false, code: "invalid_request_body" };
  }

  const rawPublicCode = record.public_code;
  if (typeof rawPublicCode !== "string" || rawPublicCode.trim().length === 0) {
    return { ok: false, code: "invalid_request_body" };
  }
  const publicCode = normalizePromoCode(rawPublicCode);

  if (action === "status") {
    return { ok: true, request: { action, clientInstallationId, installationSecret, publicCode } };
  }

  // validate | claim — both require a selected product.
  const selectedProductId = record.selected_product_id;
  if (!isValidProductId(selectedProductId)) {
    return { ok: false, code: "invalid_request_body" };
  }

  // Same "absent/null -> null, anything else must be a valid 1-64-char string" rule as
  // referral-api-validation.ts's own bootstrap parsing — never silently truncated to fit.
  const rawAppVersion = record.app_version;
  let appVersion: string | null;
  if (rawAppVersion === undefined || rawAppVersion === null) {
    appVersion = null;
  } else if (isValidAppVersion(rawAppVersion)) {
    appVersion = rawAppVersion.trim();
  } else {
    return { ok: false, code: "invalid_request_body" };
  }

  return {
    ok: true,
    request: {
      action,
      clientInstallationId,
      installationSecret,
      publicCode,
      selectedProductId: (selectedProductId as string).trim(),
      appVersion,
    },
  };
}
