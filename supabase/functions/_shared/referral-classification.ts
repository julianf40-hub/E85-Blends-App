// 85Blends 2.4.0 — Referral paid-qualification foundation. Pure event classification for the
// referral pipeline layered on top of the existing RevenueCat webhook.
//
// Deliberately does NOT extend revenuecat-webhook-parser.ts or its `ParsedWebhookEvent["normal"]`
// shape: that file is the already-reviewed, already-load-bearing parser behind the existing
// RevenueCat entitlement mirror (Phase 15 of the referral task explicitly protects it from
// regression). This module independently, defensively extracts the handful of additional raw
// fields referral qualification needs (period_type, product_id, cancel_reason, transaction ids,
// purchased_at_ms) from the SAME raw envelope index.ts already has in scope, using the same
// defensive style as that file, then exposes small pure decision functions over plain values —
// mirroring this codebase's established split (see entitlement.ts, idempotency.ts,
// customer-resolution.ts: raw-shape extraction is one function, the actual decision is another,
// separately testable one).
//
// No Deno-specific APIs — fully unit-testable under Node, see referral-classification.test.ts.

import type { RevenueCatWebhookEnvironment } from "./revenuecat-types.ts";

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

function asFiniteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function asEnvironment(value: unknown): RevenueCatWebhookEnvironment | null {
  return value === "SANDBOX" || value === "PRODUCTION" ? value : null;
}

/** The handful of raw webhook event fields referral classification needs, beyond what
 *  revenuecat-webhook-parser.ts already extracts for entitlement-mirror purposes. Every field is
 *  independently optional/defensive — RevenueCat documents price-adjacent and lifecycle fields as
 *  optional depending on event type, and a missing field here must only ever make an event
 *  ineligible for referral processing, never break entitlement-mirror processing (that pipeline
 *  never reads this type at all). */
export interface ReferralWebhookFields {
  eventType: string;
  environment: RevenueCatWebhookEnvironment | null;
  periodType: string | null;
  productId: string | null;
  cancelReason: string | null;
  transactionId: string | null;
  originalTransactionId: string | null;
  purchasedAtMs: number | null;
}

/**
 * Independently re-parses the raw webhook envelope for referral-relevant fields only. Callers
 * should only invoke this once `revenuecat-webhook-parser.ts`'s own `parseWebhookEvent` has
 * already classified the event as `"normal"` — this function does not replace that parser's
 * validation (id/type/event_timestamp_ms presence, environment/alias sufficiency), it reads
 * additional fields from the SAME already-validated envelope. Returns `null` only if the envelope
 * doesn't even have a minimal `{ event: { type: string } }` shape, which should be unreachable in
 * practice at index.ts's actual call site (parseWebhookEvent already rejected anything that
 * malformed before this would ever run).
 */
export function extractReferralWebhookFields(envelope: unknown): ReferralWebhookFields | null {
  const envelopeRecord = asRecord(envelope);
  const eventRecord = envelopeRecord ? asRecord(envelopeRecord.event) : null;
  if (!eventRecord) return null;

  const eventType = asNonEmptyTrimmedString(eventRecord.type);
  if (!eventType) return null;

  return {
    eventType,
    environment: asEnvironment(eventRecord.environment),
    periodType: asNonEmptyTrimmedString(eventRecord.period_type),
    productId: asNonEmptyTrimmedString(eventRecord.product_id),
    cancelReason: asNonEmptyTrimmedString(eventRecord.cancel_reason),
    transactionId: asNonEmptyTrimmedString(eventRecord.transaction_id),
    originalTransactionId: asNonEmptyTrimmedString(eventRecord.original_transaction_id),
    purchasedAtMs: asFiniteNumber(eventRecord.purchased_at_ms),
  };
}

/** The only three 85Blends Pro product IDs a paid referral may ever qualify from — exactly
 *  ProPlan.swift's three cases on the iOS side (see EightyFiveBlends/ProPlan.swift). The legacy
 *  `com.85blends.subscription.quarterly` product is deliberately never included here, mirroring
 *  why it's excluded from ProPlan.allCases: it is not one of the three shipping paid plans. */
export const REFERRAL_QUALIFYING_PRODUCT_IDS: readonly string[] = [
  "com.85blends.subscription.monthly",
  "com.85blends.subscription.threemonth",
  "com.85blends.subscription.annual",
];

/**
 * TRUE only for a genuine, production, first-time, normal-priced paid purchase of one of the three
 * qualifying products. This is the "trusted v1 paid-conversion rule" — deliberately checked on the
 * webhook event's own shape alone (never requires price fields, which RevenueCat documents as
 * optional): RENEWAL, PRODUCT_CHANGE, CANCELLATION, EXPIRATION, BILLING_ISSUE,
 * TEMPORARY_ENTITLEMENT_GRANT, NON_RENEWING_PURCHASE, trial/intro/promotional periods (anything
 * whose period_type isn't exactly `"NORMAL"`), and SANDBOX/TEST events are all excluded by
 * construction. This function alone is NOT sufficient to qualify a referral — see
 * ReferralQualificationEligibility's own header: the caller must ALSO have a successful canonical
 * RevenueCat subscriber refresh confirming active `pro` before ever calling the database
 * qualification function (Phase 9 of the referral task — no "best effort" qualification from the
 * webhook payload alone).
 *
 * Also requires `transactionId`/`originalTransactionId` to both be present (integrity hardening):
 * `originalTransactionId` is the sole match key a later refund/REFUND_REVERSED event uses to find
 * this exact attribution again (see the migration's `process_referral_subscription_event`) — an
 * event missing either id can never be reversed or re-confirmed later, so it must never qualify in
 * the first place, regardless of how otherwise-eligible it looks. RevenueCat documents both ids as
 * always present on a genuine INITIAL_PURCHASE; a qualifying-shaped event missing one is treated as
 * malformed, not as eligible.
 */
export function isReferralQualifyingEvent(fields: ReferralWebhookFields): boolean {
  return (
    fields.eventType === "INITIAL_PURCHASE" &&
    fields.environment === "PRODUCTION" &&
    fields.periodType === "NORMAL" &&
    fields.productId !== null &&
    REFERRAL_QUALIFYING_PRODUCT_IDS.includes(fields.productId) &&
    fields.transactionId !== null &&
    fields.originalTransactionId !== null
  );
}

/**
 * TRUE only for the narrow refund-reversal trigger this v1 recognizes: a PRODUCTION CANCELLATION
 * whose `cancel_reason` is exactly `"CUSTOMER_SUPPORT"` — RevenueCat's documented signal for a
 * support-issued refund, as distinct from a voluntary UNSUBSCRIBE, a BILLING_ERROR lapse, or any
 * other cancellation reason, none of which reverse a qualification (see the referral task's Refund
 * / Reversal Rule). This function only classifies the EVENT; matching it to the correct attribution
 * by qualifying_original_transaction_id (AND, as of this hardening pass, the participant identity
 * resolved from this same event's alias set — see the migration) happens in the database function
 * (Phase 10/12), since only the database has the attribution's stored transaction identity to
 * compare against.
 *
 * Also requires `originalTransactionId` to be present: with no id there is nothing for the database
 * function to match against, and "no referral action" (this classifier returning false, so the
 * caller never invokes the database function at all) is the correct, explicit no-op — not a bare
 * `qualifying_original_transaction_id = NULL` comparison relied on to fail closed implicitly. The
 * existing entitlement mirror is entirely unaffected either way.
 */
export function isReferralRefundReversalEvent(fields: ReferralWebhookFields): boolean {
  return (
    fields.eventType === "CANCELLATION" &&
    fields.environment === "PRODUCTION" &&
    fields.cancelReason === "CUSTOMER_SUPPORT" &&
    fields.originalTransactionId !== null
  );
}

/**
 * TRUE only for a PRODUCTION `REFUND_REVERSED` event — RevenueCat's signal that a previously
 * refunded transaction has been un-refunded. A candidate only, exactly like the reversal
 * classifier above: matching it against the correct, currently-`reversed` attribution by
 * qualifying_original_transaction_id AND participant identity, and re-confirming canonical Pro
 * state, both happen in the database function (Phase 13) — this function only answers "is this
 * event's TYPE the kind that could ever re-qualify a referral," never "should it."
 *
 * Also requires `originalTransactionId` to be present, for the same reason as the reversal
 * classifier above — no id means no possible match, so this is a clean no-op, not a database call
 * relying on `= NULL` never matching.
 */
export function isReferralRequalificationEvent(fields: ReferralWebhookFields): boolean {
  return (
    fields.eventType === "REFUND_REVERSED" &&
    fields.environment === "PRODUCTION" &&
    fields.originalTransactionId !== null
  );
}

/**
 * Cheap pre-filter for index.ts: whether this event's TYPE is even potentially referral-relevant
 * at all, before doing any alias/attribution lookup. Every other event type (RENEWAL,
 * PRODUCT_CHANGE, EXPIRATION, BILLING_ISSUE, UNCANCELLATION, a non-CUSTOMER_SUPPORT CANCELLATION,
 * TRANSFER, TEST, TEMPORARY_ENTITLEMENT_GRANT, ...) is a clean no-op for referral purposes — the
 * existing entitlement mirror still processes it exactly as before, referral processing is simply
 * never invoked for it (see this task's Phase 15 — a referral no-op must never affect entitlement
 * mirroring, and the cheapest possible no-op is not calling the referral path at all).
 */
export function isReferralRelevantEventType(eventType: string): boolean {
  return eventType === "INITIAL_PURCHASE" || eventType === "CANCELLATION" || eventType === "REFUND_REVERSED";
}

// MARK: — Database call shape (plain data only; database.ts imports these as types)

/** Mirrors private.process_referral_subscription_event's exact parameter list — see the referral
 *  migration. Plain data, no Deno/Postgres dependency, so it can be constructed and asserted on
 *  entirely under Node (see determineReferralAction's own tests). */
export interface ReferralActionInput {
  action: "qualify" | "refund_reversal" | "refund_reversed";
  appUserIdSet: string[];
  environment: RevenueCatWebhookEnvironment;
  eventId: string;
  purchasedAtMs: number | null;
  productId: string | null;
  transactionId: string | null;
  originalTransactionId: string | null;
  /** Required `true` for 'qualify'/'refund_reversed' — see the migration's own header for why
   *  this is supplied by the caller (a successful canonical RevenueCat refresh already performed
   *  for the SAME event, see index.ts's handleNormalEvent) rather than re-derived here. */
  canonicalProIsActive: boolean;
}

/** Mirrors private.process_referral_subscription_event's exact RETURNS TABLE shape. */
export interface ReferralActionResult {
  outcome: string;
  attributionId: string | null;
  referrerParticipantId: string | null;
  qualifiedCount: number | null;
}

/** The minimal facts about a "normal"-kind webhook event determineReferralAction needs, deliberately
 *  NOT the full ParsedWebhookEvent union — keeps this module decoupled from
 *  revenuecat-webhook-parser.ts's exact type shape (see this file's own header for why that parser
 *  is never imported here). index.ts constructs this directly from the `parsed` value it already
 *  has after a successful parseWebhookEvent call. */
export interface NormalEventReferralContext {
  eventType: string;
  environment: RevenueCatWebhookEnvironment;
  aliasSet: string[];
  eventId: string;
}

/**
 * Orchestrates the three classifiers above into the single ReferralActionInput index.ts should
 * pass to the database (or `undefined` for "do not call the referral path at all"). Pure and
 * independently testable: `envelope` is the same raw, already-JSON-parsed webhook body index.ts
 * already has in scope, and `canonicalProIsActive` is whatever the caller's own canonical
 * RevenueCat refresh for this SAME event already computed (see this file's header — Phase 9 of
 * the referral task: qualification/re-qualification must never proceed without it).
 */
export function determineReferralAction(
  context: NormalEventReferralContext,
  envelope: unknown,
  canonicalProIsActive: boolean,
): ReferralActionInput | undefined {
  if (!isReferralRelevantEventType(context.eventType)) return undefined;

  const fields = extractReferralWebhookFields(envelope);
  if (!fields) return undefined;

  const shared = {
    appUserIdSet: context.aliasSet,
    environment: context.environment,
    eventId: context.eventId,
    productId: fields.productId,
    transactionId: fields.transactionId,
    originalTransactionId: fields.originalTransactionId,
  };

  if (isReferralQualifyingEvent(fields)) {
    return { ...shared, action: "qualify", purchasedAtMs: fields.purchasedAtMs, canonicalProIsActive };
  }
  if (isReferralRefundReversalEvent(fields)) {
    return { ...shared, action: "refund_reversal", purchasedAtMs: null, canonicalProIsActive };
  }
  if (isReferralRequalificationEvent(fields)) {
    return { ...shared, action: "refund_reversed", purchasedAtMs: null, canonicalProIsActive };
  }
  return undefined;
}
