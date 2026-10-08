# Cash / Credit E85 prices and configurable Price Drop alerts (2.4.1, Phase 3C)

> **Status: code-ready, NOT deployed.** Nothing in this document has been run against production.
> No migration has been applied, no Edge Function deployed, no production row read or written, no secret,
> scheduler, cron job, APNs/FCM credential, CloudKit schema, entitlement or Xcode Cloud workflow changed. The two
> migrations and the two Edge Function changes are prepared and tested on a local scratch Postgres, under Node and under
> Deno only. Applying them is a separate, explicitly authorized step (see [Rollout](#10-rollout-proposed-nothing-has-been-run)).

Phase 3A built the Price Alerts client, Phase 3B its UI (`PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md`,
`PRICE_ALERTS_UI_2.4.1.md`). Phase 3C fixes a correctness problem in what an alert compares, and gives Price Drop
alerts a drop size.

## 1. The problem

A station can show one E85 price for paying cash and a different one for paying by card. Community reports carried
one bare number, and the alert engine judged a new report against "the previous report of the station", whatever it
was. So:

- Credit `$3.19` followed by Cash `$2.99` looked like a 20¢ **drop** — a false alert.
- Two 5¢ drops in a row never satisfied a 10¢ alert (each was judged against the previous row only).
- A late or back-dated report was judged as if it were current.
- Two reports prepared before the first was *sent* could both pass the cooldown.

The fix is on the **server**, where the notification is decided — a client-side filter alone could not stop a
notification that has already been sent.

## 2. Vocabulary (one spelling in the database, the API and the app)

| Value | Meaning | Where it can appear |
|---|---|---|
| `cash` | the price shown for paying cash | reports, alerts |
| `credit` | the price shown for paying by card | reports, alerts |
| `same_for_both` | ONE price the reporter saw for both; counts as the cash price **and** the credit price | reports only |
| `unknown` | legacy / unspecified: every report made before this change and every report from an app that does not send the field; for an alert, one made before payment types existed | reports, alerts |

Rules that hold everywhere:

- A cash report is **not** the same thing as a credit report. Neither is ever derived from the other (no ±10¢).
- `same_for_both` is never inferred from missing data; it is something a person chooses.
- Nothing assumes cash is cheaper (or dearer) than credit.
- `unknown` is **never** turned into cash or credit — not by the server, not by the app, not by a backfill.

## 3. Map of the change

| Layer | Files | What |
|---|---|---|
| Database | `supabase/migrations/20261007120000_community_price_payment_type.sql` (A) | `e85_price_reports.payment_type`, CHECK, column-scoped INSERT grant, one index |
| Database | `supabase/migrations/20261007130000_price_alert_payment_aware_evaluation.sql` (B) | alert payment type + baseline, comparable-stream helpers, pure decision function, replaced `prepare_price_alert_deliveries`, configure-time anchor trigger |
| API | `supabase/functions/price-alerts-api/{index,alert-input,values}.ts` | optional `payment_type` on `set_alert`; `payment_type` + comparable-price fields on reads |
| Worker | `supabase/functions/price-alerts-worker/{index,message}.ts` | notification copy names the price; additive `payment_type` payload key |
| iOS | `CommunityPaymentType`, `CommunityPriceBreakdown`, `CommunityPriceLinePresentation`, `CommunityReportInputCheck`, `CommunityPaymentTypeSelector`, `StationsView`, `FuelLogView`, `ProStationsMapView`, widget snapshot files | report with a payment type; show Cash / Credit lines |
| iOS | `PriceAlertsModels/API/Service/Form/StationModel/OverviewModel`, `PriceAlertsSensitivity`, `PriceAlertSheet`, `StationAlertsView` | alert payment type and 5¢ / 10¢ / 20¢ / Custom drop size |
| Tests | `supabase/tests/price_alert_payment_type*.{sql,sh}`, `supabase/functions/*/*.test.ts`, `EightyFiveBlendsTests/*` | see [Tests](#11-tests-and-what-they-can-and-cannot-prove) |

## 4. Database

### 4.1 Migration A — reports learn which price they are

- `public.e85_price_reports.payment_type text NOT NULL DEFAULT 'unknown'`. A constant default is catalog-only on
  PostgreSQL 11+: **no table rewrite, no per-row backfill**. Existing rows read as `unknown` and keep their id,
  price, `reported_at`, `created_at` and reporter exactly. (Proved by `price_alert_payment_type_migration.test.sh`,
  which loads rows before the migration and compares them after.)
- `CHECK (payment_type in ('cash','credit','same_for_both','unknown'))`, added `NOT VALID` then `VALIDATE`d so
  inserts keep flowing during the scan.
- `GRANT INSERT (payment_type) ... TO anon, authenticated` — additive. The clients' INSERT grant was already
  **column-scoped**, so without this a new app naming the column is refused with `permission denied for column`.
  An old app that omits the column needs no privilege for it (it takes the default).
- One index, `(station_id, payment_type, reported_at desc, created_at desc)`, for "latest report of a payment type
  at a station". The existing `(station_id, reported_at desc, created_at desc)` index stays.
- **Not changed:** the INSERT RLS policy, the SELECT policy/grant (table-wide, so the new column is readable and
  `Prefer: return=representation` keeps working), the immutability of reports (still no UPDATE/DELETE grant), the
  rate-limit trigger, the alert-enqueue trigger, any function.

### 4.2 Migration B — the payment-aware engine

Requires A (it refuses to run without it) and the Phase 3 worker/claim migrations.

- `private.price_alerts` gains `payment_type` (`cash|credit|unknown`, default `unknown`), `baseline_price`
  `numeric(6,3)` and `baseline_at`. `private.price_alert_deliveries` gains a nullable `payment_type` (the alert's
  method when the delivery was decided). All additive; constraints are added `NOT VALID` then validated.
- Helpers (`private.*`, pinned `search_path`, no client grants): `comparable_report_types`,
  `payment_type_is_comparable`, `latest_comparable_price_report`, `has_newer_comparable_price_report`,
  `price_alert_reference_horizon` (7 days).
- `private.evaluate_price_alert_v2(...)` — a **pure, immutable** decision function (unit-testable by direct call).
  The old `private.evaluate_price_alert` stays in place, unchanged and no longer called.
- `private.prepare_price_alert_deliveries(uuid)` — replaced; same signature and ACL (postgres + service_role).
  Alerts are processed `ORDER BY id FOR UPDATE`, so concurrent preparers serialize per alert.
- Trigger `price_alerts_anchor_baseline` (before insert, or update of `alert_mode`/`payment_type`): anchors the
  reference to the latest comparable report **within 7 days**, else leaves it NULL (nothing invented), and clears
  `last_notified_price` when the method or mode changes (a cash notification price is never compared to a credit one).
- A one-time, idempotent fill gives each legacy alert the reference the old engine would have used for the next
  report (the latest `unknown` report), so the first report after deployment behaves as it did. It runs only on the
  first application (a session setting decided before the columns exist), so re-applying never anchors an alert that
  is legitimately waiting for its first report.
- **Not changed:** `claim_price_alert_deliveries_v2` and its v1 wrapper. Their exact return shape is pinned by the
  existing `price_alert_cross_platform_delivery_safety.test.sql` and the deployed worker depends on it, so the worker
  reads `deliveries.payment_type` with one extra lookup by delivery id instead (fail-soft).

### 4.3 RLS / privilege audit (local, from the migration chain)

| Object | Before | After |
|---|---|---|
| `e85_price_reports` SELECT | table-wide to `anon, authenticated` | unchanged (new column readable) |
| `e85_price_reports` INSERT | column-scoped: `station_id, price, reported_at, anonymous_reporter_id, app_version, note` | + `payment_type` only |
| `e85_price_reports` UPDATE/DELETE | none | none |
| INSERT RLS policy | price 1–8, reporter not blank, `reported_at` window | unchanged |
| `private.price_alerts`, `private.price_alert_deliveries` | no client grants | no client grants (tests assert this) |
| new `private` functions | n/a | no `PUBLIC`/`anon`/`authenticated` EXECUTE |

## 5. How an alert decides

### 5.1 Comparable streams

| Alert watches | Judged only on reports that are |
|---|---|
| `cash` | `cash`, `same_for_both` |
| `credit` | `credit`, `same_for_both` |
| `unknown` (legacy) | `unknown` — `same_for_both` is **not** mixed in |

Anything else, including a value this code has never seen, is not comparable (**fail closed**).

### 5.2 Decision order for a report `R` at station `S`, for each enabled Pro alert of `S`

1. `R` not comparable to the alert → skipped (`payment_type_mismatch`). **No state change**, so a type switch can
   never look like a drop.
2. A newer comparable report exists → skipped (`superseded`): late, back-dated and backlogged reports change nothing.
3. `R` older than the 2-hour send-freshness window can never notify: a fall it would have qualified for is recorded as
   `stale_report` and the reference moves to it.
4. By mode, with reference `B` (a reference that no comparable report has refreshed for 7 days is discarded and
   re-established **without** notifying. Every comparable report the engine decides moves the reference's timestamp
   to that report, so while reports keep arriving `B` is a running high-water mark since the last notification):
   - **`price_drop`**: no `B` → established from `R` (no notification). `B − P ≥ minimum_change` → notify and set
     `B := P` (**rearm at the notified price**). A smaller drop keeps `B` (so 5¢ + 5¢ reaches a 10¢ alert). A rise or
     equal price moves `B` up to it (so a later fall from the new high counts).
   - **`at_or_below`**: crossing / first-met / changed-by-`minimum_change` rules as before, but over the comparable
     stream only. The threshold is a dollar amount for the alert's own price type.
   - **`any_change`**: unchanged semantics over the comparable stream (not offered in the UI).
5. **Cooldown** (default 360 min) compares against `last_notified_at`, now stamped when a notification is
   **reserved** (a pending delivery is queued), not only when it is later sent — closing the two-prepared-reports race.
   A qualifying drop that the cooldown suppresses **keeps the alert armed**: it fires on the next qualifying
   comparable report after the cooldown. Nothing is queued "for later".
6. Idempotence: if a delivery already exists for `(alert, R)`, the alert is skipped, so replays converge.

### 5.3 Worked examples (all are executed by `price_alert_payment_type.test.sql`)

Credit price-drop alert, 10¢, baseline Credit `3.19`, existing Cash `2.99`:

| Next report | Result | Why |
|---|---|---|
| Cash `2.99` | no alert | not comparable (`payment_type_mismatch`) |
| Credit `3.14` | no alert | 5¢ < 10¢; baseline stays `3.19` |
| Credit `3.09` | **alert** | `3.19 − 3.09 = 10¢`; baseline becomes `3.09` (subject to freshness, cooldown, dedup, Pro) |
| Credit `3.14` then Credit `3.09` | **alert** on the second | cumulative: baseline was kept at `3.19` |
| `same_for_both` `3.09` | **alert** | counts as a credit price |
| unknown `3.00` | no alert | a legacy report never reaches a credit alert |

`at_or_below` Credit `2.89`:

| Report | Result |
|---|---|
| Cash `2.79` | no alert (a cash price never meets a credit target) |
| Credit `2.89` | may alert (target met / crossed) |
| `same_for_both` `2.89` | may alert for either a cash or a credit alert |

### 5.4 Legacy alerts

A legacy alert (`payment_type = 'unknown'`) is **not** converted and no payment type is invented for it. It keeps
working on the reports it always saw — unclassified ones — and never fires from a cash/credit/same-for-both report.
A person moves it to Cash or Credit by editing it in the updated app (the form shows "Payment type not set" and asks).
See [Open product questions](#12-open-product-questions) for the consequence this has over time.

Legacy alerts are evaluated by the same state machine over the unclassified stream, so three things differ from the
old engine, all in the direction of fewer wrong or duplicate notifications: sub-threshold drops now add up (3¢ then 3¢
satisfies a 5¢ alert), a late or back-dated report no longer notifies as if it were current, and two reports prepared
before the first was sent cannot both pass the cooldown. A fall from the previous price that qualified before still
qualifies, with two deliberate exceptions: a reference that no unclassified report has refreshed for 7 days is
re-established instead of compared against (the old engine would have compared with a price that old), and a report
that is no longer the newest unclassified report when it is decided is skipped. The **wording** of a legacy alert's
notification is not changed at all (see §7).

### 5.5 Deliveries already queued

Rows already in `price_alert_deliveries` (pending, processing or sent) are **not** touched, re-evaluated or re-sent by
either migration. New behavior applies to reports prepared after migration B.

## 6. API (`price-alerts-api`) — written, not deployed

- `set_alert`: optional `payment_type` of `"cash"` or `"credit"`. Anything else — `"unknown"`, `"same_for_both"`,
  a different case, a non-string — is `400 invalid_payment_type`. **Absent (or `null`) means "not specified"**: an
  existing alert keeps its current method (`coalesce`), a new alert is stored `unknown`. `minimum_change` keeps its
  contract (0.01–2.00, default `0.05` when omitted — the **legacy** server default is unchanged; the app sends its
  10¢ new-alert default explicitly). Editing one field never resets another: the app sends the alert's full state.
- Responses (`set_alert` alert object, `list_alerts` rows) add `payment_type`. `list_alerts` also adds
  `latest_comparable_price`, `latest_comparable_reported_at`, `latest_comparable_payment_type` — the newest report the
  alert is actually judged on. `latest_price` / `latest_reported_at` keep their original meaning (newest report of any
  kind), so older clients are unaffected.
- Authentication, the publishable-key flow and the Pro gate are unchanged; no service-role credential reaches a client.
- Pure input rules live in `alert-input.ts` (Node-testable, `alert-input.test.ts`).

## 7. Notifications (`price-alerts-worker`) — written, not deployed

Copy comes from the pure `message.ts` and is shared by the APNs and FCM senders:

| Alert | Title | Body |
|---|---|---|
| Price Drop, Credit | `E85 price dropped!` | `Credit price is now $3.09 at {Station}.` |
| Price Drop, Cash | `E85 price dropped!` | `Cash price is now $2.99 at {Station}.` |
| At or Below, Cash | `Your E85 target was reached.` | `Cash price is now $2.79 at {Station}.` |
| At or Below, Credit | `Your E85 target was reached.` | `Credit price is now $2.89 at {Station}.` |
| Legacy (`unknown`) | unchanged: `E85 price dropped` / `E85 price alert` | unchanged: `{Station} dropped to $3.09/gal.` / `{Station} is now $2.79/gal.` — character for character what the worker sent before |

A legacy alert's wording is the previous implementation kept verbatim (`legacyMessageFor` in `message.ts`); `message.test.ts`
compares it with a verbatim copy of the old function across 8 reasons × 12 prices × 7 station names × 9 non-method
values (6,048 combinations), so "payloads and notifications for existing alerts do not change" is a tested claim, not a hope.

The copy never says "verified", "confirmed" or "official" (these are community reports) and never mentions a baseline
or reason the person did not see.

**Payload compatibility.** The APNs custom payload and the FCM `data` map gain one **additive, optional** key,
`payment_type` (`"cash"` or `"credit"`), present only for a Cash/Credit alert; for a legacy alert the payload is
byte-for-byte what it was. `type`, `station_id` and `observed_price` are untouched, so the iOS deep link
(`station_id`) and any receiver that ignores unknown keys — the shipped iOS app and Android — are unaffected
(`AppNotificationPayloadTests` pins this for iOS). The worker's lookup of the new column is fail-soft: if it errors,
the notification is sent with the plain (legacy) wording and no `payment_type`, and a `payment_type lookup failed`
warning (an error code or name only — never the query or its parameters) is logged so the degradation is visible.

## 8. iOS

### 8.1 Reporting a price

The **existing** report UI is extended — no new screen. In the Stations report sheet (both layouts: full, and the
compact post-navigation reporter) and in the Fuel Log "Report this E85 price?" sheet:

```
Payment Type
[ Cash ] [ Credit ] [ Same for Both ]
Select the price shown at the pump or on the sign.
```

- **Nothing is preselected and the choice is not remembered** between reports; a new report cannot be sent until one is
  chosen ("Choose Cash, Credit, or Same for Both."). No invalid default exists, and a price is never silently labelled.
- Station selection, price entry and validation, the reporter identity, the success/failure feedback, haptics and the
  map/price conventions are unchanged. The Stations sheet validates the price **and** the choice together
  (`CommunityReportInputCheck`), before the local save, so nothing is saved or sent half-filled. A station that cannot
  be reported to the community (too little location information) is saved locally exactly as before and is not asked.
- The compact layout is now scrollable (the selector makes it taller; the price field still auto-focuses).
- Labels scale with Dynamic Type, and the option grid's minimum column width scales with it too (`@ScaledMetric`), so at
  large text sizes the buttons stack into fewer columns instead of breaking a label ("Credit" mid-word). Selection is
  shown by a check mark, a thicker border and the selected accessibility trait (not colour alone), each button has a
  VoiceOver hint, and the "Choose Cash, Credit, or Same for Both." message is announced to VoiceOver when it appears.
- The Fuel Log report prompt opens at full height: its Payment Type choice sits under the fill-up summary and would
  otherwise start below the fold of a half-height sheet, so a tap on "Report Price" with nothing chosen would look like
  a no-op.
- Known limitation: choosing a payment type clears keyboard focus (the sheet's tap-to-dismiss-keyboard gesture also sees
  the button tap), so in the compact post-navigation reporter, where the price field is focused on open, choosing the
  type first means tapping the price field again.
- **Two prices on one sign = two reports.** The smallest backward-compatible design: a report is one price with one
  payment type, exactly the existing row shape plus one column. A dual-price operation would need a new API shape
  and partial-failure handling for a case "Same for Both" and a second report already cover.
- A new report is sent with `payment_type` only when the person chose one; an older call that names none sends the
  exact bytes an older app sends. The service does **not** retry a rejected report without the field — the person's
  choice is never silently dropped.

### 8.2 Showing prices (and the policy where a feature cannot choose a method)

A station's community prices are read per method from its newest 20 reports (`CommunityPriceBreakdown`):
Cash ← newest `cash`/`same_for_both`; Credit ← newest `credit`/`same_for_both`; one `same_for_both` report that is
newest for both is a single "Cash & Credit" line; an `unknown` report is its own slot and is shown (labelled
"Payment type not specified") only when it is **newer than every typed price**. **Each line keeps its own report time
and staleness** — a stale Cash price is never shown as the current Credit price, and a missing method is never filled
in from the other.

| Surface | Behavior |
|---|---|
| Saved-station card | no saved price → Cash and Credit lines, each with its own age (stale in yellow); saved price primary → it stays primary and the community lines support it |
| Nearby (live) card | "Community E85" with one line per method and a per-line stale note |
| Classic embedded-map card (selected saved station) | typed reports: one "Community E85 {Cash/Credit} $x" line per method (or one "Community {method} $x · age" supporting line each under a saved price), each with its own age, stale in yellow; legacy-only: unchanged |
| Pro map card and list row | headline is the first line (Cash, else Credit) labelled `Community · Cash`; other methods are supporting lines; the pin's VoiceOver label speaks every method when community is the headline (with a saved price as the headline, the community supporting lines are shown but — as before this change — not spoken in the pin label) |
| Post-navigation reporter | "Current community prices" by method (read-only, never copied into the field) |
| Nearby E85 widget + station screen | one slot: the **most recent typed** price (tie → Credit), labelled in the status line ("Cash · Reported today"); an unclassified price never takes the slot. The snapshot gains an optional `paymentType` string (old snapshots decode; an older widget ignores it) |
| Station with only unclassified reports | **unchanged**: the single price, claiming no method |
| Trip / route planning, calculators, At the Pump | use the station's own **saved** price (`lastKnownE85Price`) and never read community prices, so they are method-agnostic by design. The saved price has no payment type (SwiftData/CloudKit schema deliberately untouched) |
| Community history | the app shows only the latest per method; there is no history screen |

A method whose newest report is older than the station's 20 newest reports has no line (an old price is never promoted to a
current one), which reads as "this method has not been reported recently", not as "this station only takes the other method".
A Cash or Credit line that comes from a `same_for_both` report is labelled by the method it fills; when one such report is the
newest for both, it is one "Cash & Credit" line. On the smallest widget sizes the longer labelled status ("Cash/Credit ·
Check price · 14d ago") can clip its age; it is a Pro-only line and only appears for typed reports.

### 8.3 Price Alerts UI

- **Which price:** Cash / Credit. No default; a new alert cannot be saved until one is chosen. A legacy alert opens
  with nothing chosen ("Payment type not set") and a note explaining why; editing it asks for a choice. The central list
  shows "Credit price · 10¢ drop" or "Payment type not set" per alert, with the alert's own latest comparable price
  ("Latest Credit price $3.09"; "No Cash price reported yet" — it does **not** borrow the unfiltered latest price,
  which may be the other method's).
- **Drop size (Price Drop):** 5¢, **10¢ (Recommended)**, 20¢, Custom (0.01–2.00 dollars, up to three decimals, held as
  integer thousandths). A **new** alert starts at 10¢; an existing alert keeps its stored value and the form shows it as
  the matching choice — nothing migrates 5¢ to 10¢, and the backend's legacy 0.05 default is unchanged. No percentage
  presets. *At or Below* has no drop size on screen: a new one stores the new-alert default, an existing one keeps its own.
- **At or Below** keeps its dollar target ($1.000–$8.000, three decimals, Pro gate), now for the chosen price type.
- Editing one setting preserves the others (the app sends the alert's full state; `updateAlert` carries the existing
  payment type and drop size forward). Turning an alert off is a delete, as before; a Pro lapse never deletes anything.
- The note under the form states the limits from the alert's own values and that alerts "follow community reports, so
  they aren't instant".

### 8.4 New iOS against an old backend (partial deployment)

| Action | Backend not yet migrated | Result |
|---|---|---|
| Read prices | the select with `payment_type` returns 400 | the app reads again **without** the column (only on a 400): prices stay visible, every report reads as unclassified, legacy presentation |
| Report a price | an insert naming `payment_type` is rejected (unknown column) | the report fails with the existing "could not be submitted" message; **not** retried without the field |
| Save an alert | old API ignores the extra key | the alert saves as legacy and the list shows "Payment type not set" |

So: **do not distribute a Phase 3C iOS build to people who will report prices or set alerts until migrations A and B and
the API are deployed** (see the order below).

## 9. Compatibility matrix

| Client | Backend | Behavior |
|---|---|---|
| Released iOS / Android (no payment type) | new | Reports accepted, stored `unknown`. Alerts keep their legacy behavior (legacy stream). Notifications unchanged in wording for legacy alerts |
| New iOS | new | Everything above |
| New iOS | old (migrations not applied) | see 8.4 |
| Released clients | old | unchanged |

## 10. Rollout (proposed; nothing has been run)

Every step is transactional or idempotent. **Do not start any step without explicit authorization**, and do not
treat a green build as authorization.

**Heads-up:** pushing this branch starts the Xcode Cloud **85Blends Internal** workflow (it watches `claude/*`), which builds
this app and uploads an Internal TestFlight build. Do not install that build on a device that talks to production before
migrations A and B and the API are deployed — a report sent with a payment type is rejected by the current backend (8.4).

0. **Read-only checks first** (SQL editor, no writes): the current migration list matches the chain this phase replayed;
   `\d public.e85_price_reports` shows the column-scoped INSERT grant; the state of the cron jobs
   `85blends-price-alert-job-prepare` and `85blends-price-alerts-worker-invoke`. The project owner reported both **active**
   (`PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md`); this phase never touched production and did not re-verify it, so confirm
   — and treat migration B as acting on **live** alert traffic from its first minute. Also count the rows in
   `private.price_alert_deliveries` with `status in ('pending','processing')` (they will be left alone).
1. **Migration A.** Effect: reports can carry a payment type; nothing else changes (the engine still compares as before).
   Verify: existing rows read `unknown`; `anon` can insert with and without the column; `anon` cannot update/delete.
2. **Migration B.** Effect is **immediate**: `prepare_price_alert_deliveries` is called every minute by the job-prepare
   cron and by the worker, so the new engine decides the very next report. Existing alerts become legacy (`unknown`) and
   keep working on unclassified reports. Verify: alerts keep their rows; `baseline_price` is filled for legacy alerts
   that had a prior report; no delivery was created by the migration itself.
3. **Deploy `price-alerts-api`.** Verify `set_alert` with and without `payment_type`, `list_alerts` fields, `400
   invalid_payment_type`.
4. **Deploy `price-alerts-worker`.** The invoker cron is reported **active** (step 0), so the deployed worker is live within
   a minute: there is no pre-activation dry run in production, and none is attempted here (no cron change, no APNs/FCM
   send, no test reports or alerts). Deploying it before or after migration B is safe: for a legacy alert its wording is
   byte-for-byte the old one, and the extra `payment_type` lookup is fail-soft (it logs `payment_type lookup failed` and
   sends the legacy wording if the column is not there yet). Verify from the logs afterwards: no `payment_type lookup
   failed` warnings, and — when one occurs naturally — a Cash/Credit notification with the new wording and the optional
   `payment_type` key. If a dry run before activation is wanted, pausing the invoker cron first is the owner's decision.
5. **iOS Internal build** (`EightyFiveBlends Internal`, Xcode Cloud "85Blends Internal"), then production only on the
   owner's explicit "prepare production release".
6. **Android** update (below).

**Stopping part-way is safe, in this order**: A alone changes nothing visible; A + B without the API means every alert
is legacy and still works; A + B + API without the worker sends the old wording with no `payment_type`; the worker
read of the new column is fail-soft. **Two orders are NOT safe and must not be used:** the new API *before* migration B
(its SQL names B's columns and functions, so `set_alert` and `list_alerts` would fail) and the iOS build *before* the
backend (8.4). Migration B before migration A refuses to run.

**Rollback / fail-closed.**
- iOS: revert the release (the new fields are additive; older apps keep working).
- Worker: redeploy the previous version (it ignores the extra column; a Cash/Credit alert then gets the old wording).
- API: redeploy the previous version (the extra response fields were additive; the previous API cannot set a payment type,
  so alerts saved meanwhile keep the method they have).
- Engine: **do not re-apply the previous `prepare_price_alert_deliveries` (`20260918001318`) once cash / credit /
  same-for-both reports exist.** That engine compares a report with the previous report of any method — the false alert
  this phase removes — so it is a rollback to the bug, not a fail-closed state. Pause instead, and fix forward by
  re-applying migration B:
  ```sql
  create or replace function private.prepare_price_alert_deliveries(p_price_report_id uuid)
  returns table(pending_count integer, skipped_count integer)
  language sql
  security definer
  set search_path = ''
  as $$ select 0, 0 $$;
  ```
  It decides and queues nothing (a report that arrives meanwhile is consumed without a decision), and `create or replace`
  keeps the function's ACL. Scenario D19 runs exactly this statement, checks that nothing is queued and no alert state
  moves, and that re-applying migration B restores the real engine. Pausing the two cron jobs instead keeps the job queue,
  but a job older than the 2-hour send window can no longer notify when it is finally processed; either way nothing false is
  sent. Only while NO typed report exists yet is the previous engine a safe fallback.
- Reports: before anything depends on it, migration A's header lists the exact drops. After clients send `payment_type`,
  drop the column last.
- Fail-closed behavior built in: an unrecognised payment value is not comparable (no notification), a corrupted alert
  payment type is rejected by CHECK, a lookup failure in the worker sends the plain copy, and a report with an unrecognised
  payment value is skipped (no notification, no state change; scenario D13).

## 11. Tests and what they can and cannot prove

| Area | Where | Run with |
|---|---|---|
| SQL decision matrix — scenarios R1 (reports/grants/RLS), C1 (comparability), E1 (the pure function), D1–D18 (isolation, cumulative drops, type switching, legacy, out-of-order, repeats, cooldown, rearm, baseline, Pro gate, devices, idempotence, fail-closed, anchor, delivery record, the exact `set_alert` upsert incl. an older client and an edit that names no method, `list_alerts` returning both the legacy latest and the comparable latest, and a `same_for_both` report driving a Price Drop alert of either method while never reaching a legacy one), G1 (ACLs, index, re-apply) | `supabase/tests/price_alert_payment_type.test.sql` | local Postgres 16 scratch DB, `supabase/tests/support/replay_migrations.sh` + `local_supabase_shims.sql` |
| Migration preservation (rows unchanged, no rewrite, idempotent re-apply, legacy fill, old-client insert, permission matrix) | `price_alert_payment_type_migration.test.sh` | same |
| Concurrency (two sessions, row lock, cooldown reservation race) | `price_alert_payment_type_concurrency.test.sh` | same |
| Edge Function pure modules (input rules, copy, payload) | `supabase/functions/**/*.test.ts` | `node --test` (Node 22 type-stripping) or `deno test`; the entry points are also pinned by source-text assertions |
| The Edge Functions themselves, end to end, under Deno against a local Postgres: the API's `set_alert` / `list_alerts` / `delete_alert` over HTTP (A1–A9: an older client, the 2.4.1 app, edits that keep the method, `invalid_payment_type`, bounds, comparable-latest fields, re-anchoring, non-Pro, delete), and the worker preparing, claiming and "sending" five notifications with the push providers stubbed (3 APNs, 2 FCM: copy, additive `payment_type`, legacy payload unchanged, the delivery's recorded method) | `price_alert_api_payment_type.test.sh`, `price_alert_worker_message.test.sh` (+ `support/worker_with_recorded_fetch.ts`) | Deno 2.x, jq, curl, openssl, psql and a replayed scratch database; nothing leaves the machine (the wrapper refuses any URL but the providers') |
| Swift (models, form, presets, service, wire contract, report rules, breakdown, presenter, widget model, notification payload) | `EightyFiveBlendsTests/*` | Xcode (`xcodebuild test`) |

**What Linux could and could not prove.** The two Edge Function entry points pass `deno check` under the functions' own
strict config (`strict`, `noUncheckedIndexedAccess`) and were run under Deno 2.9 against a migrated scratch Postgres (above).
The Swift app sources that do not import SwiftUI/SwiftData/MapKit and the
Swift Testing files were compiled and run in a throwaway SwiftPM harness (Swift 5 language mode with the project's
MainActor default isolation, and again in Swift 6 mode), including the real `CommunityPriceService` over a stubbed
`URLSession`. SwiftUI views were only parsed and, for the alert sheet and the selector, type-checked against a
structural stand-in — **that is not Xcode**. `StationsView`, `FuelLogView` and the widget views compile only in Xcode.
The authoritative iOS gate is the Xcode Cloud workflow **85Blends Internal**: the branch is not validated until
**Test – iOS reports SUCCESS** on the final commit.

## 12. Open product questions

These are flagged, not silently decided beyond the conservative default noted.

1. **Legacy alerts go quiet over time.** A legacy alert sees only unclassified reports. Once most reporters use the
   updated iOS app (typed reports), unclassified reports become rare, so legacy alerts — every Android alert, and every
   iOS alert whose owner has not edited it — will fire less and less. This is the price of never comparing across
   methods. Options: ship the Android update promptly; have the app nudge legacy alerts to choose a price; or (a
   product decision with a cost) let a legacy alert accept typed reports. Not done.
2. **Reference horizon of 7 days** (the maximum back-dating window): a reference that no comparable report has refreshed
   for 7 days is discarded and re-established without notifying. While reports keep arriving it behaves as a high-water mark
   since the last notification, so a fall of at least the drop size from that high notifies however long ago the high was.
3. **A cooldown-suppressed qualifying drop is not queued**; it fires on the next qualifying report.
4. **One alert per station per installation** remains — a person cannot watch both Cash and Credit at one station.
5. **A mistaken high report followed by the correct one still looks like a drop.** Community data is unverified; the
   notification copy does not claim otherwise.
6. **Trip planning uses the saved price** (method-agnostic). Whether planning should prefer a Credit or Cash community
   price when no saved price exists is a product choice; it does not read community prices today.
7. **Which price the widget shows** when both exist (newest typed, tie → Credit) is a policy, easy to change.
8. **A reserved cooldown is not released if its delivery never goes out.** The cooldown and `last_notified_price` are
   stamped when a delivery is queued (that is what closes the two-prepared-reports race). If the queued delivery is then
   skipped at send time (the report is older than the 2-hour window, or the device was invalidated) or ends `dead`, the
   alert stays quiet for up to its cooldown (6 hours) with nothing sent. The old engine stamped only after a send. With a
   healthy worker the window between queueing and sending is about a minute; releasing the stamp on a terminal unsent
   delivery would need a change to the claim path, which this phase deliberately leaves untouched.
9. **`superseded` is decided on the report's `reported_at`, which the client supplies** (the INSERT policy allows up to
   10 minutes in the future and 7 days back). A future-dated report makes honest reports dated before it `superseded` for
   at most those 10 minutes. Reports already needed a valid price and passed the rate limiter, and a forged drop could always
   have notified, so this adds no new abuse class, but it is a way to briefly mute an alert.
10. **A payment method with no report among a station's 20 newest has no line** in the app, which reads as "not reported
    recently" rather than "not accepted here".

## 13. Android follow-up (no Android code lives in this repository)

Everything is additive and optional, so the shipped Android app keeps working unchanged. To adopt it:
send optional `payment_type` (`cash`/`credit`) on `set_alert`; read `payment_type` and the `latest_comparable_*` fields
from `list_alerts` (fall back to `latest_price` when absent); read the optional `payment_type` FCM data key; add the
same Payment Type choice to price reports (`payment_type` on insert, omitted when unchosen) and the 5¢/10¢/20¢/Custom
drop-size choice; treat an alert without a payment type as "Payment type not set". Until then Android alerts are legacy
alerts (see question 1).
