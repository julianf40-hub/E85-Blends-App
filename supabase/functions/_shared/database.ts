// 85Blends 2.3.0 — Phase B1. Postgres access — the ONLY file in this function that talks to the
// database.
//
// NOT unit-testable under Node: uses the Deno-idiomatic `npm:postgres` specifier, which Node
// cannot resolve without a package.json/node_modules this project deliberately doesn't have (see
// supabase/README.md). This file is therefore static-review-only in this environment — no local
// Postgres/Docker stack was available either (see the Phase B1 review-repair report). Every
// DECISION this file makes (idempotency, customer resolution, alias-upsert conflict detection,
// post-insert alias re-verification) is delegated to the pure, Node-tested modules in
// idempotency.ts and customer-resolution.ts — this file only runs the SQL those decisions imply.
// Keep it that way: do not move decision logic back in here.
//
// `private` is intentionally never added to Supabase's exposed API schemas (see
// supabase/config.toml, supabase/README.md) — this direct Postgres connection via
// SUPABASE_DB_URL is the access path that was always intended for it, not a workaround.
//
// TRANSACTION ARCHITECTURE (Phase B1 review Findings 3 & 4, Concurrency Hardenings 1 & 2):
//   - The ledger CLAIM (claimLedgerEvent) is its own atomic `INSERT ... ON CONFLICT DO NOTHING
//     RETURNING` — safe under concurrent delivery of the same brand-new event_id without needing
//     an enclosing transaction, and deliberately happens BEFORE any RevenueCat API call (Phase 11
//     — never hold a transaction, or in this case even a lock, across an outbound HTTP call).
//   - Every RevenueCat API call this function makes happens with NO open transaction.
//   - Exactly ONE short transaction (applyRefreshPlansAndMarkProcessed) applies ALL of a request's
//     normalized customer/alias mutations AND marks the ledger row `processed`, together,
//     atomically. A normal event produces exactly one RefreshPlan; a TRANSFER event produces up to
//     four (source/destination × up to two environments) — either way, ALL of them are applied (or
//     none are) in that one transaction, never one transaction per plan.
//   - A conflict detected at any point inside that transaction is signaled by THROWING
//     IdentityConflictError, not by returning a value — a normal `return` from a postgres.js
//     `sql.begin()` callback COMMITS, so returning a "conflict" value after already having
//     inserted/updated rows earlier in the same callback would silently commit that partial state.
//     Throwing is what makes postgres.js roll back everything the callback did.

import postgres from "npm:postgres@3.4.5";
import { decideIdempotency, type ExistingLedgerRow, type IdempotencyDecision } from "./idempotency.ts";
import {
  planAliasUpserts,
  resolveCanonicalCustomer,
  verifyAliasesAfterInsert,
  type MatchedAliasRow,
} from "./customer-resolution.ts";
import type { EntitlementCalculationResult } from "./entitlement.ts";
import type { ReferralActionInput, ReferralActionResult } from "./referral-classification.ts";
import type { ReferralRewardFulfillmentCandidate } from "./referral-reward-offer-codes.ts";
import { maskIdentifier, logWebhookEvent } from "./logging.ts";

export type Sql = ReturnType<typeof postgres>;

/**
 * Creates the Postgres client used for the lifetime of one function instance. `prepare: false`
 * per the task spec — Supabase's connection pooler may run in transaction mode, which does not
 * support server-side prepared statements. Deliberately does not log or embed `dbUrl` anywhere;
 * the caller (index.ts) reads it from `SUPABASE_DB_URL` at request time and passes it straight
 * through.
 */
export function createDatabaseClient(dbUrl: string): Sql {
  return postgres(dbUrl, {
    prepare: false,
    max: 1, // one Edge Function invocation, one short-lived connection — no pooling needed here.
    connect_timeout: 10,
    idle_timeout: 5,
  });
}

export interface LedgerEventInput {
  eventId: string;
  eventType: string;
  appUserId: string | null;
  /** RevenueCat's `original_app_user_id`, when the event provides one — ledger-completeness only
   *  (see this file's `claimLedgerEvent`). Purely a record of what RevenueCat sent; never read by
   *  any entitlement/identity-resolution code path — those all operate on
   *  private.revenuecat_customers/revenuecat_aliases via the caller's own aliasSet/preferredAnchor
   *  (see index.ts), never via this ledger column. */
  originalAppUserId: string | null;
  environment: "SANDBOX" | "PRODUCTION" | null;
  eventTimestampMs: number;
  payloadHash: string;
  rawPayload: unknown;
}

/** Reads the existing ledger row for an event_id, if any — used only to feed decideIdempotency(). */
async function getExistingLedgerRow(sql: Sql, eventId: string): Promise<ExistingLedgerRow | null> {
  const rows = await sql<{ payload_hash: string; processing_status: string }[]>`
    select payload_hash, processing_status
    from private.revenuecat_webhook_events
    where event_id = ${eventId}
  `;
  if (rows.length === 0) return null;
  return { payloadHash: rows[0].payload_hash, processingStatus: rows[0].processing_status };
}

/**
 * Claims (or inspects) the ledger row for one event, atomically (Concurrency Hardening 1). The
 * `INSERT ... ON CONFLICT (event_id) DO NOTHING RETURNING` is a single statement — if it returns a
 * row, THIS call is unambiguously the one that created it, even under concurrent delivery of the
 * same brand-new event_id; there is no separate "check, then insert" window for two concurrent
 * requests to both observe "absent". If it returns no row, some other request (or a prior delivery)
 * already claimed this event_id, and we fall back to reading + deciding from that existing row.
 */
export async function claimLedgerEvent(sql: Sql, input: LedgerEventInput): Promise<IdempotencyDecision> {
  const inserted = await sql<{ payload_hash: string; processing_status: string }[]>`
    insert into private.revenuecat_webhook_events (
      event_id, event_type, app_user_id, original_app_user_id, environment, event_timestamp,
      payload_hash, raw_payload, processing_status
    ) values (
      ${input.eventId}, ${input.eventType}, ${input.appUserId}, ${input.originalAppUserId}, ${input.environment},
      to_timestamp(${input.eventTimestampMs}::double precision / 1000.0),
      ${input.payloadHash}, ${sql.json(input.rawPayload as object)}, 'received'
    )
    on conflict (event_id) do nothing
    returning payload_hash, processing_status
  `;

  if (inserted.length > 0) {
    return { kind: "new" };
  }

  const existing = await getExistingLedgerRow(sql, input.eventId);
  return decideIdempotency(existing, input.payloadHash);
}

/**
 * Marks a ledger row `processed` with NO customer/alias mutation — used only for event kinds that
 * are, by design, never supposed to touch private.revenuecat_customers/aliases at all (TEST,
 * `insufficient`, TEMPORARY_ENTITLEMENT_GRANT — see revenuecat-webhook-parser.ts and index.ts).
 * Any event that DOES need a normalized write goes through `applyRefreshPlansAndMarkProcessed`
 * instead, which marks the ledger row processed atomically WITH that write — never this function.
 */
export async function markLedgerProcessed(sql: Sql, eventId: string, note?: string): Promise<void> {
  await sql`
    update private.revenuecat_webhook_events
    set processing_status = 'processed',
        processed_at = now(),
        error_message = ${note ?? null}
    where event_id = ${eventId}
  `;
}

export async function markLedgerError(sql: Sql, eventId: string, errorMessage: string): Promise<void> {
  await sql`
    update private.revenuecat_webhook_events
    set processing_status = 'error',
        error_message = ${errorMessage}
    where event_id = ${eventId}
  `;
}

/**
 * Phase 10 + Phase B1 review "hash-mismatch ledger hardening": same event_id, different payload —
 * flagged for investigation, but a row that already reached `processed` must NEVER be regressed by
 * a later mismatched delivery. `previousStatus` comes straight from the same
 * `IdempotencyDecision` the caller already has (see idempotency.ts's `decideIdempotency`) — no
 * extra read needed. The `and processing_status <> 'processed'` in the WHERE clause is a second,
 * belt-and-suspenders guard against the (already-unlikely) case where the row's status changed
 * between the decision and this call — this UPDATE never touches `payload_hash` either way, so the
 * originally recorded payload is preserved regardless.
 */
export async function markLedgerHashMismatch(sql: Sql, eventId: string, previousStatus: string): Promise<void> {
  if (previousStatus === "processed") return;
  await sql`
    update private.revenuecat_webhook_events
    set processing_status = 'error',
        error_message = 'payload_hash mismatch on redelivery of the same event_id'
    where event_id = ${eventId}
      and processing_status <> 'processed'
  `;
}

/** Thrown inside a transaction to force a rollback on any identity conflict — see this file's
 *  header comment for why a normal return value is not safe here. Never thrown outside a
 *  `sql.begin()` callback. */
export class IdentityConflictError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "IdentityConflictError";
  }
}

export interface RefreshPlan {
  aliasSet: string[];
  environment: "SANDBOX" | "PRODUCTION";
  preferredAnchor: string;
  entitlement: EntitlementCalculationResult;
  /** The webhook event that triggered this specific plan — written to the resolved customer
   *  row's last_trigger_event_id. For a normal event every plan shares one event; for TRANSFER,
   *  every plan also shares the one TRANSFER event's id (see index.ts) — this is per-plan rather
   *  than a single shared parameter only so applyIdentityRefresh doesn't need a second argument. */
  triggerEventId: string;
}

/**
 * Applies ONE identity group's resolved entitlement state using the TRANSACTION-scoped `tx`
 * handle passed in (never the outer, non-transactional `sql`). Throws `IdentityConflictError` —
 * never returns a "conflict" value — the moment any conflict is detected, so `sql.begin()` rolls
 * back everything this call (and any earlier plan in the same batch — see
 * applyRefreshPlansAndMarkProcessed) has done so far.
 */
async function applyIdentityRefresh(tx: Sql, plan: RefreshPlan): Promise<void> {
  const { aliasSet, environment, preferredAnchor, entitlement, triggerEventId } = plan;

  const matchedAliasRows = await tx<{ app_user_id: string; customer_id: string }[]>`
    select app_user_id, customer_id
    from private.revenuecat_aliases
    where environment = ${environment}
      and app_user_id = any(${tx.array(aliasSet)})
  `;
  const matched: MatchedAliasRow[] = matchedAliasRows.map((row) => ({
    appUserId: row.app_user_id,
    customerId: row.customer_id,
  }));

  const resolution = resolveCanonicalCustomer(matched, preferredAnchor);

  if (resolution.kind === "conflict") {
    logWebhookEvent("error", "alias identity conflict — refusing to merge customers", {
      environment,
      matchedCustomerCount: resolution.matchedCustomerIds.length,
      anchor: maskIdentifier(preferredAnchor),
    });
    throw new IdentityConflictError(
      `${resolution.matchedCustomerIds.length} distinct customers matched this event's alias set (environment ${environment})`,
    );
  }

  let customerId: string;
  if (resolution.kind === "create") {
    const inserted = await tx<{ id: string }[]>`
      insert into private.revenuecat_customers (
        original_app_user_id, environment, entitlement_id,
        pro_is_active, pro_expires_at, last_synced_at, last_trigger_event_id
      ) values (
        ${resolution.anchorAppUserId}, ${environment}, 'pro',
        ${entitlement.proIsActive}, ${entitlement.proExpiresAt}, now(), ${triggerEventId}
      )
      returning id
    `;
    customerId = inserted[0].id;
  } else {
    customerId = resolution.customerId;
    await tx`
      update private.revenuecat_customers
      set pro_is_active = ${entitlement.proIsActive},
          pro_expires_at = ${entitlement.proExpiresAt},
          last_synced_at = now(),
          last_trigger_event_id = ${triggerEventId}
      where id = ${customerId}
    `;
  }

  const aliasPlan = planAliasUpserts(aliasSet, customerId, matched);
  if (aliasPlan.kind === "conflict") {
    logWebhookEvent("error", "alias upsert conflict — an alias already belongs to a different customer", {
      environment,
      conflictingCount: aliasPlan.conflictingAppUserIds.length,
    });
    throw new IdentityConflictError(
      `${aliasPlan.conflictingAppUserIds.length} alias(es) already belong to a different customer (environment ${environment})`,
    );
  }

  for (const appUserId of aliasPlan.toInsert) {
    await tx`
      insert into private.revenuecat_aliases (app_user_id, environment, customer_id)
      values (${appUserId}, ${environment}, ${customerId})
      on conflict (app_user_id, environment) do nothing
    `;
  }

  // Concurrency Hardening 2: re-read every alias in this plan, fresh, inside this same
  // transaction, AFTER the inserts above — under Postgres's READ COMMITTED semantics this new
  // SELECT sees any conflicting mapping a concurrent transaction committed in the window between
  // our first SELECT (above) and our own INSERT — something the first SELECT alone cannot catch.
  const rowsAfterInsert = await tx<{ app_user_id: string; customer_id: string }[]>`
    select app_user_id, customer_id
    from private.revenuecat_aliases
    where environment = ${environment}
      and app_user_id = any(${tx.array(aliasSet)})
  `;
  const verification = verifyAliasesAfterInsert(
    aliasSet,
    customerId,
    rowsAfterInsert.map((row) => ({ appUserId: row.app_user_id, customerId: row.customer_id })),
  );
  if (verification.kind === "conflict") {
    logWebhookEvent("error", "alias race detected after insert — rolling back", {
      environment,
      problemCount: verification.problemAppUserIds.length,
    });
    throw new IdentityConflictError(
      `alias race detected after insert: ${verification.problemAppUserIds.length} alias(es) not correctly mapped (environment ${environment})`,
    );
  }
}

/**
 * 85Blends 2.4.0 — invokes private.process_referral_subscription_event(...) using the
 * TRANSACTION-scoped `tx` handle, so a qualification/reversal/re-qualification and its milestone
 * reconciliation land in the SAME transaction as the entitlement-mirror write and the ledger
 * `processed` mark (see applyRefreshPlansAndMarkProcessed below). This is a deliberate departure
 * from this file's own "throw on conflict, never return one" rule for identity conflicts: a
 * REFERRAL identity conflict (see referral-classification.ts's header) is a normal, expected,
 * NON-fatal outcome of that database function — it must never roll back the entitlement mirror
 * this transaction is also writing (see the referral migration's own header and Phase 15 of the
 * referral task). Only a genuine thrown error from this call (a real infrastructure/SQL failure,
 * not a structured "nothing to do" result) propagates and rolls back the transaction, exactly like
 * any other genuine error already does elsewhere in this same transaction.
 *
 * 85Blends 2.4.0 Referral Reward Redemption, fourth correctness hardening pass — a `defer_paid_origin`
 * action (see referral-classification.ts's isReferralDeferrablePaidOriginEvent) is handled entirely
 * separately, below: it never calls process_referral_subscription_event at all (recording a
 * deferred origin must never itself qualify anything or touch attribution/reward state), and it
 * needs no reward-redemption proof (it's the mechanism that later PRODUCES that proof for a
 * RENEWAL-triggered qualify attempt — see the generalized proof check further down).
 */
async function applyReferralAction(tx: Sql, input: ReferralActionInput): Promise<ReferralActionResult> {
  type Row = { outcome: string; attribution_id: string | null; referrer_participant_id: string | null; qualified_count: number | null };

  if (input.action === "defer_paid_origin") {
    type DeferRow = { outcome: string; attribution_id: string | null; referrer_participant_id: string | null };
    let deferRows: DeferRow[];
    try {
      deferRows = await tx<DeferRow[]>`
        select * from private.record_referral_deferred_paid_origin(
          ${tx.array(input.appUserIdSet)},
          ${input.environment},
          ${input.eventId},
          ${input.purchasedAtMs},
          ${input.productId},
          ${input.transactionId},
          ${input.originalTransactionId},
          ${input.deferredReason ?? null},
          ${input.offerReferenceForAudit ?? null}
        )
      `;
    } catch (error) {
      // Same deployment-ordering guard as every other referral schema call in this file — degrades
      // to a clean skip, never a rollback of the entitlement mirror this same transaction is also
      // writing.
      const code = (error as { code?: string } | null)?.code;
      if (code === "42883" || code === "42P01") {
        return { outcome: "referral_deferred_origin_schema_unavailable", attributionId: null, referrerParticipantId: null, qualifiedCount: null };
      }
      throw error;
    }
    const deferRow = deferRows[0];
    return {
      outcome: deferRow.outcome,
      attributionId: deferRow.attribution_id,
      referrerParticipantId: deferRow.referrer_participant_id,
      qualifiedCount: null,
    };
  }

  // 85Blends 2.4.0 Referral Reward Redemption — the additional database-backed proof check
  // referral-classification.ts's isReferralRenewalQualificationCandidate's own header describes:
  // a RENEWAL-triggered 'qualify' attempt may proceed ONLY if THIS original_transaction_id traces
  // back to a purchase that was legitimately excluded from qualifying when it originally happened
  // (it was free), making this renewal its first genuinely paid transaction. Never applied to an
  // INITIAL_PURCHASE-triggered qualify (which needs no such proof — see that same header for why).
  // A missing proof row is a clean, safe no-op — never an error, and never falls through to calling
  // process_referral_subscription_event at all, so no attribution/reward state is touched.
  //
  // Fourth correctness hardening pass: this proof now has TWO independent sources, either one
  // sufficient on its own — never re-checked against each other, since both already independently
  // guarantee "this exact original_transaction_id's original purchase was free/excluded AND (for
  // the deferred-origin source) had a pending attribution predating it":
  //   1. private.referral_reward_offer_codes — our own dedicated referral-reward Offer Codes
  //      (REFERRAL_REWARD_*), unchanged from the original mechanism.
  //   2. private.referral_deferred_paid_origins — every OTHER free/zero-price/unknown-price start
  //      (including the public 85BLENDS launch promo), populated only by a 'defer_paid_origin'
  //      action above, itself only ever recorded when a pending attribution already existed before
  //      that free purchase (see record_referral_deferred_paid_origin's own header — this is what
  //      keeps a referral code applied AFTER an unrelated free/promo start from ever qualifying).
  if (input.action === "qualify" && input.requiresRewardRedemptionProof) {
    let proven: boolean;
    try {
      const proofRows = await tx<{ proven: boolean }[]>`
        select (
          exists(
            select 1 from private.referral_reward_offer_codes
            where redemption_original_transaction_id = ${input.originalTransactionId}
              and status = 'redeemed'
          )
          or exists(
            select 1 from private.referral_deferred_paid_origins
            where original_transaction_id = ${input.originalTransactionId}
              and environment = ${input.environment}
          )
        ) as proven
      `;
      proven = proofRows[0].proven;
    } catch (error) {
      // Same deployment-ordering guard as the try/catch below — this feature's own migration may
      // not be deployed yet. Degrades to a clean skip, never a rollback of the entitlement mirror.
      const code = (error as { code?: string } | null)?.code;
      if (code === "42883" || code === "42P01") {
        return { outcome: "referral_reward_schema_unavailable", attributionId: null, referrerParticipantId: null, qualifiedCount: null };
      }
      throw error;
    }
    if (!proven) {
      return { outcome: "reward_redemption_not_proven", attributionId: null, referrerParticipantId: null, qualifiedCount: null };
    }
  }

  let rows: Row[];
  try {
    rows = await tx<Row[]>`
      select * from private.process_referral_subscription_event(
        ${input.action},
        ${tx.array(input.appUserIdSet)},
        ${input.environment},
        ${input.eventId},
        ${input.purchasedAtMs},
        ${input.productId},
        ${input.transactionId},
        ${input.originalTransactionId},
        ${input.canonicalProIsActive}
      )
    `;
  } catch (error) {
    // Deployment-ordering guard: the referral migration (private.process_referral_subscription_event
    // and its supporting schema) must be applied to the live project BEFORE this updated function
    // code is ever deployed — see the referral foundation report's "safe order of operations." If
    // it somehow isn't yet — Postgres 42883 undefined_function / 42P01 undefined_table — referral
    // processing degrades to a clean skip rather than rolling back the entitlement-mirror write
    // this same transaction is also making (Phase 15's "referral is secondary" priority, applied to
    // the one failure mode a deployment-ordering mistake could actually cause). Any OTHER error —
    // a real bug once the schema does exist — still propagates and rolls back, exactly as before;
    // this catch is deliberately narrow, not a blanket swallow.
    const code = (error as { code?: string } | null)?.code;
    if (code === "42883" || code === "42P01") {
      logWebhookEvent("warn", "referral schema not yet deployed — skipping referral processing for this event", {});
      return { outcome: "referral_schema_unavailable", attributionId: null, referrerParticipantId: null, qualifiedCount: null };
    }
    throw error;
  }
  const row = rows[0];
  return {
    outcome: row.outcome,
    attributionId: row.attribution_id,
    referrerParticipantId: row.referrer_participant_id,
    qualifiedCount: row.qualified_count,
  };
}

/**
 * 85Blends 2.4.0 Referral Reward Redemption — invokes
 * private.fulfill_referral_reward_offer_code(...) using the TRANSACTION-scoped `tx` handle, so a
 * confirmed redemption lands in the SAME transaction as the entitlement-mirror write and the ledger
 * `processed` mark — same "referral processing must never roll back the entitlement mirror" posture
 * as applyReferralAction above (a candidate's own normal outcomes are never errors), and the same
 * deployment-ordering guard (this feature's migration may not be deployed yet).
 */
async function applyReferralRewardFulfillment(
  tx: Sql,
  candidate: ReferralRewardFulfillmentCandidate,
): Promise<{ outcome: string; rewardId: string | null; referrerParticipantId: string | null }> {
  type Row = { outcome: string; reward_id: string | null; referrer_participant_id: string | null };
  let rows: Row[];
  try {
    rows = await tx<Row[]>`
      select * from private.fulfill_referral_reward_offer_code(
        ${tx.array(candidate.appUserIdSet)},
        ${candidate.environment},
        ${candidate.productId},
        ${candidate.offerReferenceName},
        ${candidate.transactionId},
        ${candidate.originalTransactionId},
        ${candidate.eventId}
      )
    `;
  } catch (error) {
    const code = (error as { code?: string } | null)?.code;
    if (code === "42883" || code === "42P01") {
      logWebhookEvent("warn", "referral reward schema not yet deployed — skipping fulfillment for this event", {});
      return { outcome: "referral_reward_schema_unavailable", rewardId: null, referrerParticipantId: null };
    }
    throw error;
  }
  const row = rows[0];
  return { outcome: row.outcome, rewardId: row.reward_id, referrerParticipantId: row.referrer_participant_id };
}

export type ApplyRefreshResult =
  | {
      kind: "applied";
      referralResult?: ReferralActionResult;
      rewardFulfillmentResult?: { outcome: string; rewardId: string | null; referrerParticipantId: string | null };
    }
  | { kind: "conflict"; detail: string };

/**
 * Applies EVERY plan in `plans`, optionally processes ONE referral action and/or ONE referral
 * reward fulfillment candidate, and marks the ledger row `processed` — all inside ONE transaction
 * (Phase B1 review Finding 4; referral processing extends this same guarantee, 85Blends 2.4.0). For
 * a normal event, `plans` has exactly one entry. For a TRANSFER event, callers must have already
 * fetched RevenueCat's canonical state for every group/environment combination BEFORE calling this
 * — this function performs no RevenueCat API calls of its own, only database writes, so nothing
 * here ever blocks on outbound HTTP.
 *
 * `referralAction` is omitted entirely for TRANSFER events and for any normal event that isn't
 * referral-relevant (see referral-classification.ts's isReferralRelevantEventType).
 * `rewardFulfillmentCandidate` (85Blends 2.4.0) is omitted for TRANSFER events and for any normal
 * event whose own offer code isn't one of the three dedicated referral-reward offer references (see
 * referral-reward-offer-codes.ts's determineReferralRewardFulfillmentCandidate) — a normal event can
 * be BOTH referral-irrelevant AND a fulfillment candidate (a RENEWAL carrying a referral-reward
 * offer code is never itself referral-relevant to qualify anything, since isReferralQualifyingEvent/
 * isReferralRenewalQualificationCandidate both exclude referral-reward offer codes — but that exact
 * same event IS what fulfillment exists to detect). When both are omitted, this function's behavior
 * is byte-for-byte identical to before 85Blends 2.4.0.
 *
 * If ANY plan hits an identity conflict, OR the referral action/fulfillment call throws a genuine
 * error, the ENTIRE transaction rolls back — including any earlier plan in the same batch that had
 * already written its customer/alias rows within this same call. Either call's own NORMAL outcomes
 * (no participant, no attribution, identity conflict, too late, already processed, already
 * fulfilled, no outstanding code, …) are never errors and never roll back anything — see each
 * function's own header.
 */
export async function applyRefreshPlansAndMarkProcessed(
  sql: Sql,
  eventId: string,
  plans: RefreshPlan[],
  referralAction?: ReferralActionInput,
  rewardFulfillmentCandidate?: ReferralRewardFulfillmentCandidate,
): Promise<ApplyRefreshResult> {
  try {
    let referralResult: ReferralActionResult | undefined;
    let rewardFulfillmentResult: { outcome: string; rewardId: string | null; referrerParticipantId: string | null } | undefined;
    await sql.begin(async (tx) => {
      for (const plan of plans) {
        await applyIdentityRefresh(tx, plan);
      }
      if (referralAction) {
        referralResult = await applyReferralAction(tx, referralAction);
      }
      if (rewardFulfillmentCandidate) {
        rewardFulfillmentResult = await applyReferralRewardFulfillment(tx, rewardFulfillmentCandidate);
      }
      await tx`
        update private.revenuecat_webhook_events
        set processing_status = 'processed',
            processed_at = now(),
            error_message = null
        where event_id = ${eventId}
      `;
    });
    return { kind: "applied", referralResult, rewardFulfillmentResult };
  } catch (error) {
    if (error instanceof IdentityConflictError) {
      return { kind: "conflict", detail: error.message };
    }
    throw error;
  }
}
