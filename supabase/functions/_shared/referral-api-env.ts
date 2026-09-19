// 85Blends 2.4.0 — Referral client API. Required runtime configuration resolution — same pattern
// as _shared/env.ts (Phase B1's webhook config), scoped to referral-api's own required values.
// Pure — takes a `getValue` lookup function rather than reading `Deno.env` directly, so this is
// unit-testable under Node (see referral-api-env.test.ts). The real Edge Function entry point
// calls `resolveReferralApiEnvConfig((name) => Deno.env.get(name))`.
//
// CLIENT API KEYS ARE NOT SECRETS. SUPABASE_PUBLISHABLE_KEYS / SUPABASE_ANON_KEY are PUBLIC,
// project-scoped client credentials — the same values that already ship inside the iOS app (see
// EightyFiveBlends/SupabaseConfig.swift). Comparing a request's key against these is a first-gate
// routing/project-identity check, never proof of app authenticity, never proof of a human/user,
// and never a substitute for the actual possession credential — the per-installation secret
// verified separately by referral-api/index.ts's authenticateInstallation. SUPABASE_DB_URL is the
// one genuinely sensitive value this module resolves; see database.ts's createDatabaseClient for
// the same "never log or embed dbUrl anywhere" discipline this module also follows.
//
// SUPABASE_PUBLISHABLE_KEYS is a JSON object whose VALUES are client-safe publishable keys — keys
// of that object are just labels (e.g. {"default": "sb_publishable_..."}), never inspected.
// Malformed JSON, a non-object, or non-string values never crash startup — they simply contribute
// zero keys from this source, the same "fail closed, don't fail loud" discipline this codebase
// already applies elsewhere (e.g. create_or_get_referral_participant's own defensive checks).
// SUPABASE_ANON_KEY (legacy) is optional and additive — either source alone, or both together, can
// make the configuration usable; it is valid only when SUPABASE_DB_URL is present AND at least one
// usable key exists from EITHER source.

export const REFERRAL_API_ENV_VAR_NAMES = [
  "SUPABASE_DB_URL",
  "SUPABASE_PUBLISHABLE_KEYS",
  "SUPABASE_ANON_KEY",
] as const;

export interface ReferralApiEnvConfig {
  supabaseDbUrl: string;
  /** Every usable client-safe API key this deployment accepts — SUPABASE_PUBLISHABLE_KEYS' values
   *  plus (if present) the legacy SUPABASE_ANON_KEY. A request's key is accepted if it matches ANY
   *  entry — see referral-api/index.ts. Never logged. */
  clientApiKeys: string[];
}

export type ResolveReferralApiEnvResult =
  | { ok: true; config: ReferralApiEnvConfig }
  | { ok: false; missing: string[] };

function isPresent(value: string | undefined): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

/** Parses SUPABASE_PUBLISHABLE_KEYS into its usable key list. Never throws — any parse/shape
 *  problem (invalid JSON, a non-object, an array, non-string values) yields an empty array,
 *  exactly as if the variable were absent, so a misconfiguration here degrades to relying on
 *  SUPABASE_ANON_KEY alone rather than crashing the function. */
function parsePublishableKeys(rawValue: string | undefined): string[] {
  if (!isPresent(rawValue)) return [];

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawValue);
  } catch {
    return [];
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return [];
  }

  const keys: string[] = [];
  for (const value of Object.values(parsed as Record<string, unknown>)) {
    if (typeof value === "string" && value.trim().length > 0) {
      keys.push(value);
    }
  }
  return keys;
}

export function resolveReferralApiEnvConfig(
  getValue: (name: string) => string | undefined,
): ResolveReferralApiEnvResult {
  const dbUrl = getValue("SUPABASE_DB_URL");
  const publishableKeys = parsePublishableKeys(getValue("SUPABASE_PUBLISHABLE_KEYS"));
  const anonKey = getValue("SUPABASE_ANON_KEY");

  const clientApiKeys = [...publishableKeys];
  if (isPresent(anonKey)) {
    clientApiKeys.push(anonKey);
  }

  const missing: string[] = [];
  if (!isPresent(dbUrl)) missing.push("SUPABASE_DB_URL");
  if (clientApiKeys.length === 0) missing.push("SUPABASE_PUBLISHABLE_KEYS or SUPABASE_ANON_KEY");

  if (missing.length > 0) {
    return { ok: false, missing };
  }

  return {
    ok: true,
    config: {
      supabaseDbUrl: dbUrl as string,
      clientApiKeys,
    },
  };
}
