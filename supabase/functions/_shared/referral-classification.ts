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
import { isReferralRewardOfferReference } from "./referral-reward-offer-codes.ts";

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
  /** 85Blends 2.4.0 Referral Reward Redemption — RevenueCat's own `offer_code` field: "Offer or
   *  promotion code used for the transaction," present (when applicable at all) on
   *  INITIAL_PURCHASE/RENEWAL/NON_RENEWING_PURCHASE events. For an Apple subscription Offer Code
   *  this is the App Store Connect Offer Code REFERENCE NAME (the single name field entered when
   *  the offer code is created) — never the literal one-time-use Apple code the customer typed
   *  (RevenueCat does not expose that), and not a separate "Offer Identifier" (Offer Codes have no
   *  such field; that belongs to Apple's different Promotional Offers mechanism) — see
   *  _shared/referral-reward-offer-codes.ts's own header. `null` for an ordinary, non-promotional
   *  purchase. */
  offerCode: string | null;
  /** 85Blends 2.4.0 Referral Reward Redemption, fourth correctness hardening pass — RevenueCat's
   *  own `price` field: the transaction's price converted to USD. RevenueCat documents this as
   *  optional/nullable (not every event type carries it, and it can be legitimately absent even on
   *  a genuine paid purchase). `null` never means "free" — it means "no price evidence available,"
   *  which this module's price rule (see `isDemonstrablyPaid`) treats as NOT sufficient proof of
   *  payment, deliberately failing conservative rather than assuming paid. */
  price: number | null;
  /** 85Blends 2.4.0 Referral Reward Redemption, fourth correctness hardening pass — RevenueCat's
   *  own `price_in_purchased_currency` field: the transaction's price in whatever currency the
   *  customer was actually charged in. Preferred over `price` as the primary paid/free signal (see
   *  `isDemonstrablyPaid`) since it reflects the actual charge without a USD-conversion step, but
   *  both are checked — either field reporting a clearly positive amount is treated as sufficient
   *  evidence of payment. Same nullability caveat as `price`. */
  priceInPurchasedCurrency: number | null;
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
    offerCode: asNonEmptyTrimmedString(eventRecord.offer_code),
    price: asFiniteNumber(eventRecord.price),
    priceInPurchasedCurrency: asFiniteNumber(eventRecord.price_in_purchased_currency),
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
 * Shared "shape" of a genuine, production purchase of one of the three qualifying products,
 * parameterized by which single event TYPE is being tested — used by both the paid-qualifying
 * check below and the deferred-paid-origin check (fourth correctness hardening pass). Deliberately
 * checked on the webhook event's own type/environment/period/product/transaction-identity shape
 * alone, never on price: PRODUCT_CHANGE, CANCELLATION, EXPIRATION, BILLING_ISSUE,
 * TEMPORARY_ENTITLEMENT_GRANT, NON_RENEWING_PURCHASE, trial/intro/promotional periods (anything
 * whose period_type isn't exactly `"NORMAL"`), and SANDBOX/TEST events are all excluded by
 * construction.
 *
 * Also requires `transactionId`/`originalTransactionId` to both be present (integrity hardening):
 * `originalTransactionId` is the sole match key a later refund/REFUND_REVERSED event uses to find
 * this exact attribution again (see the migration's `process_referral_subscription_event`) — an
 * event missing either id can never be reversed or re-confirmed later, so it must never qualify (or
 * be deferred) in the first place, regardless of how otherwise-eligible it looks. RevenueCat
 * documents both ids as always present on a genuine INITIAL_PURCHASE/RENEWAL; a qualifying-shaped
 * event missing one is treated as malformed, not as eligible.
 */
function isReferralCandidateShapeEvent(fields: ReferralWebhookFields, eventType: string): boolean {
  return (
    fields.eventType === eventType &&
    fields.environment === "PRODUCTION" &&
    fields.periodType === "NORMAL" &&
    fields.productId !== null &&
    REFERRAL_QUALIFYING_PRODUCT_IDS.includes(fields.productId) &&
    fields.transactionId !== null &&
    fields.originalTransactionId !== null
  );
}

/**
 * 85Blends 2.4.0 Referral Reward Redemption, fourth correctness hardening pass — TRUE only when
 * this event carries positive, trustworthy evidence that real money changed hands. Fails
 * conservative by design (per this feature's task spec): a clearly positive price is evidence of
 * payment; an explicit zero is evidence of NO payment; a missing/null price is NOT evidence of
 * payment either way and must never be treated as "probably paid." This is what closes the bug this
 * hardening pass exists for — RevenueCat can report `period_type: "NORMAL"` and a non-null
 * `offer_code` for the public 85BLENDS launch promo's free month exactly as it would for an
 * ordinary paid purchase; only the transaction's own economics (price), never the offer_code field
 * alone, can distinguish the two.
 *
 * Checks `price_in_purchased_currency` (the actual amount charged, in the customer's own currency)
 * and `price` (the same transaction converted to USD) independently — either one reporting a
 * clearly positive number is sufficient, since a genuinely free transaction is $0 in every
 * currency. Never requires both to agree; only one needs to be positive.
 */
function isDemonstrablyPaid(fields: ReferralWebhookFields): boolean {
  return (
    (fields.priceInPurchasedCurrency !== null && fields.priceInPurchasedCurrency > 0) ||
    (fields.price !== null && fields.price > 0)
  );
}

/**
 * Shared core of a "genuine, production, normal-priced paid purchase of one of the three qualifying
 * products" check, parameterized by which single event TYPE is being tested — see
 * `isReferralQualifyingEvent` (INITIAL_PURCHASE) and `isReferralRenewalQualificationCandidate`
 * (RENEWAL) below. Neither function alone is sufficient to qualify a referral — the caller must ALSO
 * have a successful canonical RevenueCat subscriber refresh confirming active `pro` before ever
 * calling the database qualification function (Phase 9 of the referral task — no "best effort"
 * qualification from the webhook payload alone).
 *
 * 85Blends 2.4.0 Referral Reward Redemption hardening: also excludes ANY event whose own
 * `offerCode` is one of the three dedicated referral-reward offer references
 * (isReferralRewardOfferReference) — a user must never generate a qualified referral (for whoever
 * referred THEM) merely by redeeming a free reward month someone else earned. This is a pure,
 * per-event check; it can never by itself distinguish "this person was never referred" from "this
 * free month's later real paid renewal should still be allowed to qualify a still-pending
 * attribution" — that second, narrower question is answered by
 * `isReferralRenewalQualificationCandidate` plus a database-backed proof check in
 * _shared/database.ts's applyReferralAction (see that file's own comment for the full loophole
 * analysis of why a bare timing check alone would be unsafe).
 *
 * Fourth correctness hardening pass: also requires `isDemonstrablyPaid` — see that function's own
 * header. An otherwise-qualifying-shaped event that is free/zero-price/unknown-price is never
 * excluded silently: see `isReferralDeferrablePaidOriginEvent` below for the narrow, safe path that
 * preserves a still-pending referral through a free/promotional start.
 */
function isCandidatePaidQualifyingEvent(fields: ReferralWebhookFields, eventType: string): boolean {
  return (
    isReferralCandidateShapeEvent(fields, eventType) &&
    !isReferralRewardOfferReference(fields.offerCode) &&
    isDemonstrablyPaid(fields)
  );
}

/** TRUE only for a genuine, production, first-time, normal-priced paid INITIAL_PURCHASE of one of
 *  the three qualifying products. See `isCandidatePaidQualifyingEvent`'s own header for the shared
 *  rule this applies. */
export function isReferralQualifyingEvent(fields: ReferralWebhookFields): boolean {
  return isCandidatePaidQualifyingEvent(fields, "INITIAL_PURCHASE");
}

/**
 * 85Blends 2.4.0 Referral Reward Redemption — TRUE for a RENEWAL event that otherwise looks exactly
 * like a qualifying paid purchase (see `isCandidatePaidQualifyingEvent`). This alone is NEVER
 * sufficient to qualify a referral: unlike an INITIAL_PURCHASE, a RENEWAL can belong to a
 * subscription that has been running for months, completely unrelated to when its participant
 * happened to apply someone's referral code — a bare `attributed_at <= this renewal's purchased_at`
 * timing check would let someone apply a code AFTER already being an unrelated, long-standing Pro
 * subscriber and have their very next ordinary renewal incorrectly "qualify" that late code
 * application. That is the exact loophole this feature's task spec prohibits ("Do not create a
 * loophole where someone can enter a referral code after becoming Pro and later qualify it.").
 *
 * The legitimate case this exists FOR: a participant applies a referral code before ever
 * subscribing, then redeems a referral-reward Offer Code as their very first purchase (excluded
 * from qualifying by `isCandidatePaidQualifyingEvent`'s own offer-code check, correctly — it's
 * free), and that subscription later renews for real money. THAT renewal should be allowed to
 * qualify the still-pending attribution. The two cases are only distinguishable with backend state
 * this pure classifier does not have access to (was this original_transaction_id's original
 * purchase actually one of our own referral-reward redemptions?) — see
 * _shared/database.ts's applyReferralAction, which performs that additional database-backed proof
 * check (querying private.referral_reward_offer_codes for a 'redeemed' row matching this same
 * original_transaction_id) BEFORE ever calling process_referral_subscription_event for a candidate
 * produced by this function — never for one produced by `isReferralQualifyingEvent`, which needs no
 * such extra proof (an INITIAL_PURCHASE is always the FIRST event for its own original_transaction_id,
 * so the ordinary `attributed_at <= purchased_at` check the database function already performs is
 * sufficient on its own).
 */
export function isReferralRenewalQualificationCandidate(fields: ReferralWebhookFields): boolean {
  return isCandidatePaidQualifyingEvent(fields, "RENEWAL");
}

/**
 * 85Blends 2.4.0 Referral Reward Redemption, fourth correctness hardening pass — TRUE only for an
 * INITIAL_PURCHASE that has every qualifying SHAPE characteristic (production, NORMAL period, one
 * of the three Pro products, both transaction ids present) but is NOT demonstrably paid (see
 * `isDemonstrablyPaid`) and does not carry one of our own dedicated referral-reward offer codes
 * (which already has its own established fulfillment/proof mechanism via
 * private.referral_reward_offer_codes — see referral-reward-offer-codes.ts and
 * _shared/database.ts's applyReferralAction — never duplicated here).
 *
 * This is the exact gap this hardening pass exists to close: the public 85BLENDS launch promo (and
 * any other free/zero-price/unknown-price start of one of the three Pro products) must never count
 * as a paid referral, but a referral already pending for this same participant must not be silently
 * and permanently lost either. `determineReferralAction` turns a TRUE result here into a
 * `defer_paid_origin` action — a narrow, database-backed proof recorded ONLY if this participant
 * already had a pending attribution whose `attributed_at` predates this exact purchase (see
 * _shared/database.ts's applyReferralAction and the migration's own
 * `record_referral_deferred_paid_origin` for the full mechanism, including why a referral code
 * applied AFTER this free start can never retroactively benefit from it). Recording (or failing to
 * record) this proof never itself qualifies anything — no attribution status or reward milestone
 * changes as a result.
 */
export function isReferralDeferrablePaidOriginEvent(fields: ReferralWebhookFields): boolean {
  return (
    isReferralCandidateShapeEvent(fields, "INITIAL_PURCHASE") &&
    !isReferralRewardOfferReference(fields.offerCode) &&
    !isDemonstrablyPaid(fields)
  );
}

/** The three reasons `determineReferralAction` can compute for a `defer_paid_origin` action's own
 *  audit trail (never used for any decision, only for a human/operator reading the ledger later).
 *  Mirrors the migration's `referral_deferred_paid_origins_reason` CHECK constraint exactly. */
export type ReferralDeferredPaidOriginReason = "free_offer_code" | "zero_price" | "unknown_price";

/**
 * Pure, audit-only categorization of WHY an event was deferred rather than immediately qualified —
 * never read by any later decision (the later RENEWAL-qualify proof check only checks for the
 * deferred-origin row's existence, never its reason). `offerCode` present at all (any non-reward
 * offer code — a reward offer code is already excluded before this is ever called, see
 * `isReferralDeferrablePaidOriginEvent`) is checked first since it's the most specific, most useful
 * fact for an operator investigating a promo campaign later; otherwise falls back to whether either
 * price field was an explicit zero (a confirmed free transaction) versus simply absent (a data gap
 * this pipeline can't further characterize).
 */
export function deferredPaidOriginReason(fields: ReferralWebhookFields): ReferralDeferredPaidOriginReason {
  if (fields.offerCode !== null) return "free_offer_code";
  const explicitZero =
    fields.price === 0 || fields.priceInPurchasedCurrency === 0;
  return explicitZero ? "zero_price" : "unknown_price";
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
 * at all, before doing any alias/attribution lookup. Every other event type (PRODUCT_CHANGE,
 * EXPIRATION, BILLING_ISSUE, UNCANCELLATION, a non-CUSTOMER_SUPPORT CANCELLATION, TRANSFER, TEST,
 * TEMPORARY_ENTITLEMENT_GRANT, ...) is a clean no-op for referral purposes — the existing
 * entitlement mirror still processes it exactly as before, referral processing is simply never
 * invoked for it (see this task's Phase 15 — a referral no-op must never affect entitlement
 * mirroring, and the cheapest possible no-op is not calling the referral path at all).
 *
 * 85Blends 2.4.0 Referral Reward Redemption: RENEWAL is now included — see
 * `isReferralRenewalQualificationCandidate`'s own header for why a RENEWAL can (narrowly) qualify a
 * still-pending attribution. This does mean referral processing is now attempted on the single
 * highest-volume RevenueCat event type (every renewal, for every Pro subscriber, fires this check),
 * not just the rarer INITIAL_PURCHASE/CANCELLATION/REFUND_REVERSED — an accepted, modest cost (one
 * additional indexed lookup per renewal in the common case where nothing is pending) documented in
 * this feature's own report, not an oversight.
 */
export function isReferralRelevantEventType(eventType: string): boolean {
  return (
    eventType === "INITIAL_PURCHASE" ||
    eventType === "RENEWAL" ||
    eventType === "CANCELLATION" ||
    eventType === "REFUND_REVERSED"
  );
}

// MARK: — Database call shape (plain data only; database.ts imports these as types)

/** Mirrors private.process_referral_subscription_event's exact parameter list — see the referral
 *  migration. Plain data, no Deno/Postgres dependency, so it can be constructed and asserted on
 *  entirely under Node (see determineReferralAction's own tests). */
export interface ReferralActionInput {
  action: "qualify" | "refund_reversal" | "refund_reversed" | "defer_paid_origin";
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
  /** 85Blends 2.4.0 Referral Reward Redemption — true only for a 'qualify' action produced from a
   *  RENEWAL event (see `isReferralRenewalQualificationCandidate`'s own header). Tells
   *  _shared/database.ts's applyReferralAction to perform the additional database-backed proof
   *  check (this original_transaction_id traces back to one of our own redeemed referral-reward
   *  offer codes) BEFORE ever calling process_referral_subscription_event — never set for a
   *  'qualify' action produced from an INITIAL_PURCHASE (which needs no such proof) or for
   *  'refund_reversal'/'refund_reversed' (irrelevant to either). */
  requiresRewardRedemptionProof: boolean;
  /** 85Blends 2.4.0 Referral Reward Redemption, fourth correctness hardening pass — set only for a
   *  `defer_paid_origin` action (see `isReferralDeferrablePaidOriginEvent`/
   *  `deferredPaidOriginReason`). Audit-only; never read by any qualification decision. */
  deferredReason?: ReferralDeferredPaidOriginReason;
  /** 85Blends 2.4.0 Referral Reward Redemption, fourth correctness hardening pass — set only for a
   *  `defer_paid_origin` action: the event's own `offer_code` (an App Store Connect offer
   *  REFERENCE NAME, never the raw one-time Apple code — see referral-reward-offer-codes.ts's own
   *  header), kept purely for later audit of which promo/offer a deferred origin came from. `null`
   *  when the free/unknown-price purchase carried no offer code at all. */
  offerReferenceForAudit?: string | null;
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
    return {
      ...shared,
      action: "qualify",
      purchasedAtMs: fields.purchasedAtMs,
      canonicalProIsActive,
      requiresRewardRedemptionProof: false,
    };
  }
  if (isReferralRenewalQualificationCandidate(fields)) {
    return {
      ...shared,
      action: "qualify",
      purchasedAtMs: fields.purchasedAtMs,
      canonicalProIsActive,
      requiresRewardRedemptionProof: true,
    };
  }
  if (isReferralDeferrablePaidOriginEvent(fields)) {
    return {
      ...shared,
      action: "defer_paid_origin",
      purchasedAtMs: fields.purchasedAtMs,
      canonicalProIsActive,
      requiresRewardRedemptionProof: false,
      deferredReason: deferredPaidOriginReason(fields),
      offerReferenceForAudit: fields.offerCode,
    };
  }
  if (isReferralRefundReversalEvent(fields)) {
    return {
      ...shared,
      action: "refund_reversal",
      purchasedAtMs: null,
      canonicalProIsActive,
      requiresRewardRedemptionProof: false,
    };
  }
  if (isReferralRequalificationEvent(fields)) {
    return {
      ...shared,
      action: "refund_reversed",
      purchasedAtMs: null,
      canonicalProIsActive,
      requiresRewardRedemptionProof: false,
    };
  }
  return undefined;
}
