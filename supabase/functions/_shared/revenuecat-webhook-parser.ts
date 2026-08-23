// 85Blends 2.3.0 — Phase B1. Defensive RevenueCat webhook payload parsing + event classification.
//
// Pure — takes the already-JSON-parsed envelope (parsing itself happens in index.ts, after auth
// succeeds, per Phase 8) and returns a discriminated union the rest of the pipeline switches on.
// No Deno-specific APIs; fully unit-testable under Node — see revenuecat-webhook-parser.test.ts.
//
// Per Phase 8: unknown/future JSON fields are always ignored, never cause rejection. Per Phases
// 19-22: TEST, TRANSFER, and TEMPORARY_ENTITLEMENT_GRANT events have their own limited shapes and
// must not be forced through the normal-event field requirements.

import {
  isValidWebhookEnvironment,
  type RevenueCatWebhookEnvelope,
  type RevenueCatWebhookEnvironment,
  type RevenueCatWebhookEventCore,
} from "./revenuecat-types.ts";

const TEST_EVENT_TYPE = "TEST";
const TRANSFER_EVENT_TYPE = "TRANSFER";
const TEMPORARY_ENTITLEMENT_GRANT_EVENT_TYPE = "TEMPORARY_ENTITLEMENT_GRANT";

export type ParsedWebhookEvent =
  | { kind: "malformed"; reason: string }
  | { kind: "test"; core: RevenueCatWebhookEventCore }
  | {
      kind: "transfer";
      core: RevenueCatWebhookEventCore;
      transferredFrom: string[];
      transferredTo: string[];
      environment: RevenueCatWebhookEnvironment | null;
      /** RevenueCat's `original_app_user_id` field, when the TRANSFER event happens to carry it —
       *  ledger-completeness only (see database.ts's LedgerEventInput); never null-coalesced with
       *  transferred_from[]/transferred_to[], which are a distinct kind of identity information.
       *  Null whenever RevenueCat's payload omits it, same as every other optional field on this
       *  event shape. */
      originalAppUserId: string | null;
    }
  | {
      kind: "temporary_entitlement_grant";
      core: RevenueCatWebhookEventCore;
      appUserId: string | null;
      environment: RevenueCatWebhookEnvironment | null;
    }
  | {
      kind: "normal";
      core: RevenueCatWebhookEventCore;
      environment: RevenueCatWebhookEnvironment;
      /** Deduplicated, non-empty union of app_user_id, original_app_user_id, and aliases[]. */
      aliasSet: string[];
      appUserId: string | null;
      originalAppUserId: string | null;
    }
  | { kind: "insufficient"; core: RevenueCatWebhookEventCore; reason: string };

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function asNonEmptyTrimmedString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/** Filters to non-empty, trimmed strings and dedupes while preserving first-seen order. */
export function dedupeNonEmptyStrings(values: unknown[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const raw of values) {
    const value = asNonEmptyTrimmedString(raw);
    if (value && !seen.has(value)) {
      seen.add(value);
      result.push(value);
    }
  }
  return result;
}

function extractCore(eventRecord: Record<string, unknown>): RevenueCatWebhookEventCore | null {
  const id = asNonEmptyTrimmedString(eventRecord.id);
  const type = asNonEmptyTrimmedString(eventRecord.type);
  const eventTimestampMs = eventRecord.event_timestamp_ms;

  if (!id || !type || typeof eventTimestampMs !== "number" || !Number.isFinite(eventTimestampMs)) {
    return null;
  }
  return { id, type, event_timestamp_ms: eventTimestampMs };
}

function extractEnvironment(eventRecord: Record<string, unknown>): RevenueCatWebhookEnvironment | null {
  return isValidWebhookEnvironment(eventRecord.environment) ? eventRecord.environment : null;
}

/**
 * Parses and classifies one webhook envelope. Never throws — every failure mode is represented
 * in the returned union so index.ts can map it to the correct HTTP response without a try/catch
 * around business logic.
 */
export function parseWebhookEvent(envelope: unknown): ParsedWebhookEvent {
  const envelopeRecord = asRecord(envelope) as RevenueCatWebhookEnvelope | null;
  if (!envelopeRecord) {
    return { kind: "malformed", reason: "root JSON value is not an object" };
  }

  const eventRecord = asRecord(envelopeRecord.event);
  if (!eventRecord) {
    return { kind: "malformed", reason: "missing or invalid \"event\" object" };
  }

  const core = extractCore(eventRecord);
  if (!core) {
    return { kind: "malformed", reason: "missing/invalid event.id, event.type, or event.event_timestamp_ms" };
  }

  if (core.type === TEST_EVENT_TYPE) {
    return { kind: "test", core };
  }

  if (core.type === TRANSFER_EVENT_TYPE) {
    const transferredFrom = dedupeNonEmptyStrings(
      Array.isArray(eventRecord.transferred_from) ? eventRecord.transferred_from : [],
    );
    const transferredTo = dedupeNonEmptyStrings(
      Array.isArray(eventRecord.transferred_to) ? eventRecord.transferred_to : [],
    );
    return {
      kind: "transfer",
      core,
      transferredFrom,
      transferredTo,
      environment: extractEnvironment(eventRecord),
      originalAppUserId: asNonEmptyTrimmedString(eventRecord.original_app_user_id),
    };
  }

  if (core.type === TEMPORARY_ENTITLEMENT_GRANT_EVENT_TYPE) {
    return {
      kind: "temporary_entitlement_grant",
      core,
      appUserId: asNonEmptyTrimmedString(eventRecord.app_user_id),
      environment: extractEnvironment(eventRecord),
    };
  }

  // Every other event type (INITIAL_PURCHASE, RENEWAL, CANCELLATION, UNCANCELLATION, EXPIRATION,
  // BILLING_ISSUE, PRODUCT_CHANGE, and any future type RevenueCat introduces) is treated as a
  // "normal" subscription-lifecycle shape IF it actually carries what a normal refresh needs —
  // otherwise it falls back to "insufficient" rather than guessing (Phase 22).
  const environment = extractEnvironment(eventRecord);
  const appUserId = asNonEmptyTrimmedString(eventRecord.app_user_id);
  const originalAppUserId = asNonEmptyTrimmedString(eventRecord.original_app_user_id);
  const aliasesField = Array.isArray(eventRecord.aliases) ? eventRecord.aliases : [];
  const aliasSet = dedupeNonEmptyStrings([appUserId, originalAppUserId, ...aliasesField]);

  if (!environment) {
    return { kind: "insufficient", core, reason: "missing or invalid event.environment" };
  }
  if (aliasSet.length === 0) {
    return { kind: "insufficient", core, reason: "no usable app_user_id/original_app_user_id/aliases" };
  }

  return { kind: "normal", core, environment, aliasSet, appUserId, originalAppUserId };
}
