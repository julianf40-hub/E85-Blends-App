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
      event_id, event_type, app_user_id, environment, event_timestamp,
      payload_hash, raw_payload, processing_status
    ) values (
      ${input.eventId}, ${input.eventType}, ${input.appUserId}, ${input.environment},
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

export type ApplyRefreshResult =
  | { kind: "applied" }
  | { kind: "conflict"; detail: string };

/**
 * Applies EVERY plan in `plans` and marks the ledger row `processed`, all inside ONE transaction
 * (Phase B1 review Finding 4). For a normal event, `plans` has exactly one entry. For a TRANSFER
 * event, callers must have already fetched RevenueCat's canonical state for every group/
 * environment combination BEFORE calling this — this function performs no RevenueCat API calls of
 * its own, only database writes, so nothing here ever blocks on outbound HTTP.
 *
 * If ANY plan hits an identity conflict, the ENTIRE transaction rolls back — including any earlier
 * plan in the same batch that had already written its customer/alias rows within this same call.
 */
export async function applyRefreshPlansAndMarkProcessed(
  sql: Sql,
  eventId: string,
  plans: RefreshPlan[],
): Promise<ApplyRefreshResult> {
  try {
    await sql.begin(async (tx) => {
      for (const plan of plans) {
        await applyIdentityRefresh(tx, plan);
      }
      await tx`
        update private.revenuecat_webhook_events
        set processing_status = 'processed',
            processed_at = now(),
            error_message = null
        where event_id = ${eventId}
      `;
    });
    return { kind: "applied" };
  } catch (error) {
    if (error instanceof IdentityConflictError) {
      return { kind: "conflict", detail: error.message };
    }
    throw error;
  }
}
