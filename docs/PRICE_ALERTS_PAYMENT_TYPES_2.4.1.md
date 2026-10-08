# Cash / Credit E85 prices and configurable Price Drop alerts (2.4.1, Phase 3C)

> **Status: code-ready, NOT deployed.** Nothing in this document has been run against production.
> No migration has been applied, no Edge Function deployed, no production row read or written, no secret,
> scheduler, cron job, APNs/FCM credential, CloudKit schema, entitlement or Xcode Cloud workflow changed. The two
> migrations and the two Edge Function changes are prepared and tested on a local scratch Postgres, under Node and under
> Deno only. Applying them is a separate, explicitly authorized step (see [Rollout](#10-rollout-proposed-nothing-has-been-run)).
>
> **Phase 3C.1 (compatibility hardening)** added three things on top, still without touching production: an older client can no
> longer reset a drop size a newer client chose ([§6.1](#61-the-drop-size-contract)); an alert that predates payment types is
> offered a calm "Choose Your Price Type" step instead of being left unexplained ([§8.3](#83-price-alerts-ui)); and the production
> rollout is written down as a tested, fail-closed plan in
> [`PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md`](PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md) with read-only SQL in `supabase/runbooks/`.
> Neither migration changed in 3C.1: the drop-size fix needs no schema change.

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
| API | `supabase/functions/price-alerts-api/{index,alert-input,values}.ts` | optional `payment_type` on `set_alert`; `payment_type` + comparable-price fields on reads; optional `alert_contract_version` (the drop-size contract, §6.1) |
| Worker | `supabase/functions/price-alerts-worker/{index,message}.ts` | notification copy names the price; additive `payment_type` payload key |
| iOS | `CommunityPaymentType`, `CommunityPriceBreakdown`, `CommunityPriceLinePresentation`, `CommunityReportInputCheck`, `CommunityPaymentTypeSelector`, `StationsView`, `FuelLogView`, `ProStationsMapView`, widget snapshot files | report with a payment type; show Cash / Credit lines |
| iOS | `PriceAlertsModels/API/Service/Form/StationModel/OverviewModel`, `PriceAlertsSensitivity`, `PriceAlertSheet`, `StationAlertsView` | alert payment type and 5¢ / 10¢ / 20¢ / Custom drop size |
| iOS (3C.1) | `PriceAlertsPaymentMigration.swift` (+ the same files above) | the "Choose Your Price Type" prompt, the "Payment type needed" list banner, the carried `any_change` rule, the honest "Price type not saved" outcome |
| Rollout (3C.1) | `docs/PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md`, `supabase/runbooks/*`, `supabase/tests/price_alert_rollout_compat.test.sh` | read-only preflight / verification / observation SQL, source-hash check, the old-vs-new compatibility matrix and the incident drill |
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
- `private.prepare_price_alert_deliveries(uuid)` — replaced; same signature and ACL (postgres + service_role). It first
  takes a transaction-level **advisory lock on the station**, then processes the station's alerts `ORDER BY id FOR
  UPDATE`, so concurrent preparers serialize per station and always lock alert rows in the same order (the every-minute job
  processor prepares several reports in ONE transaction; without the station lock, an alert saved in between two of its
  prepares could deadlock with a single-report call — found in review and reproduced as scenario PC5).
- `private.mark_price_alert_delivery_sent(uuid, integer)` — replaced with its previous body plus **one guard**: the sent
  price is written to the alert only while the alert still has the payment method the delivery was decided under (a
  delivery decided before this migration counts as `unknown`). Without it, a Credit notification delivered just after the
  person switched the alert to Cash would write a Credit price into the Cash alert. Signature, return value and ACL
  are unchanged (`create or replace` keeps the grants; scenario G1 checks).
- A partial index `price_alert_deliveries_alert_queued_idx (alert_id, created_at desc) where status in ('pending',
  'processing','failed')` for the lookup below; the set is small because a delivery leaves it within minutes.
- Trigger `price_alerts_anchor_baseline` (before insert, or update of `alert_mode`/`payment_type`): anchors the
  reference to the latest comparable report **within 7 days**, else leaves it NULL (nothing invented), and clears
  `last_notified_price` when the method or mode changes (a cash notification price is never compared to a credit one).
- A one-time, idempotent fill gives each legacy alert the reference the old engine would have used for the next
  report (the latest `unknown` report), so the first report after deployment behaves as it did. It runs only on the
  first application (a session setting decided before the columns exist), so re-applying never anchors an alert that
  is legitimately waiting for its first report.
- Both files begin with `set lock_timeout = '3s'` (and end with `reset lock_timeout`): they run in one transaction and
  their `ALTER TABLE`s take locks that queue every reader and writer of the table behind them, so a file that cannot get its
  lock in 3 seconds fails and can simply be re-run, instead of stalling the table.
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
5. **Cooldown** (default 360 min) is measured from the alert's last **sent** notification (`last_notified_at` /
   `last_notified_price`, written when a delivery is marked sent, as before) or from a **newer notification still queued**
   for it under its current payment method — a delivery that is `pending`, being sent, or `failed` and awaiting a retry. That
   is what closes the two-prepared-reports race (the second report sees the first's queued delivery) **without** holding the
   cooldown for a notification that never goes out: a queued delivery that ends `dead`, `invalid_device` or `skipped` (stale,
   device unusable) is no longer queued, so it neither mutes the alert nor pins `at_or_below`'s "already notified at this
   price" memory. (An earlier draft stamped the alert when a delivery was queued; review showed a lost notification then
   muted the alert for up to 6 hours — scenario D20.) A qualifying drop that the cooldown suppresses **keeps the alert
   armed**: it fires on the next qualifying comparable report after the cooldown. Nothing is queued "for later".
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
A person moves it to Cash or Credit by editing it in the updated app: the alert list shows "Payment type needed" and the
sheet opens on "Choose Your Price Type" with Cash and Credit only (§8.3). Nothing is chosen for them, and the alert keeps its
id, station, rule, target, drop size and cooldown. The move runs through the same `set_alert` upsert as every other edit
(scenario D27 executes it, A16 does it over HTTP): the trigger re-anchors the reference to the newest report of the chosen
price type (or leaves it empty when there is none yet), so the next qualifying report establishes the starting point.
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
either migration. New behavior applies to reports prepared after migration B. A delivery the previous engine queued and has
not yet sent counts as a queued notification of its (legacy) alert, so the first report after the migration does not
produce a duplicate while it is still waiting to go out (scenario D22).

## 6. API (`price-alerts-api`) — written, not deployed

- `set_alert`: optional `payment_type` of `"cash"` or `"credit"`. Anything else — `"unknown"`, `"same_for_both"`,
  a different case, a non-string — is `400 invalid_payment_type`. **Absent (or `null`) means "not specified"**: an
  existing alert keeps its current method (`coalesce`), a new alert is stored `unknown`. `minimum_change` keeps its
  contract (0.01–2.00, default `0.05` when omitted — the **legacy** server default is unchanged; the app sends its
  10¢ new-alert default explicitly). Editing one field never resets another: the app sends the alert's full state, and
  a client that does not choose a drop size cannot reset one (§6.1).
- Responses (`set_alert` alert object, `list_alerts` rows) add `payment_type`. `list_alerts` also adds
  `latest_comparable_price`, `latest_comparable_reported_at`, `latest_comparable_payment_type` — the newest report the
  alert is actually judged on. `latest_price` / `latest_reported_at` keep their original meaning (newest report of any
  kind), so older clients are unaffected.
- Authentication, the publishable-key flow and the Pro gate are unchanged; no service-role credential reaches a client.
- Pure input rules live in `alert-input.ts` (Node-testable, `alert-input.test.ts`).

### 6.1 The drop-size contract

**The problem (3C.1).** Until the payment-aware alerts, no client could choose how big a drop an alert waits for: the
iOS app sent the fixed `0.05` (3A/3B) and a client that named nothing got the server default `0.05`. `set_alert` is an upsert
that **replaced** every setting on every save, so a request that said nothing about the drop size (or sent the fixed
default) reset a stored `0.20` to `0.05`. Once an app lets people choose 5¢ / 10¢ / 20¢ / Custom, an older client that
re-saves the same alert (an Android build, an iOS build that was downgraded or is a pre-3C.1 internal build) silently undid
the choice. Omitted and "the fixed default" were indistinguishable from a deliberate 5¢.

**Who sends what.** (Established by reading every client in this repository and the API; the Android wire format is not
visible here.)

| Client | `minimum_change` on `set_alert` | Version marker |
|---|---|---|
| iOS 3A / 3B (internal TestFlight) | always, and always the fixed `0.05` for a new alert; an edit echoes the server's value | none |
| iOS 3C (`ad02bf1`, internal) | always an explicit value (new alert 10¢; an edit sends the chosen / existing value) | none |
| iOS 3C.1 | always an explicit value | `alert_contract_version: 2` |
| Android | unknown (no code here); it was written against the `0.05` default | none |
| the `list_alerts`, `delete_alert` and device actions | never read or write it | — |

No released App Store build (2.4.0) has a Price Alerts client at all, so only internal builds and Android can be affected.

**The rule.** `alert_contract_version` is an optional integer, 1–1000; absent or `null` means 1; anything else
(`"2"`, `0`, `2.5`, `true`, `[]`, `1001`) is `400 invalid_alert_contract_version` and nothing is stored. For an alert that **already
exists**, `minimum_change` is replaced only when

| Request | Replaces the stored `minimum_change`? |
|---|---|
| version ≥ 2, `minimum_change` present (a deliberate 5¢ included) | **yes** |
| version ≥ 2, `minimum_change` omitted | no |
| no version, `minimum_change` omitted | no |
| no version, `minimum_change` = the fixed `0.05` (after rounding to thousandths, so `0.04999999999999999` counts) | no |
| no version, any other value (`0.10`, `0.137`, …) | **yes** — it cannot be the fixed default, so it was meant |

A **new** alert always takes the request's value, or `0.05` when it names none. Mode, target price and cooldown are still
replaced in full, as before; the payment type still uses `coalesce` (a request that names none keeps the alert's). The
decision is made once, in `replacesStoredMinimumChange` (`alert-input.ts`), and applied in SQL as
`minimum_change = case when <replaces> then excluded.minimum_change else private.price_alerts.minimum_change end`.
Because `ON CONFLICT DO UPDATE` re-reads the locked row, two concurrent saves (one changing the payment type, one the
drop size, or an older client's save racing either) both survive: PC6 forces four interleavings in SQL and A14 runs fifteen
rounds of three concurrent saves over HTTP.

**What it does not do — read before relying on it.**

- It is a **compatibility hint, not a security boundary.** Claiming version 2 can only make a client's *own* alert follow that
  client's own `minimum_change`; the installation secret and the Pro gate are what authorize a save, and neither changed.
- The real ambiguity is irreducible: a client with no marker that sends `0.05` might mean a deliberate 5¢ or might be an old
  client's fixed default. The contract resolves it toward **keeping** the stored value, so the cost lands only on the rare
  case: **an iOS build older than 3C.1 cannot deliberately switch an existing alert *back to* 5¢** (it can raise it, and a new
  alert starts at the value it sends). Updating the app fixes it; nothing is lost silently, the alert simply keeps the size it
  had. Alerts that were already reset to 5¢ before this fix are indistinguishable from chosen 5¢ ones and are not touched.
- **Cooldown is still replaced in full.** No client offers a cooldown choice today (the iOS form never edits it and sends the
  alert's own), so there is nothing to protect yet; a future client that lets people pick one needs the same capability.
- The default for an omitted `minimum_change` is still the legacy `0.05` for a **new** alert, so an Android alert created
  without the field keeps its previous behavior.

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

- **Which price:** Cash / Credit. No default; a new alert cannot be saved until one is chosen. The central list
  shows "Credit price · 10¢ drop" per alert, with the alert's own latest comparable price
  ("Latest Credit price $3.09"; "No Cash price reported yet" — it does **not** borrow the unfiltered latest price,
  which may be the other method's). An alert that predates payment types is handled by the next bullet.
- **Legacy alerts — "Choose Your Price Type" (3C.1).** An alert whose server record has `payment_type = unknown` keeps working
  and is never converted automatically. Both screens say so calmly, and everything shown is derived from the list the server
  returned (`PriceAlertWatch.needsPaymentChoice`) — there is no local flag, so it disappears the moment the server reports
  Cash or Credit, and opening a screen sends nothing.
  - *Price Alerts list (`StationAlertsView`):* a short explainer card above the list ("Choose Your Price Type" / "Price reports now
    distinguish Cash and Credit prices. Choose which price you want to watch to keep your alerts up to date.") and, on each such row, a
    yellow-edged banner — "Payment type needed" / "Choose Cash or Credit to continue watching this station's prices." — with a clear
    44-pt **Edit** button (the whole row opens the same sheet; VoiceOver reads "Payment type needed" and the hint "Opens this alert so you
    can choose Cash or Credit.").
  - *The sheet (`PriceAlertSheet`):* the same "Choose Your Price Type" card comes first and contains the Cash / Credit picker —
    **Cash and Credit only; "Same for Both" is a reporting choice and is not offered for an alert**. **Nothing is preselected and Save
    stays off until a type is chosen.** The form opens on exactly what the server holds (rule, target, drop size, cooldown), says "Your
    alert type and settings stay the same." while that is true, and — once Cash or Credit is picked on a Price Drop — says how the starting
    point works: "Drops are measured from the latest Credit price reported for this station. If there isn't one yet, the next Credit price —
    or one reported as the same for both — sets the starting point." It never promises a notification (alerts follow community reports).
  - *What is preserved:* the alert id (the save is an upsert on the same installation + station, never a delete-and-create), station,
    mode, At-or-Below target, drop size, cooldown, installation and Pro state. The old *notify on any price change* rule
    (`any_change`), which this screen has no card for, is **carried** unchanged until the person picks another type explicitly;
    saving the payment type alone does not convert it.
  - *Honest outcome:* after Save the app compares what the server answers with what was chosen. If the backend does not apply the
    choice (an API that predates payment types answers `unknown`), the sheet shows "Price type not saved — We couldn't save your Cash or
    Credit choice just now. Your alert is unchanged. Try again in a little while." and keeps the choice on screen; it never says
    "Price Alert updated." for a save that changed nothing.
  - *Pro and entitlement:* unchanged. A Free person sees the Pro card; an entitlement that is still resolving is "checking", never Free;
    nothing is deleted when Pro lapses; the server still refuses a non-Pro save (`pro_required`).
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
| Save an alert | old API ignores the extra key | the alert stays legacy; the app notices that the answer carries no price type and says "Price type not saved" instead of "updated" (3C.1); the list still shows "Payment type needed" |

So: **do not distribute a Phase 3C iOS build to people who will report prices or set alerts until migrations A and B and
the API are deployed** (see the order below).

## 9. Compatibility matrix

| Client | Backend | Behavior |
|---|---|---|
| Android, and any iOS build before 3C.1 (no payment type; no `alert_contract_version`) | new | Reports accepted, stored `unknown`. Alerts keep their legacy behavior (legacy stream). Notifications unchanged in wording for legacy alerts. A re-save of an alert a 2.4.1 app made keeps its payment type, its reference **and (3C.1) its drop size**: a request that omits `minimum_change`, or sends the fixed `0.05`, no longer overwrites it (§6.1). The one thing such a client cannot do is deliberately choose 5¢ for an existing alert |
| The App Store build 2.4.0 | any | has **no Price Alerts client**; nothing here applies to it. Reports it makes (none carry a payment type) are stored `unknown` |
| New iOS (3C.1) | new | Everything above; sends `alert_contract_version: 2`, so every drop size it chooses is applied, 5¢ included |
| New iOS | old (migrations not applied) | see 8.4 |
| Released clients | old | unchanged |
| Previous API / previous worker | database with A, with A + B | measured in `price_alert_rollout_compat.test.sh` (M1–M3): the previous API answers 200 everywhere; the previous worker still delivers (a Cash/Credit alert in the old wording, without `payment_type`). The **new** API on a database without B fails every `set_alert` / `list_alerts` with a 500 — hence the order in §10 |

## 10. Rollout (proposed; nothing has been run)

**The authoritative plan is [`PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md`](PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md)** (read-only
preflight, snapshot, window, queue drain, step-by-step apply with verification and abort conditions, failure analysis, fail-closed
and incident controls, resume, observation, hash validation). This section is the short form and must not drift from it.

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
   `private.price_alert_deliveries` with `status in ('pending','processing')` (they will be left alone). **Apply B when the queue is drained:** wait until
   `private.price_alert_jobs` has no `pending`, `processing` or `failed` rows (a queued job's report would be swallowed by the
   one-time legacy fill, which anchors each alert on the latest report) and, ideally, no `pending` or `processing` deliveries.
   A delivery the previous engine queued is still honored (it holds its alert's cooldown), but a drained queue makes the
   switch-over unambiguous. Both migrations start with `set lock_timeout = '3s'`: if one reports a lock timeout, re-run it.
1. **Migration A.** Effect: reports can carry a payment type; nothing else changes (the engine still compares as before).
   Verify: existing rows read `unknown`; `anon` can insert with and without the column; `anon` cannot update/delete.
2. **Migration B.** Effect is **immediate**: `prepare_price_alert_deliveries` is called every minute by the job-prepare
   cron and by the worker, so the new engine decides the very next report. Existing alerts become legacy (`unknown`) and
   keep working on unclassified reports. Verify: alerts keep their rows; `baseline_price` is filled for legacy alerts
   that had a prior report; no delivery was created by the migration itself.
3. **Deploy `price-alerts-api`** (all of its files: `index.ts`, `alert-input.ts`, `values.ts`, `deno.json`; a per-file upload path must include the helpers or the function will not boot) **with `verify_jwt = false`** — the iOS publishable key is not a JWT, and a tool whose default is `true` would lock every app out. Verify `set_alert` with and without `payment_type` and with and without `alert_contract_version`, `list_alerts` fields, `400
   invalid_payment_type`, `400 invalid_alert_contract_version`, and the deployed file hashes (`supabase/runbooks/price_alerts_function_hashes.sh`).
4. **Deploy `price-alerts-worker`** (all of its files: `index.ts`, `auth.ts`, `fcm.ts`, `message.ts`, `deno.json`; `verify_jwt = false`, as `config.toml` says). The invoker cron is reported **active** (step 0), so the deployed worker is live within
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

**Rollback / fail-closed.** (The full incident plan — which control for which problem, the exact statements C1–C6, cancelling
queued notifications, the two cron jobs that may be paused and the ones that must not be touched, and resume — is section 9 of the
readiness document; the incident drill is executed by `price_alert_rollout_compat.test.sh`, scenario T6.)
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
| SQL decision matrix — scenarios R1 (reports/grants/RLS), C1 (comparability), E1 (the pure function), D1–D27 (isolation, cumulative drops, type switching, legacy, out-of-order, repeats, cooldown, rearm, baseline, Pro gate, devices, idempotence, fail-closed, anchor, delivery record, the exact `set_alert` upsert incl. an older client and an edit that names no method, `list_alerts` returning both the legacy latest and the comparable latest, a `same_for_both` report driving a Price Drop alert of either method while never reaching a legacy one, the fail-closed pause, an unsent notification not holding the cooldown, the `mark_sent` guard, a pre-migration queued delivery, a notification queued under the other method, the station advisory lock, **and (3C.1) D25 an older client's save keeping a chosen drop size while a declared client's deliberate 5¢ is applied, D26 repeated identical saves, D27 a legacy alert moving to Cash/Credit through the real upsert**), G1 (ACLs, index, re-apply) | `supabase/tests/price_alert_payment_type.test.sql` | local Postgres 16 scratch DB, `supabase/tests/support/replay_migrations.sh` + `local_supabase_shims.sql` |
| Migration preservation (rows unchanged, no rewrite, idempotent re-apply, legacy fill, old-client insert, permission matrix) | `price_alert_payment_type_migration.test.sh` | same |
| Concurrency (PC1 cooldown race, PC2 one report prepared twice, PC3 a burst through the real grants while the job processor runs, PC4 the `set_alert` upsert racing a prepare, PC5 the lock-order deadlock, **PC6 (3C.1) two saves racing each other — payment-only vs drop-size-only vs an older client — in four forced interleavings**) | `price_alert_payment_type_concurrency.test.sh` | same |
| Edge Function pure modules (input rules, **the drop-size truth table**, copy, payload) | `supabase/functions/**/*.test.ts` | `node --test` (Node 22 type-stripping) or `deno test`; the entry points are also pinned by source-text assertions |
| The Edge Functions themselves, end to end, under Deno against a local Postgres: the API's `set_alert` / `list_alerts` / `delete_alert` over HTTP (A1–A9: an older client, the 2.4.1 app, edits that keep the method, `invalid_payment_type`, bounds, comparable-latest fields, re-anchoring, non-Pro, delete; **A10–A16 (3C.1): an older client's re-save keeps the drop size, the 2.4.1 app's 5¢/10¢/20¢/Custom round-trip, single-field edits, sixteen malformed versions, repeated saves, concurrent saves, the Pro gate regardless of the version, and a legacy alert moving to Cash then Credit**), and the worker preparing, claiming and "sending" five notifications with the push providers stubbed (3 APNs, 2 FCM: copy, additive `payment_type`, legacy payload unchanged, the delivery's recorded method) | `price_alert_api_payment_type.test.sh`, `price_alert_worker_message.test.sh` (+ `support/worker_with_recorded_fetch.ts`) | Deno 2.x, jq, curl, openssl, psql and a replayed scratch database; nothing leaves the machine (the wrapper refuses any URL but the providers') |
| **Rollout compatibility (3C.1)**: the previous API and worker (exported from git) and the new ones against a database before A, with A only, and with A + B (M1–M3), a false alert between A and B (T1), a notification queued by the previous engine surviving B (T2), a job still queued when B is applied (T3), a B that fails (T4), a report submitted while B runs (T5), the incident drill (T6), the lock window at 300k–1M rows (T7) | `price_alert_rollout_compat.test.sh` | Deno 2.x, psql and scratch databases it creates and drops; `OLD_REV` (default `1f88df0`) names the previous sources |
| Swift (models, form, presets, service, wire contract, report rules, breakdown, presenter, widget model, notification payload; **3C.1: the legacy-alert prompt, list banners, carried rule, honest outcome and the wire marker**) | `EightyFiveBlendsTests/*` (`PriceAlertsLegacyMigrationTests.swift` is new) | Xcode (`xcodebuild test`) |

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
8. **A notification SENT shortly before the person switches the alert's method still rate-limits the alert.** Switching
   clears the notification *price* (a Credit price is never compared with a Cash one) but keeps the notification *time*, so the
   first Cash notification can be held until the cooldown that the Credit one started has run out. A notification still *queued*
   under the other method holds nothing (scenario D23).
9. **`superseded` is decided on the report's `reported_at`, which the client supplies** (the INSERT policy allows up to
   10 minutes in the future and 7 days back). A future-dated report makes honest reports dated before it `superseded` for
   at most those 10 minutes. Reports already needed a valid price and passed the rate limiter, and a forged drop could always
   have notified, so this adds no new abuse class, but it is a way to briefly mute an alert.
10. **A payment method with no report among a station's 20 newest has no line** in the app, which reads as "not reported
    recently" rather than "not accepted here".
11. **An alert saved at the very instant a report is inserted can be anchored one report behind.** The anchor is read in a
    `BEFORE INSERT` trigger and the report's job is only enqueued if an enabled alert is visible to the report's transaction;
    a report that commits just before the alert does is in neither. The next report at the same price could then fire a drop from
    the older reference. The window is one statement (sub-millisecond in practice; the review needed a deliberate 3 second pause
    to hit it). Closing it would put a station lock in the public report-insert path, which is not worth it.
12. **Fully tied reports are ordered by id.** Rows from one multi-row `INSERT` share `reported_at` and `created_at`, so which
    is "newest" is arbitrary. The app posts one report at a time; only a batch writer can tie.
13. **(3C.1) A client without the marker cannot deliberately choose 5¢ for an existing alert.** The server cannot tell a
    deliberate `0.05` from an older client's fixed default, so it keeps the stored value (§6.1). This affects only an iOS
    internal build older than 3C.1 (and Android until it declares the contract); updating fixes it. The alternative —
    treating `0.05` as deliberate — would let an Android re-save reset a chosen 20¢, which is the harm being prevented.
14. **(3C.1) Cooldown is still replaced in full by every save.** No client offers a cooldown choice today. If one ever does, give it
    the same capability treatment (omitted means "keep").
15. **(3C.1) `alert_contract_version` is advisory.** Anyone holding an installation's secret can already rewrite that installation's
    own alerts; the marker only chooses between "this request means its `minimum_change`" and "it may be a default". It is not
    checked against an app version, not stored, and not a security control.
16. **(3C.1) Alerts that were reset to 5¢ before this fix cannot be recognized** (a reset and a chosen 5¢ are the same row). The
    preflight records the distribution of stored values (`alerts.minimum_change_values`) so the owner sees how many alerts exist
    and what they hold; nothing is guessed or rewritten.
17. **(3C.1) A legacy alert keeps listening only to unclassified reports until its owner chooses.** The app now says so (§8.3), but
    it is a prompt, not a migration: someone who never opens the app never chooses, and that alert gradually hears less (question 1).
    Choosing for them was rejected on purpose — a guessed price type would alert on the wrong price.

## 13. Android follow-up (no Android code lives in this repository)

Everything is additive and optional, so the shipped Android app keeps working unchanged at the HTTP level (measured against the previous
and the new backend in every intermediate state: `price_alert_rollout_compat.test.sh`). **One thing no test here can show: the new API adds
fields to the `set_alert` and `list_alerts` responses, and an Android JSON decoder that rejects unknown keys would fail on them — confirm it ignores
them before the API is deployed (readiness document, Step 5).** To adopt the feature:
send optional `payment_type` (`cash`/`credit`) on `set_alert`; **once the app offers a drop-size choice, also send
`alert_contract_version: 2` with `minimum_change` on every `set_alert`** (without it the server keeps a stored drop size when the
request carries the fixed `0.05`, §6.1); read `payment_type` and the `latest_comparable_*` fields
from `list_alerts` (fall back to `latest_price` when absent); read the optional `payment_type` FCM data key; add the
same Payment Type choice to price reports (`payment_type` on insert, omitted when unchosen) and the 5¢/10¢/20¢/Custom
drop-size choice; show an alert without a payment type as "Payment type needed" and offer Cash or Credit (not "Same for Both"),
carrying the rest of the alert unchanged — the iOS copy is in §8.3. Until then Android alerts are legacy
alerts (see question 1), and an Android re-save never resets a drop size chosen elsewhere.
