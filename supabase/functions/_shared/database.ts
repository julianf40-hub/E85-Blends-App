// 85Blends 2.3.0 — Phase B1. Postgres access — the ONLY file in this function that talks to the
// database.
//
// NOT unit-testable under Node: uses the Deno-idiomatic `npm:postgres` specifier, which Node
// cannot resolve without a package.json/node_modules this project deliberately doesn't have (see
// supabase/README.md). This file is therefore static-review-only in this environment — no local
// Postgres/Docker stack was available either (see the Phase B1 final report). Every DECISION this
// file makes (idempotency, customer resolution, alias-upsert conflict detection) is delegated to
// the pure, Node-tested modules in idempotency.ts and customer-resolution.ts — this file only
// runs the SQL those decisions imply. Keep it that way: do not move decision logic back in here.
//
// `private` is intentionally never added to Supabase's exposed API schemas (see
// supabase/config.toml, supabase/README.md) — this direct Postgres connection via
// SUPABASE_DB_URL is the access path that was always intended for it, not a workaround.

import postgres from "npm:postgres@3.4.5";
import { decideIdempotency, type ExistingLedgerRow, type IdempotencyDecision } from "./idempotency.ts";
import {
  planAliasUpserts,
  resolveCanonicalCustomer,
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

async function insertLedgerRow(sql: Sql, input: LedgerEventInput): Promise<void> {
  await sql`
    insert into private.revenuecat_webhook_events (
      event_id, event_type, app_user_id, environment, event_timestamp,
      payload_hash, raw_payload, processing_status
    ) values (
      ${input.eventId}, ${input.eventType}, ${input.appUserId}, ${input.environment},
      to_timestamp(${input.eventTimestampMs}::double precision / 1000.0),
      ${input.payloadHash}, ${sql.json(input.rawPayload as object)}, 'received'
    )
  `;
}

/**
 * Claims (or inspects) the ledger row for one event. Inserts a new `received` row for a genuinely
 * new event_id; leaves an existing row untouched otherwise — the caller decides what to do next
 * from the returned `IdempotencyDecision` (see idempotency.ts). Never mutates
 * private.revenuecat_customers/aliases — that only happens in `refreshIdentityGroup` below, and
 * only for the "new"/"duplicate_retryable" decisions.
 */
export async function claimLedgerEvent(sql: Sql, input: LedgerEventInput): Promise<IdempotencyDecision> {
  const existing = await getExistingLedgerRow(sql, input.eventId);
  const decision = decideIdempotency(existing, input.payloadHash);
  if (decision.kind === "new") {
    await insertLedgerRow(sql, input);
  }
  return decision;
}

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

/** Phase 10: same event_id, different payload — never processed, flagged for investigation. */
export async function markLedgerHashMismatch(sql: Sql, eventId: string): Promise<void> {
  await sql`
    update private.revenuecat_webhook_events
    set processing_status = 'error',
        error_message = 'payload_hash mismatch on redelivery of the same event_id'
    where event_id = ${eventId}
  `;
}

export type RefreshOutcome =
  | { kind: "applied"; customerId: string }
  | { kind: "conflict"; detail: string };

/**
 * The one transactional core this whole function uses to write normalized entitlement state.
 * Called once per "identity group" — a normal event's single alias set, or (for TRANSFER) once
 * per transferred_from/transferred_to group, per environment. Must be called with the RevenueCat
 * API result ALREADY fetched (Phase 11 — never hold this transaction open across an outbound
 * HTTP call) and already known to be a successful/empty result — callers must short-circuit to
 * `markLedgerError` + a 500 response *before* calling this if the API call itself failed
 * (retryable_error/config_error), never inside the transaction.
 */
export async function refreshIdentityGroup(
  sql: Sql,
  params: {
    aliasSet: string[];
    environment: "SANDBOX" | "PRODUCTION";
    preferredAnchor: string;
    entitlement: EntitlementCalculationResult;
    triggerEventId: string;
  },
): Promise<RefreshOutcome> {
  const { aliasSet, environment, preferredAnchor, entitlement, triggerEventId } = params;

  return await sql.begin(async (sql) => {
    const matchedAliasRows = await sql<{ app_user_id: string; customer_id: string }[]>`
      select app_user_id, customer_id
      from private.revenuecat_aliases
      where environment = ${environment}
        and app_user_id = any(${sql.array(aliasSet)})
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
        triggerEventId,
      });
      return {
        kind: "conflict",
        detail: `${resolution.matchedCustomerIds.length} distinct customers matched this event's alias set`,
      } as const;
    }

    let customerId: string;
    if (resolution.kind === "create") {
      const inserted = await sql<{ id: string }[]>`
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
      await sql`
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
        triggerEventId,
      });
      return {
        kind: "conflict",
        detail: `${aliasPlan.conflictingAppUserIds.length} alias(es) already belong to a different customer`,
      } as const;
    }

    for (const appUserId of aliasPlan.toInsert) {
      await sql`
        insert into private.revenuecat_aliases (app_user_id, environment, customer_id)
        values (${appUserId}, ${environment}, ${customerId})
        on conflict (app_user_id, environment) do nothing
      `;
    }

    return { kind: "applied", customerId } as const;
  });
}
