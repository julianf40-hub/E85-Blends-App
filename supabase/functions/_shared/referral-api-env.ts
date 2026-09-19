// 85Blends 2.4.0 — Referral client API. Required runtime configuration resolution — same pattern
// as _shared/env.ts (Phase B1's webhook config), scoped to referral-api's own two required
// values. Pure — takes a `getValue` lookup function rather than reading `Deno.env` directly, so
// this is unit-testable under Node (see referral-api-env.test.ts). The real Edge Function entry
// point calls `resolveReferralApiEnvConfig((name) => Deno.env.get(name))`.
//
// SUPABASE_ANON_KEY is itself a client-safe value (it already ships inside the iOS app — see
// EightyFiveBlends/SupabaseConfig.swift) — reading it here is comparing "what the client sent"
// against "the same public value the client already has," not handling a secret. SUPABASE_DB_URL
// is the one genuinely sensitive value this module resolves; see database.ts's createDatabaseClient
// for the same "never log or embed dbUrl anywhere" discipline this module also follows.

export const REFERRAL_API_REQUIRED_ENV_VAR_NAMES = ["SUPABASE_DB_URL", "SUPABASE_ANON_KEY"] as const;

export interface ReferralApiEnvConfig {
  supabaseDbUrl: string;
  supabaseAnonKey: string;
}

export type ResolveReferralApiEnvResult =
  | { ok: true; config: ReferralApiEnvConfig }
  | { ok: false; missing: string[] };

/** Blank/whitespace-only values are treated the same as "missing" — same convention env.ts uses. */
function isPresent(value: string | undefined): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

export function resolveReferralApiEnvConfig(
  getValue: (name: string) => string | undefined,
): ResolveReferralApiEnvResult {
  const values: Record<string, string | undefined> = {};
  const missing: string[] = [];

  for (const name of REFERRAL_API_REQUIRED_ENV_VAR_NAMES) {
    const value = getValue(name);
    values[name] = value;
    if (!isPresent(value)) missing.push(name);
  }

  if (missing.length > 0) {
    return { ok: false, missing };
  }

  return {
    ok: true,
    config: {
      supabaseDbUrl: values.SUPABASE_DB_URL as string,
      supabaseAnonKey: values.SUPABASE_ANON_KEY as string,
    },
  };
}
