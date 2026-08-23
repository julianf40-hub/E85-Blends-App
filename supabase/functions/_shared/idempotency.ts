// 85Blends 2.3.0 — Phase B1. Idempotent webhook-event-claim decision logic.
//
// Pure — operates on a plain, already-fetched ledger row (or `null`) and the incoming payload
// hash; the actual `SELECT`/`INSERT` against private.revenuecat_webhook_events lives in
// database.ts. Fully unit-testable under Node — see idempotency.test.ts.
//
// Design note: because Phase B1 always re-fetches RevenueCat's CURRENT canonical subscription
// state rather than applying the webhook event as a delta, out-of-order delivery is naturally
// self-correcting — whichever event arrives, the write reflects RevenueCat's state as of the
// fetch, not the event's own position in time. So the only thing this decision needs to prevent
// is REDUNDANT work on an already-fully-processed duplicate, and catch a same-event-id-different-
// payload anomaly (Phase 10).

export interface ExistingLedgerRow {
  payloadHash: string;
  processingStatus: string;
}

export type IdempotencyDecision =
  | { kind: "new" }
  /** Already fully processed with the identical payload — short-circuit, do not redo any work. */
  | { kind: "duplicate_processed" }
  /** Same payload seen before, but the prior attempt never reached "processed" — safe to retry. */
  | { kind: "duplicate_retryable" }
  /** Same event_id, but the recorded payload_hash differs — never seen for a genuine RevenueCat
   *  retry (Phase 10 note: RevenueCat retries reuse event.id AND event_timestamp_ms, so the body
   *  — and therefore its hash — should be stable across retries of the same delivery). Treated as
   *  suspicious; never mutates entitlement state. Carries the existing row's `processingStatus` so
   *  the caller can decide whether it's safe to mark the row `error` — see
   *  database.ts's markLedgerHashMismatch and the "hash-mismatch ledger hardening" note below. */
  | { kind: "hash_mismatch"; previousStatus: string };

export function decideIdempotency(
  existingRow: ExistingLedgerRow | null,
  incomingPayloadHash: string,
): IdempotencyDecision {
  if (!existingRow) return { kind: "new" };

  if (existingRow.payloadHash !== incomingPayloadHash) {
    // A mismatch must never regress a row that already reached "processed" — that state is
    // durable and reflects a successful, complete canonical refresh. The mismatched delivery is
    // reported to the caller either way (so it can log/return 409), but only a NOT-YET-processed
    // row may actually be marked `error` — see database.ts's markLedgerHashMismatch, which checks
    // `previousStatus` before writing anything.
    return { kind: "hash_mismatch", previousStatus: existingRow.processingStatus };
  }

  return existingRow.processingStatus === "processed"
    ? { kind: "duplicate_processed" }
    : { kind: "duplicate_retryable" };
}
