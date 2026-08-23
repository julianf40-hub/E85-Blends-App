-- 85Blends 2.3.0 — Phase B1. Relax private.revenuecat_webhook_events' identity columns.
--
-- Phase A's ledger schema (20260823055527_revenuecat_entitlement_foundation.sql, NOT edited by
-- this migration) required app_user_id and environment to be NOT NULL, written against the
-- shape of a normal subscription-lifecycle event. RevenueCat's current webhook event catalog
-- also includes valid event shapes that don't carry those fields the same way:
--
--   - TRANSFER events carry transferred_from[]/transferred_to[] instead of a single
--     app_user_id, and may omit environment entirely.
--   - TEMPORARY_ENTITLEMENT_GRANT events intentionally carry a limited field set and may omit
--     original_app_user_id, aliases, and environment.
--
-- The webhook ledger's job is to faithfully record every authenticated, idempotency-checked
-- event RevenueCat actually sends — it must not corrupt or fabricate identity/environment values
-- just to satisfy a NOT NULL constraint that assumed every event looks like a normal purchase/
-- renewal/expiration. This migration only relaxes the LEDGER's own columns; it does not touch
-- private.revenuecat_customers or private.revenuecat_aliases, which remain environment-
-- partitioned and identity-anchored exactly as Phase A defined — see
-- supabase/functions/revenuecat-webhook for how those two tables are still written safely even
-- when a given event's app_user_id/environment is null at the ledger level.
--
-- The existing `environment IN ('SANDBOX', 'PRODUCTION')` CHECK constraint from Phase A is left
-- entirely as-is: Postgres CHECK constraints already permit NULL unless the constraint explicitly
-- forbids it (a NULL value makes the check expression UNKNOWN, not FALSE, so the row is accepted)
-- — no constraint rewrite is needed to allow NULL through the existing check.

alter table private.revenuecat_webhook_events
  alter column app_user_id drop not null;

alter table private.revenuecat_webhook_events
  alter column environment drop not null;

comment on column private.revenuecat_webhook_events.app_user_id is
  'The event''s primary app_user_id when the event shape provides one. NULL for event shapes '
  'that don''t carry a single app_user_id (e.g. TRANSFER, which carries transferred_from[]/'
  'transferred_to[] instead — see supabase/functions/revenuecat-webhook).';
comment on column private.revenuecat_webhook_events.environment is
  'SANDBOX or PRODUCTION when the event provides one. NULL for event shapes that omit it (e.g. '
  'some TRANSFER and TEMPORARY_ENTITLEMENT_GRANT events) — never fabricated to satisfy this '
  'column. A NULL environment here never grants or implies entitlement in either environment; '
  'see private.revenuecat_customers, which stays NOT NULL and environment-partitioned.';
