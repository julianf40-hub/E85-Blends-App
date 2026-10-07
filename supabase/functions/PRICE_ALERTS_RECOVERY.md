# Price Alerts deployed-source recovery

This directory records an exact source snapshot downloaded read-only from the deployed
Supabase Edge Functions in project `zefkbtscieokkdenvnkg` on 2026-10-04. The snapshot was
added for reproducibility only. It was not refactored, redeployed, or exercised against live
requests, and no database, cron, secret, or APNs configuration was changed.

## Deployed artifacts

| Function | Deployed version | Status | Updated (UTC) | JWT gate | Entrypoint in downloaded bundle | Supabase bundle SHA-256 |
|---|---:|---|---|---|---|---|
| `price-alerts-api` | 2 | ACTIVE | 2026-09-10T21:31:00Z | disabled | `index.ts` | `86d4d5327f1459074b760aa693668dcb833cc011a9bdf95ce69e02ba188d45a8` |
| `price-alerts-worker` | 1 | ACTIVE | 2026-09-18T00:16:10Z | enabled | `index.ts` | `06e1e2bae4e1d8993873c87c95f9e20af0616b34f101cef337829704b0aa285d` |

Each downloaded bundle contained only `index.ts` and `deno.json`. The files now live under
their conventional Supabase function directories without source changes. The deployment
metadata exposes no runtime version. Dependencies visible in source are pinned to
`postgres@3.4.5` for both functions and `jose@5.9.6` for the worker.

Runtime environment variable names referenced by the recovered source:

- API: `SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_ANON_KEY`, `SUPABASE_DB_URL`
- Worker: `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_DB_URL`, `APNS_TEAM_ID`,
  `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8`

Values were not read, printed, or committed.

## API contract

`price-alerts-api` accepts `POST` only and uses a JSON `action` discriminator. Its platform
JWT gate is disabled, but every request must present a configured client-safe Supabase key in
`apikey` or as a legacy Bearer value. Every action also uses a
`client_installation_id` UUID and a random `installation_secret` of at least 32 characters;
only the SHA-256 hash of that secret is stored.

| Action | Additional request fields | Success response |
|---|---|---|
| `bootstrap` | optional `contributor_id`, `app_version`; RevenueCat ID and environment must be supplied together | `status`, installation ID, current Pro state, RevenueCat-link state |
| `register_device` | `bundle_id`, `apns_environment` (`sandbox` or `production`), `device_token` | `status: registered`, device ID |
| `unregister_device` | `device_token` | `status: unregistered`, whether a row changed |
| `set_alert` | canonical community-station UUID, mode, optional threshold/minimum change/cooldown | `status: saved`, persisted alert |
| `delete_alert` | canonical community-station UUID | `status: deleted`, whether a row changed |
| `list_alerts` | none | alerts joined to station details and the latest report |
| `status` | none | Pro/link state plus active-device and enabled-alert counts |

The supported modes are `any_change`, `price_drop`, and `at_or_below`.
`at_or_below` requires `threshold_price` from 1 through 8; the other modes reject a
threshold. `minimum_change` defaults to 0.05 and is limited to 0.01 through 2.
`cooldown_minutes` defaults to 360 and is limited to 60 through 10080. Saving an alert is
Pro-gated and verifies that `station_id` exists in `public.community_stations`.
`any_change` requires an earlier station price and an absolute delta at least equal to the
minimum. `price_drop` requires an earlier price and a downward delta at least equal to the
minimum. `at_or_below` fires on a threshold crossing, the first qualifying observation, or a
large-enough change from the last notified price while still at/below the threshold. A current
cooldown suppresses an otherwise eligible result.

Stable error bodies use an `error` string. Notable status codes are 400 for request/validation
errors, 401 for API-key or installation-credential failures, 403 for `pro_required`, 404 for
`station_not_found`, 405 for non-POST requests, 503 for missing database configuration, and
500 for redacted internal failures.

## Worker and delivery contract

`price-alerts-worker` accepts `POST` only. The platform JWT gate is enabled and the function
also constant-time compares the Bearer value with `SUPABASE_SERVICE_ROLE_KEY`. Its optional
JSON body accepts `job_limit` (default 20) and `delivery_limit` (default 50), each clamped to
1 through 100.

The worker claims/prepares outbox jobs, then sends claimable delivery rows when all three APNs
signing variables are present. Without them it returns HTTP 200 with
`status: prepared_only` and does not claim deliveries. With them it returns per-run job and
delivery counters. APNs payload data is:

- `type: price_alert`
- canonical `station_id`
- numeric `observed_price`

The delivery UUID is the APNs idempotency ID, and notifications collapse by station UUID.
HTTP 410 and the APNs reasons `BadDeviceToken`, `DeviceTokenNotForTopic`, and
`Unregistered` invalidate a device. HTTP 429, HTTP 5xx, and the explicit transient APNs
reasons in source retry; other failures become terminal. Database retry delays are 1 minute,
5 minutes, 15 minutes, 1 hour, and then 4 hours, with a five-attempt worker limit.
The outbox is unique per price report, and the delivery ledger is unique per
`(alert_id, price_report_id, push_device_id)`. Claims use `FOR UPDATE SKIP LOCKED`, making
concurrent workers safe and repeated preparation idempotent.

## Database and migration map

- `20260910212848_price_alert_backend_foundation.sql`: installations, push devices, alerts,
  jobs, delivery ledger, RLS/grants, report-insert outbox trigger.
- `20260910213128_price_alert_performance_indexes.sql`: delivery-device and latest-station-price
  indexes.
- `20260917232104_price_alert_worker_primitives.sql`: three-mode decision engine and atomic
  job claims.
- `20260917232144_price_alert_prepare_deliveries.sql`,
  `20260918001235_fix_price_alert_prepare_deliveries.sql`, and
  `20260918001318_simplify_price_alert_delivery_candidates.sql`: successive delivery
  preparation definitions; the last file is authoritative.
- `20260918000854_price_alert_delivery_lifecycle.sql`: delivery/job state transitions,
  idempotency, retries, dead-letter state, and device invalidation.
- `20260918001525_price_alert_delivery_claim_payload.sql`: authoritative delivery claim shape,
  adding canonical station UUID and station name for APNs.
- `20260918001657_price_alert_job_processor_cron.sql`: database job processor and the active
  every-minute `85blends-price-alert-job-prepare` cron job.
- `20260823060735_revenuecat_entitlement_foundation.sql` and
  `20260823073614_revenuecat_webhook_ledger_nullable_identity.sql`: canonical RevenueCat
  customers/aliases and the idempotent webhook-event ledger used to keep entitlement state
  current.

The API resolves an installation's RevenueCat alias to
`private.revenuecat_customers`. Delivery preparation rechecks that linked customer has
`entitlement_id = 'pro'` and `pro_is_active = true` at send-preparation time. Price Alerts
does not read `private.revenuecat_webhook_events` directly; it depends on the webhook pipeline
to idempotently process that ledger and refresh `revenuecat_aliases` /
`revenuecat_customers`.

Live read-only catalog inspection on 2026-10-04 matched the repository migrations for the five
Price Alerts tables, constraints, indexes, triggers, RLS posture, current function definitions,
and the active cron row. The cron invokes `private.process_price_alert_jobs(50)`; it does not
invoke the Edge Function worker. No price-alert-related database cron entry that invokes
`price-alerts-worker` was present, so APNs delivery still requires an external authorized
worker invocation.

## Known client and operational prerequisites

- The API requires the canonical `community_stations.id` UUID. The SwiftData `FuelStation`
  model does not currently persist that identifier.
- Alert/list logic has no explicit product freshness cutoff. Public reports may be backdated up
  to seven days, so the client/backend must agree on which reports are notification-worthy.
- The existing notification-center delegate handles pump-detection notifications and ignores
  the recovered `price_alert` payload. A shared router is required before alert taps can work.
- The APNs payload supplies a station UUID but the app has no stable-ID station route/deep link.
- Database delivery claims recover stale `processing` rows after 15 minutes. Job claims do not
  have an equivalent stale-`processing` reclaim path, so an interrupted job processor can
  strand a job.

These are documented observations only. This recovery snapshot intentionally makes no behavior
change.

## Update (2026-10-05): invocation gap confirmed, fix prepared but not deployed *(HISTORICAL — superseded below)*

A read-only follow-up audit established that nothing in the project invokes `price-alerts-worker`
(no cron job, database function, trigger, webhook or platform scheduler, and zero calls in the Edge
Function logs since deployment), and that all Price Alerts tables are empty. The scheduler, stale-job
recovery and freshness guard that address this are prepared in
`migrations/20261005120000_price_alert_worker_scheduler_and_freshness.sql` and documented in
[`PRICE_ALERTS_SCHEDULER.md`](PRICE_ALERTS_SCHEDULER.md). They are **not applied or deployed**. The
worker source in this repository adds a dedicated scheduler-secret auth path
(`price-alerts-worker/auth.ts`) and `verify_jwt = false`, so until the worker is redeployed the
repository is intentionally ahead of the deployed v1 described above. Note also that the 4-hour retry
step in the delay table is unreachable with the worker's five-attempt cap (the retry horizon is about
81 minutes).

## Update (start of Phase 3B): activation completed

The scheduler, stale-job recovery and freshness guard that the 2026-10-05 update above describes as prepared
but **not applied or deployed** are now live. As reported by the project owner (not re-verified from this
repository): migrations `20261005120000_price_alert_worker_scheduler_and_freshness`,
`20261005233000_price_alert_cross_platform_delivery_safety` and
`20261006000000_price_alert_android_active_device_uniqueness` are applied; the worker cron job
`85blends-price-alerts-worker-invoke` is active on `* * * * *`; the APNs secrets and the scheduler credentials
are provisioned; and the invocation path was verified with a manual scheduler-path smoke test (pg_net HTTP 200,
worker Edge Function HTTP 200) followed by three consecutive scheduled HTTP 200 runs. The "invocation gap" is
therefore closed. See "Current production state" in [`PRICE_ALERTS_SCHEDULER.md`](PRICE_ALERTS_SCHEDULER.md).
