// 85Blends 2.4.0 — Referral client API. Pure error-message mapping — no Deno-specific APIs,
// Node-testable (see referral-api-errors.test.ts). The one place a raw Postgres/plpgsql exception
// message is translated into a safe, generic API response.
//
// A caught error's raw `.message` (and any other raw driver field — `.detail`, `.query`,
// `.parameters`) is NEVER surfaced to the CLIENT and NEVER emitted to LOGS, full stop — both
// destinations are equally untrusted from this data's perspective (`.detail` in particular often
// echoes the literal offending VALUE, e.g. `Key (installation_id)=(...) already exists`, which is
// exactly what must never reach any log line). `mapReferralFunctionError` below is the ONE
// sanctioned place `.message` is still read at all — purely as an internal classification key, to
// decide which safe, generic response code to return — see referral-api/index.ts's catch blocks,
// which pass `.message` to this function and nothing else, then log only
// `buildSafeErrorLogMetadata`'s structured, pre-sanitized output.

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
  referral_participant_missing_after_conflict: { httpStatus: 500, code: "internal_error" },
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

export interface SafeErrorLogMetadata {
  errorCategory: "database_error";
  sqlState?: string;
}

const SQLSTATE_PATTERN = /^[0-9A-Z]{5}$/;

/**
 * Builds the ONLY thing an unexpected database failure is allowed to log: a fixed category, plus
 * the raw SQLSTATE — but ONLY when it is exactly a 5-character code matching `^[0-9A-Z]{5}$`
 * (e.g. `"23505"`). Anything else (a longer/malformed value, or no `.code` field at all — the
 * `postgres` npm driver's own SQLSTATE field) is silently omitted rather than logged as-is; a
 * SQLSTATE this narrowly shaped cannot itself carry embedded request data the way `.message`/
 * `.detail`/`.query`/`.parameters` can. Never pass those other fields here or anywhere near a log
 * call — see this module's header comment.
 */
export function buildSafeErrorLogMetadata(sqlState: unknown): SafeErrorLogMetadata {
  if (typeof sqlState === "string" && SQLSTATE_PATTERN.test(sqlState)) {
    return { errorCategory: "database_error", sqlState };
  }
  return { errorCategory: "database_error" };
}
