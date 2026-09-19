// 85Blends 2.4.0 — Referral client API. Pure error-message mapping — no Deno-specific APIs,
// Node-testable (see referral-api-errors.test.ts). The one place a raw Postgres/plpgsql exception
// message is translated into a safe, generic API response; referral-api/index.ts never inspects a
// caught error's message directly, and never echoes it to the client — see this codebase's
// existing "never surface which specific check failed" philosophy (auth.ts, hmac.ts).

export interface ApiErrorMapping {
  httpStatus: number;
  code: string;
}

/** Keys match the exact `raise exception '<key>'` text used by private.create_or_get_referral_participant
 *  and private.apply_referral_code (see 20260910000000_referral_backend_baseline.sql) — this map
 *  is a translation layer over THEIR wording, not a place to reinvent it. */
const KNOWN_FUNCTION_ERROR_MAP: Record<string, ApiErrorMapping> = {
  installation_id_required: { httpStatus: 400, code: "invalid_request_body" },
  invalid_environment: { httpStatus: 400, code: "invalid_request_body" },
  referral_alias_conflict: { httpStatus: 409, code: "revenuecat_identity_conflict" },
  referral_alias_missing_after_insert: { httpStatus: 500, code: "internal_error" },
  referred_participant_required: { httpStatus: 500, code: "internal_error" },
  invalid_referral_code: { httpStatus: 400, code: "invalid_referral_code" },
  referral_code_not_found: { httpStatus: 404, code: "referral_code_not_found" },
  self_referral_not_allowed: { httpStatus: 409, code: "self_referral_not_allowed" },
  referral_already_attributed: { httpStatus: 409, code: "referral_already_applied" },
};

/**
 * Maps a raw Postgres error's `.message` (as surfaced by the `postgres` npm driver on a caught
 * error, e.g. from private.create_or_get_referral_participant or private.apply_referral_code) to a
 * safe, generic API response — never the raw Postgres message itself, which could contain SQL or
 * schema detail. Matched by prefix (`startsWith`) rather than exact equality: most of these
 * exceptions carry no extra text, but referral_alias_conflict's message continues with
 * "...already attached to a different referral participant" — startsWith handles both shapes
 * uniformly. Unrecognized messages (including a plain unique_violation the caller never mapped to
 * a raise, or anything unexpected) fall back to a generic 500, never leaking anything about the
 * underlying failure.
 */
export function mapReferralFunctionError(rawMessage: string): ApiErrorMapping {
  const trimmed = rawMessage.trim();
  for (const [key, mapping] of Object.entries(KNOWN_FUNCTION_ERROR_MAP)) {
    if (trimmed === key || trimmed.startsWith(`${key}:`) || trimmed.startsWith(`${key} `)) {
      return mapping;
    }
  }
  return { httpStatus: 500, code: "internal_error" };
}
