// 85Blends 2.3.0 — Phase B1. Pure canonical-customer / alias resolution decision logic.
//
// Takes already-fetched rows (plain objects — the caller in database.ts runs the actual SELECT
// against private.revenuecat_aliases) and decides what the transaction should do next. No
// Postgres client, no Deno-specific APIs — fully unit-testable under Node, including the
// zero/one/many-matched-customer cases from Phase 16 and the alias-upsert conflict cases from
// Phase 17 — see customer-resolution.test.ts.

export interface MatchedAliasRow {
  appUserId: string;
  customerId: string;
}

export type CustomerResolution =
  | { kind: "reuse"; customerId: string }
  | { kind: "create"; anchorAppUserId: string }
  /** Two or more of the event's alias IDs already map to DIFFERENT canonical customers — never
   *  silently merge them (Phase 16). The caller must roll back and mark the ledger row `error`. */
  | { kind: "conflict"; matchedCustomerIds: string[] };

/**
 * `matchedAliasRows` must already be scoped to the event's environment and to only the IDs in
 * `aliasSet` (i.e. `SELECT app_user_id, customer_id FROM private.revenuecat_aliases WHERE
 * environment = $1 AND app_user_id = ANY($2)` — see database.ts). `preferredAnchor` is the ID to
 * use as `original_app_user_id` if a brand-new customer row must be created — callers should pass
 * the event's own `original_app_user_id` when available, falling back to any other ID in the set.
 */
export function resolveCanonicalCustomer(
  matchedAliasRows: MatchedAliasRow[],
  preferredAnchor: string,
): CustomerResolution {
  const distinctCustomerIds = Array.from(new Set(matchedAliasRows.map((row) => row.customerId)));

  if (distinctCustomerIds.length === 0) {
    return { kind: "create", anchorAppUserId: preferredAnchor };
  }
  if (distinctCustomerIds.length === 1) {
    return { kind: "reuse", customerId: distinctCustomerIds[0] };
  }
  return { kind: "conflict", matchedCustomerIds: distinctCustomerIds };
}

export type AliasUpsertPlan =
  | { kind: "plan"; toInsert: string[] }
  /** One of the aliases in the set is already mapped to a DIFFERENT customer than the one just
   *  resolved — never silently steal it (Phase 17). */
  | { kind: "conflict"; conflictingAppUserIds: string[] };

/**
 * Decides which of `aliasSet` still need an INSERT into private.revenuecat_aliases for the
 * resolved `customerId`, given the alias rows already known to exist for those exact IDs
 * (`existingAliasRows` — same query shape as `matchedAliasRows` above, but callers may pass a
 * superset; only rows whose app_user_id is in `aliasSet` are considered).
 */
export function planAliasUpserts(
  aliasSet: string[],
  customerId: string,
  existingAliasRows: MatchedAliasRow[],
): AliasUpsertPlan {
  const existingByAppUserId = new Map(existingAliasRows.map((row) => [row.appUserId, row.customerId]));

  const toInsert: string[] = [];
  const conflicting: string[] = [];

  for (const appUserId of aliasSet) {
    const existingCustomerId = existingByAppUserId.get(appUserId);
    if (existingCustomerId === undefined) {
      toInsert.push(appUserId);
    } else if (existingCustomerId !== customerId) {
      conflicting.push(appUserId);
    }
    // else: already correctly mapped — no-op, not added to either list.
  }

  if (conflicting.length > 0) {
    return { kind: "conflict", conflictingAppUserIds: conflicting };
  }
  return { kind: "plan", toInsert };
}
