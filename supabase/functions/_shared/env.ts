// 85Blends 2.3.0 — Phase B1. Required runtime configuration resolution.
//
// Pure — takes a `getValue` lookup function rather than reading `Deno.env` directly, so this is
// unit-testable under Node with a fake env map (see env.test.ts). The real Edge Function entry
// point calls `resolveEnvConfig((name) => Deno.env.get(name))`.
//
// Per Phase 7: on any missing required variable, the caller must respond 503 and log only the
// missing VARIABLE NAME(s) — never a value, and never fall back to any client-facing credential
// (the RevenueCat `appl_` public SDK key, SUPABASE_ANON_KEY, or anything from the iOS app's
// Info.plist). This module never reads or references any of those client-facing values at all.

export const REQUIRED_ENV_VAR_NAMES = [
  "REVENUECAT_PROJECT_ID",
  "REVENUECAT_V2_SECRET_API_KEY",
  "REVENUECAT_WEBHOOK_AUTH_HEADER",
  "REVENUECAT_WEBHOOK_HMAC_SECRET",
  "SUPABASE_DB_URL",
] as const;

export interface WebhookEnvConfig {
  revenueCatProjectId: string;
  revenueCatV2SecretApiKey: string;
  webhookAuthHeaderSecret: string;
  webhookHmacSecret: string;
  supabaseDbUrl: string;
}

export type ResolveEnvResult =
  | { ok: true; config: WebhookEnvConfig }
  | { ok: false; missing: string[] };

/** Blank/whitespace-only values are treated the same as "missing" — same convention this repo's
 *  iOS-side config code already uses (see EightyFiveBlends/SupabaseConfig.swift). */
function isPresent(value: string | undefined): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

export function resolveEnvConfig(getValue: (name: string) => string | undefined): ResolveEnvResult {
  const values: Record<string, string | undefined> = {};
  const missing: string[] = [];

  for (const name of REQUIRED_ENV_VAR_NAMES) {
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
      revenueCatProjectId: values.REVENUECAT_PROJECT_ID as string,
      revenueCatV2SecretApiKey: values.REVENUECAT_V2_SECRET_API_KEY as string,
      webhookAuthHeaderSecret: values.REVENUECAT_WEBHOOK_AUTH_HEADER as string,
      webhookHmacSecret: values.REVENUECAT_WEBHOOK_HMAC_SECRET as string,
      supabaseDbUrl: values.SUPABASE_DB_URL as string,
    },
  };
}
