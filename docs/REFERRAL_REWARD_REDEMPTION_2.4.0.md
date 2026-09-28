# Referral Reward Redemption — 85Blends 2.4.0

Completes the existing, deliberately-unfinished Refer & Earn promise: **every 5 qualified paid
referrals earns 1 free month of 85Blends Pro.** Before this feature, that free month was tracked
(`private.referral_rewards`, status `earned`/`fulfilled`/`revoked`) but could never actually be
redeemed. This feature adds real Apple subscription Offer Code issuance and webhook-confirmed
fulfillment.

**Status: NOT deployed.** This document describes what has been built, how to deploy it safely,
and exactly what still needs verification against real App Store Connect / Sandbox before this
feature is release-ready. Nothing in this PR touches production migrations, functions, or App
Store Connect resources.

## 0. Correctness hardening pass (post-initial-review)

An independent review of the first revision of this PR found five real issues, all fixed in this
revision:

1. **Terminology error** — an earlier revision of this migration/code described App Store
   Connect subscription Offer Codes as having a separate "Offer Identifier" distinct from an
   internal-only "Reference Name." That is wrong: Offer Codes have only one field, the offer's
   **Reference Name** (App Store Connect: Subscriptions > offer codes > create), which is both
   what identifies the offer in App Store Connect's own Reports and the exact value RevenueCat's
   webhook exposes as `event.offer_code`. The two-field split described in the earlier revision
   belongs to a different Apple mechanism (signed Promotional Offers), not Offer Codes. Corrected
   everywhere (migration comments, `referral-reward-offer-codes.ts`, this document) — see §4.
2. **Expired issued codes could trap a reward forever** — `claim_referral_reward` returned an
   existing `status='issued'` code without checking `apple_expires_at`, and `loadStatusResponse`
   exposed it the same way. Fixed: `apple_expires_at` is now `NOT NULL` on every pooled code;
   `claim_referral_reward` now auto-voids an expired issued code and allocates a fresh one in the
   SAME call (never consuming a second reward); `loadStatusResponse` now excludes an expired issued
   code from ever being shown as redeemable. See §2 below and the migration's own Step 5b.
3. **A revoked reward's already-issued code could still be fulfilled** — the existing milestone
   shrink logic (unmodified) can revoke an `earned` reward that already has an `issued` code (a
   qualifying referral it depended on was refunded after the claim). Fixed at two layers: a new
   trigger (`referral_rewards_void_issued_code_on_revoke`) auto-voids the code the instant the
   reward is revoked, and `fulfill_referral_reward_offer_code` now independently locks and
   re-checks the reward's own status (never trusting the code's `issued` status alone) before ever
   marking anything redeemed, and verifies its own reward UPDATE actually affected a row before
   reporting `fulfilled`. See §2/§7b.
4. **No RevenueCat sync after external Offer Code redemption** — the redemption sheet only called
   a plain CustomerInfo refresh on return from the App Store, which does not itself prompt
   RevenueCat to sync a transaction it never observed directly. Fixed: `RevenueCatSubscriptionService`
   now exposes `syncAfterExternalRedemption()`, which calls RevenueCat's own `syncPurchases()` (a
   real, documented SDK method distinct from `restorePurchases()` — confirmed against the SDK's own
   source and changelog), routed through the SAME `apply(_:)` entitlement bridge every other
   CustomerInfo path already uses. See §3.
5. **SANDBOX/PRODUCTION isolation was previously all-or-nothing** — `fulfill_referral_reward_offer_code`
   rejected every non-PRODUCTION event outright, which would have made Sandbox/TestFlight
   end-to-end verification of this feature impossible before release, while providing no real
   per-row isolation for the PRODUCTION side either. Redesigned: both `private.referral_rewards`
   and `private.referral_reward_offer_codes` now carry an `environment` column; `claim_referral_reward`/
   `fulfill_referral_reward_offer_code` require an exact environment match at every step; the
   TypeScript fulfillment classifier no longer excludes SANDBOX outright. See §2/§7a's own design
   note for why the REWARD row itself (not just the code pool) needed this tag, and the alternative
   that was considered and rejected.

**Every one of these was independently exercised against a real local Postgres 16 replay** (see §2
for exactly what was run) — not merely reasoned about. Sections below are updated in place to
reflect the current, hardened design; §11 records exactly what remains unverified.

## 0b. Second correctness hardening pass

A second, independent review of the first hardening pass's revision found three further real
issues, all fixed in this revision (see §7c, §3, and §2 respectively for the full design of each):

1. **Reward status didn't actually change on issuance** — the first hardening pass's design still
   left `private.referral_rewards.status` at `'earned'` for as long as a code was merely `issued` on
   the CODE row; only the code itself carried `'issued'`. Fixed: the reward's own lifecycle is now a
   real three-state machine, `earned -> issued -> fulfilled`, with `revoked` applying only while
   there is no live issued code — enforced structurally by a new guard trigger, not merely by
   convention. This also required widening the baseline migration's own `referral_rewards_status`
   CHECK constraint to permit `'issued'` — a real gap caught only by actually executing this
   migration against local Postgres. See §7c.
2. **Claim environment was resolved by scanning historical aliases, not the current installation** —
   `resolveClaimEnvironment` used to scan EVERY alias a participant had ever accumulated in
   `private.referral_participant_aliases` and let PRODUCTION win whenever both existed, which is
   backwards for a participant/installation that is CURRENTLY, genuinely bootstrapped as SANDBOX but
   happens to also carry an older PRODUCTION alias. Fixed: `private.referral_client_installations`
   (the existing per-installation credential table) now stores `current_environment`/
   `current_app_user_id`, written on every successful bootstrap; every action (`bootstrap`/`status`/
   `apply_code`/`claim_reward`) derives environment from THIS installation's own current context,
   never a lifetime-aggregated scan. See §3.
3. **A failed fulfillment update after the code was already redeemed was reported as a safe
   outcome, not an abort** — the first hardening pass's own `reward_update_failed` outcome returned
   normally even though, by that point, a real one-time-use Apple code had already been marked
   redeemed — an impossible-in-practice but silently-reported "failure" that left the code
   permanently consumed. Fixed: both of `fulfill_referral_reward_offer_code`'s final UPDATEs now
   `RAISE EXCEPTION` on an unexpected zero-row result instead, aborting the ENTIRE surrounding
   transaction (the same one the entitlement-mirror write runs in), so the already-mutated code is
   rolled back too. Proven with a forced-failure test, not merely reasoned about — see §2.

**Every one of these was independently exercised against a real local Postgres 16 replay, from a
clean database**, including a dedicated forced-invariant-failure test for issue 3 (see §2) — not
merely reasoned about.

## 0c. Third correctness hardening pass

A third, independent review of the second hardening pass's revision found one remaining
user-facing state-machine bug and one further transactional hardening item, both fixed in this
revision (see §7d and §2 respectively for the full design of each):

1. **Issued-reward reentry / expired-reward recovery was broken** — `buildReferralStatusResponse`
   correctly excludes an `issued` reward from `earned_months_available` (§0b issue 1 made this
   true), but `ReferEarnView`'s reward card and `ReferralRewardRedemptionSheet`'s content both still
   gated ENTIRELY on `earnedMonthsAvailable > 0`. The exact 5-referral scenario this broke: claim
   succeeds → reward becomes `issued` → `earnedMonthsAvailable` correctly drops to 0 →
   `issuedRewardCode` is present → the reward card (and the sheet's own reopening path) disappeared
   anyway, because the ONLY gate checked was the now-zero count. A second, related bug: an issued
   code that EXPIRES before the client ever calls `claim_reward` again produces
   `earnedMonthsAvailable = 0 AND issuedRewardCode = null` — with no signal at all, the reward could
   become PERMANENTLY STRANDED even though `claim_referral_reward` already knows exactly how to
   recover it (void the dead code, revalidate, reissue or revoke). Fixed with a new CLIENT-SAFE
   RECOVERY SIGNAL, `issued_reward_needs_refresh` — a boolean, `true` exactly when a reward is
   `issued` but has no live code — computed entirely from data this migration's schema already
   exposes (no new query, no mutation, the status endpoint stays read-only). iOS now gates on
   `earnedMonthsAvailable > 0 OR issuedRewardCode != nil OR issuedRewardNeedsRefresh` via a single
   `ReferralPresentation.rewardCardState` decision function, with three distinct card/sheet states
   (earned / issued / needs-refresh) — see §7d.
2. **`claim_referral_reward`'s own final code+reward issuance wasn't held to the same invariant
   discipline as `fulfill_referral_reward_offer_code`** — both rows are locked and freshly confirmed
   matching their expected status moments earlier in the same call, so a zero-row result on either
   final UPDATE is a structurally-impossible invariant violation, but nothing verified that before
   this pass. Fixed: the same `GET DIAGNOSTICS ... row_count` + `RAISE EXCEPTION` discipline §0b
   issue 3 added to `fulfill_referral_reward_offer_code` now also covers `claim_referral_reward`'s
   expired-code void, both branches of the expiration-revalidation reward transition, and the final
   code-issuance + reward earned -> issued pair. Proven with a forced-invariant-failure test using
   the SAME methodology as §0b issue 3's own test — see §2.

**Every one of these was independently exercised against a real local Postgres 16 replay, from a
clean database**, including a second dedicated forced-invariant-failure test (this time for
`claim_referral_reward`'s own final issuance pair — see §2) — not merely reasoned about. Issue 1's
fix was additionally verified via 4 new Node tests covering the exact live-code/expired-code/
no-reward/environment-already-scoped cases, and new Swift Testing cases pinning the card-state
decision logic (no Xcode toolchain in this environment — see §11 for what that leaves unverified).

## 1. Architecture

```
                    ┌────────────────────────────┐
  iOS app  ───────► │ referral-api (claim_reward) │ ───► RevenueCat REST API v2
                    │                              │      (resolve active Pro + product,
                    └──────────────┬───────────────┘       backend-authoritative)
                                   │
                                   ▼
                    private.claim_referral_reward(...)
                    - locks the oldest 'earned' reward
                    - allocates one available Apple code
                    - returns the SAME code on a repeat claim

  Apple/RevenueCat ─────────────────────────────────────┐
  (a real redemption transaction)                        ▼
                    ┌───────────────────────────────────────────┐
                    │ revenuecat-webhook (existing entry point)   │
                    │  + NEW fulfillment detection                │
                    └──────────────────┬───────────────────────────┘
                                       ▼
                    private.fulfill_referral_reward_offer_code(...)
                    - matches participant + product + offer reference
                    - marks the code redeemed, the reward fulfilled
```

Backend is authoritative throughout: the iOS app never decides whether it owns a reward, which
product an active subscriber's code is for, or whether a redemption has been confirmed.

## 2. Migration changes

One file: `supabase/migrations/20260928000000_referral_reward_redemption_foundation.sql` (edited in
place across both revisions of this PR — never deployed, so editing it directly, rather than
stacking a second migration on top, is correct here; see CLAUDE.md's own migration hygiene, which
only forbids editing an already-*applied* migration).

**Verified via a real local Postgres 16 replay, FOUR times** (this container has full
`postgres`/`initdb` server binaries, not just the `psql` client) — once against the first revision
of this PR, again against the first hardening pass, again against the second hardening pass, and
again, fully from a clean database, against this third hardening pass. Every replay applied the
ENTIRE existing migration chain in order (skipping only the one pre-existing, unrelated migration
that requires the `pg_cron` extension, which this sandbox doesn't have installed), then this
migration. The first replay caught and fixed one real bug before it ever reached the original PR:
several `where`/`order by` clauses referenced
`reward_id`/`milestone_number`/`product_id`/`apple_expires_at`/`referrer_participant_id`
unqualified, which PL/pgSQL treated as ambiguous against those same names appearing as this
function's own `RETURNS TABLE` columns ("column reference ... is ambiguous") — fixed by
table-qualifying every reference in both functions. (This exact bug class — an unqualified column
colliding with a `RETURNS TABLE` name — was independently found by a prior, unrelated review of a
DIFFERENT migration in this repo, `20260921000000_promo_campaign_foundation.sql`, whose own
`.test.ts` file documents it could only be caught by a real Postgres instance, never a static text
check; this feature's own local replay is exactly that missing verification step, now actually
performed.) The THIRD replay, for the second hardening pass, caught a second real bug the same
way: the baseline migration's own `referral_rewards_status` CHECK constraint only ever permitted
`status in ('earned', 'fulfilled', 'revoked')` — with no `'issued'` value — so the very first
`UPDATE ... SET status = 'issued'` under the new state machine failed outright with a constraint
violation until this migration's own Section 1c widened it. The FOURTH replay, for this third
hardening pass, introduced no new schema objects (issue 1 is a TypeScript/iOS-only fix — see below
— and issue 2 only adds `GET DIAGNOSTICS` checks to existing UPDATE statements) and confirmed zero
regressions across the full scenario suite from all three prior passes, plus a new dedicated
forced-invariant-failure test for `claim_referral_reward`'s own final issuance pair. None of these
bugs was found by static reading; all were found only by actually executing the SQL.

The first hardening pass's replay exercised, with real data: 5 and 10 qualifying referrals producing
the expected earned reward(s); idempotent repeat claims; expired-code auto-void-and-replace;
revoke-while-issued (via the since-superseded auto-void trigger); requalification after revocation;
environment-isolated claim/fulfillment in both directions; and terminal-state enforcement.

**This second hardening pass's replay**, fully from a clean database, exercised the new state
machine and environment model with real data end to end: (1) `claim_referral_reward` transitioning a
reward `earned -> issued` the instant a code is allocated; (2) a REAL refund (the existing,
unmodified `refund_reversal` action) dropping the qualified count while a reward was `issued`, and
confirming the milestone-shrink logic — scoped to `status = 'earned'` — left the `issued` reward
completely untouched, never revoking it; (3) webhook fulfillment succeeding normally on that
still-issued reward after the refund, transitioning it `issued -> fulfilled`, and that fulfilled
reward remaining immune to a SUBSEQUENT shrink attempt too; (4) an issued code forced to expire
while its milestone was STILL justified by the current qualified count — correctly reverting the
reward to `earned` and issuing a genuinely fresh code in the same call, with exactly one reward row
for that milestone throughout; (5) an issued code forced to expire AFTER five refunds dropped the
qualified count below the milestone's threshold — correctly revoking the reward outright
(`expired_no_longer_qualified`) with NO replacement code ever issued; (6) a single participant
holding BOTH a PRODUCTION alias/rewards and a SANDBOX alias/reward (simulating a historical
environment switch) — confirming a SANDBOX-environment claim only ever touched the SANDBOX reward
row, leaving the PRODUCTION rewards (one fulfilled, one revoked) completely untouched, and vice
versa; (7) the exact query shape `loadStatusResponse` now uses (`referrer_participant_id` +
`environment`) returning only the correct environment's reward rows; (8) an independent SANDBOX
participant's full claim -> webhook-fulfillment cycle succeeding on its own. Every scenario passed
on the first attempt after fixing the `referral_rewards_status` constraint gap above.

**Transaction-rollback hardening (issue 3) was proven, not just written**, with a dedicated forced-
invariant-failure test: two test-only copies of `fulfill_referral_reward_offer_code`, each with ONE
of its two final `UPDATE` statements' `WHERE` clause deliberately changed to a status value that can
never match (simulating the "impossible" zero-row-update condition by construction, since under
real locking this branch cannot be reached by a genuine race), confirmed that (a) the call raises
rather than returning a typed outcome, (b) a subsequent statement in the SAME transaction is
rejected with "current transaction is aborted," proving the WHOLE transaction is poisoned, not just
the failing statement, and (c) after an explicit `ROLLBACK`, the code is back to `issued` (never
left `redeemed`) and the reward is back to `issued` (never left `fulfilled`) — including in the
harder case where the CODE update had already genuinely succeeded before the REWARD update was the
one forced to fail, proving the already-mutated code gets rolled back too, not just the failing
statement's own effect.

**This third hardening pass's replay**, fully from a clean database, re-ran the ENTIRE scenario
suite from both prior hardening passes with zero regressions (the new `GET DIAGNOSTICS` checks
never fired a false positive against any legitimate path), then added a dedicated
forced-invariant-failure test for `claim_referral_reward`'s own final code+reward issuance pair —
the exact same methodology as the second pass's fulfillment test: a test-only copy of the function
with the REWARD UPDATE's `WHERE` clause deliberately mismatched (the CODE UPDATE immediately before
it genuinely succeeds first), confirmed that (a) the call raises, (b) a subsequent statement in the
SAME transaction is rejected with "current transaction is aborted," and (c) after an explicit
`ROLLBACK` the code is back to `available` (never left `issued`) and the reward is back to `earned`
(never left `issued`) — proving the ALREADY-SUCCEEDED code-issuance UPDATE is rolled back too, then
confirmed the real, unmodified `claim_referral_reward` still succeeds normally on the same
untouched fixture afterward (this was a forced test artifact, not a real bug). Issue 1's
`issued_reward_needs_refresh` fix required no new Postgres scenario — it reads data the second
pass's own scenarios (4 and 5, expiration in both directions) already exercised at the SQL layer;
its own new coverage is 4 Node tests plus new Swift Testing cases (§11).

**Every pure `_shared/*.ts` Node test in this feature was also actually EXECUTED** (not merely
written) — `node --test supabase/functions/_shared/*.test.ts` runs cleanly under this container's
Node 22 (native TypeScript support, no transpile step needed): **352 tests, 352 passing, 0
failing**, across every shared module this feature touches or added (347 after the first hardening
pass, 348 after the second, +4 new tests for `issued_reward_needs_refresh` added by this third
pass). An earlier revision of this document said Deno-file testing was entirely unavailable in this
environment; that undersold what Node 22 can actually execute here — corrected in an earlier
revision.

**Zero changes to any existing FUNCTION'S body** — in particular,
`private.process_referral_subscription_event` (the existing qualification/refund function) is
**not modified**. The one new qualification-timing rule this feature needs (a RENEWAL may qualify
a still-pending attribution only if it followed one of our own free reward months) is enforced in
TypeScript (`_shared/database.ts`), as an extra check performed **before** that existing function
is ever called — see §7 below. This revision DOES additively alter the existing
`private.referral_rewards` TABLE (one new `environment` column, safely backfilled — see below) —
still zero changes to any function this repo already had before this feature.

New/changed objects:

- `private.referral_reward_offer_codes` (new table) — the Apple one-time-use code pool. RLS
  enabled, zero policies, `service_role`-only grants (no DELETE, even for service_role — a
  depleted pool is replenished by inserting fresh rows, never by deleting history). Key
  constraints/columns:
  - `apple_code` UNIQUE.
  - `apple_expires_at` **NOT NULL** (hardening pass — every pooled code has a known expiration; an
    unknown-expiration row can never exist, which is what makes "an issued code that has expired"
    a detectable state at all).
  - `environment` **NOT NULL**, `SANDBOX`/`PRODUCTION` (hardening pass — see below).
  - `product_id` restricted to the three shipping products.
  - `offer_reference_name` restricted to the three dedicated referral-reward offers, and a CHECK
    permanently pairs each reference with its own product (mismatched pairs are rejected at the
    database level, not just in application code).
  - A partial unique index enforces "a reward owns at most one live (issued/redeemed) code."
  - A partial unique index (now on `(referrer_participant_id, environment)`, hardening pass)
    enforces "a participant has at most one outstanding **issued** code per environment at a time"
    — the non-negotiable business rule that keeps webhook fulfillment matching unambiguous.
  - A `BEFORE UPDATE` trigger makes `redeemed`/`void` terminal states and forbids any code
    returning to `available` once issued.
- `private.referral_rewards` (existing table, additive changes) — new `environment` column,
  `NOT NULL`, defaulting to `'PRODUCTION'` (first hardening pass; safely backfilled — see §7a).
  **Second hardening pass:** the baseline's own `referral_rewards_status` CHECK constraint is
  widened from `('earned','fulfilled','revoked')` to `('earned','issued','fulfilled','revoked')` —
  see §2's own replay notes above for the real bug this closes — and a new partial unique index,
  `referral_rewards_one_issued_per_referrer_environment` on `(referrer_participant_id, environment)
  where status = 'issued'`, mirrors the code pool's own outstanding-code index at the reward layer.
- `private.referral_client_installations` (existing table, additive change — SECOND hardening
  pass) — new nullable `current_environment`/`current_app_user_id` columns, written on every
  successful bootstrap, holding ONLY this installation's most recent identity (never a historical/
  aggregated set). See §3/§0b issue 2.
- `private.referral_rewards_guard_transition` (new trigger, SECOND hardening pass) — **replaces**
  the first hardening pass's `referral_rewards_void_issued_code_on_revoke` entirely (removed — its
  own firing condition, `earned -> revoked` with a live issued code, can no longer occur under the
  new state machine, since a reward is never `earned` while its code is `issued`). The new `BEFORE
  UPDATE` guard proactively enforces: `fulfilled` is terminal; `fulfilled` is only ever reached from
  `issued`; and a reward may never become `revoked` while it still has a live `issued` code. See
  §7c.
- `private.claim_referral_reward(...)` (new function; signature unchanged from the first hardening
  pass — still `p_environment` as the 2nd param, now backed by `current_environment` rather than an
  alias scan) — the one atomic claim operation, rewritten for the new state machine and expiration-
  revalidation logic (see §4/§7a/§7c).
- `private.fulfill_referral_reward_offer_code(...)` (new function, hardened again in place — same
  7-param signature) — the one atomic fulfillment operation, now requiring `status = 'issued'` and
  raising on an impossible partial update instead of returning a typed failure (see §5/§7b/§7c).

## 3. Edge Function / webhook changes

**`supabase/functions/referral-api`** — new `claim_reward` action, and environment resolution
changed for EVERY action (SECOND hardening pass):
- Authenticates with the exact same installation-secret model as `bootstrap`/`status`/`apply_code`.
  `authenticateInstallation` now ALSO resolves and returns this installation's own
  `current_environment` (from `private.referral_client_installations` — see §7a/§0b issue 2),
  failing closed with `environment_unresolvable` (409) if it's somehow unresolvable — this
  replaces the first hardening pass's `resolveClaimEnvironment`, which used to scan EVERY alias a
  participant had ever accumulated and let PRODUCTION win; that function is removed entirely.
  `handleBootstrap` writes `current_environment`/`current_app_user_id` from the request's own
  `revenuecat_environment`/`revenuecat_app_user_id` fields on EVERY successful bootstrap (new
  installation or idempotent repeat) as part of the same transaction that resolves the participant.
- Every action's `loadStatusResponse` call is now scoped by this same resolved environment — the
  reward-milestone rows and the issued-code lookup both filter `AND environment = $environment`, so
  an installation that has, across its lifetime, been bootstrapped in more than one environment can
  never see a stale/other-environment reward or code in its CURRENT status response (`qualified_count`/
  `pending_count` stay unscoped — see §7a for why).
- For `claim_reward` specifically: resolves the participant's RevenueCat identity/identities IN THAT
  ENVIRONMENT from `private.referral_participant_aliases` and calls the existing
  `fetchCustomerSubscriptions` REST client (same one `revenuecat-webhook` already uses, now called
  with the resolved environment rather than a hardcoded `'production'`) to determine,
  backend-authoritatively, whether the participant is an active Pro subscriber and which product
  they're on (`_shared/referral-active-product.ts`, new — deliberately a separate file from
  `entitlement.ts`, which stays untouched).
- If the RevenueCat lookup itself fails, the claim is refused (`revenuecat_lookup_failed`) rather
  than guessing — never lets an active subscriber be misrouted through the "choose any plan" path
  because of a transient failure.
- Calls `private.claim_referral_reward(...)` (passing the resolved environment) and returns a safe
  payload: claim outcome, which milestone it concerned, and the full (already-updated) referral
  status — which now also carries the issued code's product/offer reference/raw code/expiration
  when one exists (see §6), excluding any code that has since expired.
- New required env vars: `REVENUECAT_PROJECT_ID`, `REVENUECAT_V2_SECRET_API_KEY` (same values
  `revenuecat-webhook` already uses).

**`supabase/functions/revenuecat-webhook`** — new fulfillment detection, checked on every "normal"
parsed event (any type — see §7 for why): if the event carries one of the three dedicated referral
reward offer references, `private.fulfill_referral_reward_offer_code(...)` runs inside the SAME
transaction as the existing entitlement-mirror write. A fulfillment candidate is never gated on
`isReferralRelevantEventType` — a RENEWAL can be simultaneously "not itself a qualifying event" and
"exactly the event fulfillment exists to detect." The candidate's own `environment` is now the
event's REAL reported environment (SANDBOX or PRODUCTION), no longer hardcoded to require
PRODUCTION at the TypeScript layer — see §7a for where the real isolation guarantee now lives.

**`supabase/functions/_shared`** — new files: `referral-reward-offer-codes.ts` (offer reference
constants + classification), `referral-active-product.ts` (active-product resolution). Extended:
`referral-classification.ts` (offer-code exclusion, RENEWAL qualification candidate — see §7),
`database.ts` (the reward-redemption-proof gate + the new fulfillment call path),
`revenuecat-types.ts` (`product_id` field), `referral-api-env.ts`/`-validation.ts`/`-response.ts`
(the new action's config/request/response shapes).

## 4. Apple Offer Code lifecycle

Three dedicated Apple subscription Offer Codes, one per shipping plan — **never** the public
85BLENDS launch promotion, and never a general promo-campaign system:

| Plan | Offer Code Reference Name (App Store Connect) | Product |
|---|---|---|
| Monthly | `REFERRAL_REWARD_MONTHLY_1M_FREE` | `com.85blends.subscription.monthly` |
| 3 Months | `REFERRAL_REWARD_3MONTH_1M_FREE` | `com.85blends.subscription.threemonth` |
| Annual | `REFERRAL_REWARD_ANNUAL_1M_FREE` | `com.85blends.subscription.annual` |

Each: 1 month free, eligible for New/Existing/Expired subscribers, auto-renews at the product's
normal price unless cancelled. **Terminology correction** (an earlier revision of this document
got this wrong): for App Store Connect subscription **Offer Codes** specifically, the "Reference
Name" you enter when creating the offer (Subscriptions > offer codes > create) is the value that
identifies the offer in App Store Connect's own Reports **and** the value RevenueCat's webhook
exposes as `event.offer_code`. There is no separate, hidden "Offer Identifier" field for Offer
Codes distinct from Reference Name — that two-field split belongs to a different Apple mechanism
(signed Promotional Offers), not Offer Codes. Every one of the three values above must be entered
as the offer's **Reference Name** when creating it in App Store Connect — using the wrong field (or
misreading which field this is) silently breaks fulfillment matching in production with no
client-visible error.

Lifecycle: `available` (imported, unused) → `issued` (assigned to one reward via `claim_reward`) →
`redeemed` (a real RevenueCat transaction confirmed it) or `void` (expired before redemption — the
reward stays `earned` and gets a fresh code on the next claim; no reward is ever consumed by a
voided code). Raw codes are imported out-of-band by an operator with database access (see §9's
step 8) — this database never generates or fabricates an Apple code.

## 5. Webhook reconciliation despite RevenueCat not exposing the literal code

RevenueCat can identify the Apple Offer Code's **offer reference** on a transaction
(`event.offer_code`), but cannot reliably expose the literal one-time code the customer typed.
Reconciliation is therefore keyed entirely on: participant identity (the same alias-set resolution
`process_referral_subscription_event` already uses) + environment + product ID + the dedicated
offer reference + "this participant's ONE outstanding issued code." Because a participant can have
at most one outstanding issued code at a time (enforced by a partial unique index, not just
application logic), that match is never ambiguous — `fulfill_referral_reward_offer_code` doesn't
need the literal code to know which reward a confirmed transaction fulfills.

## 6. Status response additions

`referral-api`'s status payload (returned by `bootstrap`/`status`/`apply_code`/`claim_reward`)
gains four fields, populated only while a reward currently has a live issued code for this
installation: `issued_reward_product_id`, `issued_reward_offer_reference_name`,
`issued_reward_code` (the raw Apple code — safe here specifically because this response only ever
reaches the authenticated installation it was issued to), `issued_reward_expires_at`. Never
returns a reward/participant UUID, another participant's data, or unused code-pool data.
**Hardening pass:** `loadStatusResponse`'s underlying query now filters `AND apple_expires_at >
now()`, so an issued code that has already expired (but not yet reclaimed by a subsequent
`claim_reward` call — see §2's Step 5b) is never shown to the client as redeemable; the next
`claim_reward` call is what actually voids it and allocates a fresh one.

**Third hardening pass:** a fifth field, `issued_reward_needs_refresh` (boolean), is now ALWAYS
present (never omitted) — see §7d for the full client-safe-recovery-signal design this closes a
real user-facing bug for, and §0c issue 1 for the bug itself.

## 7. Paid-referral qualification after a free reward month

**The problem:** redeeming a free reward month must never itself count as a "qualified paid
referral" for whoever referred the redeemer (rule: a free month is not a paid conversion). But if
that redeemer had *already* applied someone else's referral code *before ever subscribing*, and
their free month later auto-renews for real money, that first real paid renewal *should* be
allowed to qualify the referrer's attribution — otherwise it can never qualify at all, since only
`INITIAL_PURCHASE` triggered qualification before this feature, and a RENEWAL is never a fresh
`INITIAL_PURCHASE`.

**The loophole this must not create:** simply allowing "any RENEWAL with a pending attribution
applied before the renewal" to qualify would let someone become a real, unrelated Pro subscriber
first, then apply a referral code *afterward*, and have their next ordinary renewal incorrectly
qualify that late code application.

**The fix:** `isReferralQualifyingEvent`/the new `isReferralRenewalQualificationCandidate` (both in
`referral-classification.ts`) exclude any event carrying a referral-reward offer code. Separately,
`_shared/database.ts`'s `applyReferralAction` — before ever calling the existing, unmodified
`process_referral_subscription_event` for a RENEWAL-triggered qualify attempt — checks whether
`private.referral_reward_offer_codes` has a **redeemed** row whose
`redemption_original_transaction_id` matches this RENEWAL's `original_transaction_id`. That row can
only exist if this exact subscription's original purchase was genuinely fulfilled through one of
our own dedicated referral-reward offers (a fact only our own webhook fulfillment ever records —
not spoofable by a client). If no such row exists, the RENEWAL is a safe no-op; the general
loophole is closed because an unrelated, ordinarily-purchased subscription never has a matching
row. A refund of that later-qualifying paid transaction still reverses correctly through the
existing, untouched refund machinery (it operates on `original_transaction_id`, independent of
which event type originally qualified it).

## 7a. Environment isolation design (hardening pass)

**The requirement:** a SANDBOX Apple code must never fulfill/consume a real PRODUCTION-earned
reward, a PRODUCTION code must never be returned to a SANDBOX test claim, code pools must not mix
environments, webhook fulfillment must require an exact environment match, the production system
must remain production-authoritative, and it must still be possible to test the complete
claim → redeem → webhook-fulfillment flow using Apple's own Sandbox codes before release.

**Why tagging the code pool alone is not enough:** `private.claim_referral_reward` always operates
by picking "the oldest eligible `earned` reward" for a participant. Without an `environment` tag on
the REWARD row itself, there would be no way to distinguish a genuine PRODUCTION reward from an
operator-seeded SANDBOX test reward on the very same participant — and pre-release verification of
this feature necessarily requires SOME reward row that exists through a path other than the real,
PRODUCTION-only qualification pipeline (see below). A SANDBOX-environment claim could then attach a
SANDBOX Apple code to what is, structurally, an untagged (and therefore ambiguous) reward — exactly
the cross-contamination this design exists to prevent. Tagging only the code pool answers "which
code" but leaves "which reward" open, and the reward is the thing with real value, not the code.

**The design actually implemented:** both `private.referral_rewards` and
`private.referral_reward_offer_codes` carry `environment` (`SANDBOX`/`PRODUCTION`, `NOT NULL`).
`claim_referral_reward` takes `p_environment` and requires it to match on both the reward selection
and the code allocation. `fulfill_referral_reward_offer_code` takes the webhook event's own
`environment` (previously hardcoded to reject anything but `'PRODUCTION'`; now accepts either, per
the TypeScript classifier's relaxed gate) and requires it to match the CODE's own `environment`
column exactly, both on the idempotency check and on the "outstanding issued code" lookup. The
partial unique index that enforces "one outstanding issued code per participant" is now scoped to
`(referrer_participant_id, environment)`, so a dedicated SANDBOX test participant's one legitimate
test claim can never collide with an unrelated PRODUCTION row (or vice versa) even in the
already-unlikely case of one participant somehow holding both.

**Backend-authoritative environment resolution (SECOND hardening pass — see §0b issue 2):**
`referral-api/index.ts`'s `authenticateInstallation` derives the caller's environment from THIS
installation's own `current_environment` column on `private.referral_client_installations` — never
a client-supplied value (the request carries no such field), and never a scan of every alias the
underlying participant has ever accumulated. This replaces the first hardening pass's own
`resolveClaimEnvironment`, which scanned `private.referral_participant_aliases` and let PRODUCTION
win whenever both existed — backwards for a participant/installation that is CURRENTLY, genuinely
bootstrapped as SANDBOX but happens to also carry an older PRODUCTION alias (e.g. from a prior
build/reinstall). `current_environment` is written on EVERY successful bootstrap call (new
installation or idempotent repeat) with that exact request's own `revenuecat_environment` value, so
it always reflects the MOST RECENT bootstrap, never a historical aggregate. An installation whose
`current_environment` is somehow unresolvable (unreachable in practice — every installation row that
can pass the credential check was created by a successful bootstrap, which always records this in
the SAME transaction) fails the request closed with `environment_unresolvable` rather than guessing.

**How a SANDBOX test reward is created at all:** never through the real qualification pipeline
(`process_referral_subscription_event` is PRODUCTION-only by construction, unchanged). An operator
seeds one directly — `insert into private.referral_rewards (referrer_participant_id,
milestone_number, environment) values (..., 'SANDBOX')` — for a dedicated test participant
bootstrapped with a SANDBOX RevenueCat identity, then imports SANDBOX-tagged Apple codes (real
codes generated for Sandbox testing in App Store Connect) into the pool the same way. This lets
deployment step 11 (Sandbox/TestFlight end-to-end verification) exercise the real code paths —
`claim_reward`, the redemption URL, and webhook fulfillment — without ever touching a real
PRODUCTION reward.

**Alternative considered and rejected:** leaving `private.referral_rewards` untagged and relying
solely on the code pool's own `environment` plus operational discipline (always seed test data on
dedicated test participants, never real ones). Rejected because it is not STRUCTURALLY enforced —
it depends entirely on an operator never making a mistake, and the failure mode (a test code
silently attaching to, and permanently occupying, a real user's genuine reward) is exactly the kind
of thing a schema constraint should make impossible rather than merely discouraged. Tagging the
reward row costs one nullable-then-backfilled column addition and zero function-signature changes
to any pre-existing function (see §2) — cheap enough that the stronger guarantee was worth it.

**`loadStatusResponse` scoping (revised in the second hardening pass):** an earlier revision of this
document argued `loadStatusResponse` should be deliberately UNSCOPED by environment, reasoning that
a real PRODUCTION participant structurally never has a SANDBOX reward row. That reasoning missed the
exact scenario §0b issue 2 fixes: an installation CAN legitimately carry reward/code rows in more
than one environment over its lifetime (a dogfooding build later reinstalled from the real App
Store, or vice versa), and an unscoped query would then leak a stale, other-environment reward or
code into the CURRENT status response. `loadStatusResponse` now takes the caller's resolved
`current_environment` and filters both the reward-milestone rows and the issued-code lookup by it
(§3) — the Sandbox/TestFlight verification concern the earlier reasoning was protecting (seeing a
seeded SANDBOX test reward show up in status) is unaffected, since a dedicated SANDBOX test
participant's installation is itself bootstrapped as SANDBOX, so its own status calls resolve
`current_environment = 'SANDBOX'` and see exactly their own SANDBOX rows.

## 7b. Revoked-reward / issued-code consistency (first hardening pass — superseded by §7c)

**The original bug (first hardening pass):** a reward could transition `earned` → `revoked` (the
existing, unmodified milestone shrink logic in `process_referral_subscription_event`, triggered by a
refund) at ANY time — including after an Apple Offer Code had already been issued for it, because at
that time the REWARD row itself stayed `'earned'` for as long as the CODE was merely `'issued'`.
Left alone, that code would stay `status='issued'`, pointing at a reward that no longer justifies
it, until the user eventually redeemed it — at which point nothing would have told
`fulfill_referral_reward_offer_code` not to honor that redemption.

**The first hardening pass's fix, at two independent layers:** (1) a trigger,
`private.referral_rewards_void_issued_code_on_revoke`, that fired the instant a reward transitioned
`earned` → `revoked` and voided any code still `issued` for it; (2) `fulfill_referral_reward_offer_code`
locking and re-reading the associated reward before ever marking the code redeemed, refusing unless
the reward was genuinely `earned`.

**SUPERSEDED by the second hardening pass (§7c):** once the reward's own status became `'issued'`
the moment its code is issued (rather than staying `'earned'`), layer 1's own firing condition
(`earned` → `revoked` with a live issued code) can no longer occur by construction — a reward is
never `'earned'` while its code is `'issued'`. The trigger was removed entirely rather than left as
harmless-but-confusing dead code; layer 2's spirit survives as `fulfill_referral_reward_offer_code`
now requiring `status = 'issued'` (not `'earned'`) before ever marking a code redeemed. See §7c for
the current design and how its own defensive layer was independently verified.

## 7c. Reward state machine redesign (second hardening pass)

**The requirement:** `private.referral_rewards` gets a REAL three-state lifecycle —
`earned -> issued -> fulfilled` — with `revoked` applying only while there is no live (unexpired,
`status = 'issued'`) Apple code outstanding for that reward. An issued reward must not be revoked
merely because the referrer's qualified-referral count later drops while its code is still valid.
When an issued code expires unused, the reward must be revalidated against the CURRENT
qualified-referral count: still justified → back to `earned`, then a fresh code allocated in the
same call; no longer justified → `revoked` outright, no replacement.

**The design actually implemented:**
- `claim_referral_reward`'s final allocation step now updates BOTH rows together: the code
  `available -> issued` and the reward `earned -> issued`, in the same statement block — a code is
  never `issued` without its reward being `issued` too, and vice versa. This pairing invariant is
  what makes the milestone shrink logic's `status = 'earned'` scoping (unmodified,
  `process_referral_subscription_event`) automatically exclude every issued reward — there is
  nothing extra to teach that pre-existing, already-reviewed function.
- The function's FIRST step now looks for an existing `'issued'` reward (not `'earned'`) in the
  caller's environment. An unexpired match returns the same code as before (idempotency, unchanged
  behavior). An expired match is the new branch: the code is voided, then the reward's OWN milestone
  is revalidated against `count(*) from referral_attributions where status = 'qualified'` for that
  referrer — the identical `floor(count / 5)` formula the shrink/grow logic already uses. Still
  justified → `issued -> earned`, and the function falls through to allocate a fresh code in the
  SAME call (no second reward ever consumed). No longer justified → `issued -> revoked`
  (`revoke_reason = 'expired_unclaimed_below_milestone'`), returned as a new outcome,
  `expired_no_longer_qualified` — no replacement code is ever issued.
- `fulfill_referral_reward_offer_code` now requires the associated reward to be `status = 'issued'`
  (not `'earned'`) before ever marking a code redeemed — `reward_not_issued` replaces the first
  hardening pass's `reward_not_earned` as the refusal outcome for anything else.
- A new `BEFORE UPDATE` guard trigger, `private.referral_rewards_guard_transition`, makes the state
  machine a structural guarantee rather than a convention: `fulfilled` is permanently terminal;
  `fulfilled` may only ever be reached FROM `issued`; and — the core invariant this pass exists to
  enforce — a reward may never become `revoked` while it still has a live `issued` code. Every
  legitimate revocation path already guarantees this by construction (the shrink logic never touches
  `issued` rows; the expiration-revalidation branch above always voids the code BEFORE touching the
  reward), so this trigger is the belt-and-suspenders backstop, not the primary mechanism — replaces
  the first hardening pass's reactive `referral_rewards_void_issued_code_on_revoke` (§7b), whose own
  premise (an `earned` reward with a live issued code) can no longer occur.
- The baseline migration's `referral_rewards_status` CHECK constraint is widened to admit `'issued'`
  — a real gap only found by actually executing an `UPDATE ... SET status = 'issued'` against local
  Postgres (see §2).
- A new partial unique index, `referral_rewards_one_issued_per_referrer_environment`, mirrors the
  code pool's own outstanding-code index at the reward layer.

**Transaction-rollback hardening, the same pass:** `fulfill_referral_reward_offer_code`'s two final
`UPDATE` statements each check `GET DIAGNOSTICS ... row_count` and, on an unexpected zero-row
result, `RAISE EXCEPTION` instead of returning a typed outcome (the first hardening pass's own
`reward_update_failed` returned normally even though the Apple code had, by that point, already been
marked redeemed — a real one-time-use code silently consumed while reporting something that looked
like a safe, recoverable failure). Raising aborts the ENTIRE surrounding transaction — this
function's caller runs it inside the same transaction as the entitlement-mirror write (§3) — so an
already-succeeded code UPDATE is rolled back too if the reward UPDATE that follows it turns out to
be the one that fails. Verified with a forced-invariant-failure test, not just written: see §2 for
the exact methodology (two test-only copies of the function, each with one UPDATE's `WHERE` clause
deliberately mismatched) and its results.

**Why `earned_months_available`/`fulfilled_months`/next-milestone progress didn't need new backend
logic:** `earned_months_available` already counted only `status = 'earned'` rows, so an `'issued'`
reward is automatically excluded (it's surfaced separately via `issued_reward_*` fields, §6) with no
code change. `computeNextMilestoneProgress` (`_shared/referral-milestones.ts`) DID need one fix: its
"highest milestone ever reached" calculation now treats `'issued'` the same as `'earned'`/
`'fulfilled'` — otherwise an issued-but-not-yet-fulfilled milestone would incorrectly stop counting
as "reached," regressing the next-milestone target. Covered by a new Node test.

## 7d. Issued-reward reentry / expired-reward recovery (third hardening pass)

**The bug (§0c issue 1):** once `earned_months_available` correctly excludes an `issued` reward
(§7c/§0b issue 1), a client that gates its ENTIRE redemption entry point on
`earned_months_available > 0` alone loses that entry point the instant a claim succeeds — the exact
5-referral scenario: claim succeeds → reward `issued` → `earned_months_available` drops to 0 →
`issued_reward_code` is populated → but the UI never checked that field for VISIBILITY, only for
copy. A second, more serious form of the same bug: an issued code that EXPIRES before the client
ever calls `claim_reward` again produces `earned_months_available = 0 AND issued_reward_code =
null` — with literally no signal, every client entry point back into the redemption flow vanishes,
even though `claim_referral_reward` (§7c) already knows exactly how to recover this exact reward
(void the dead code, revalidate against the current qualified count, reissue or revoke). The reward
could become PERMANENTLY STRANDED — never fulfilled, never explicitly resolved — purely because the
client had no way to know it needed to ask again.

**The fix — a client-safe recovery signal, not a client-side decision:** `buildReferralStatusResponse`
(`_shared/referral-api-response.ts`) computes a new boolean, `issued_reward_needs_refresh`, purely
from data this response already assembles — `true` exactly when `input.rewards` contains a
`status = 'issued'` row AND `input.issuedRewardCode` is `null` (an issued reward with no live code).
No new query: `loadStatusResponse` already fetches both. No mutation: the status endpoint stays
strictly read-only — reading it never voids a code, revalidates a milestone, or changes any
`referral_rewards`/`referral_reward_offer_codes` row; only a `claim_reward` call does that (§7c).
Never exposes the expired code itself (`issued_reward_code` stays `null` in this case) or any
internal identifier. The client's only correct response to `true` is to call `claim_reward` again —
the SAME atomic operation as a normal claim; `private.claim_referral_reward` alone decides whether
that reissues a fresh code or revokes the reward outright, exactly as it already did before this
signal existed (§7c) — this fix adds a way to KNOW to ask, never a new way to decide the answer.

**iOS:** `ReferralPresentation.rewardCardState(earnedMonthsAvailable:issuedRewardCode:
issuedRewardNeedsRefresh:)` is the single decision function both `ReferEarnView`'s reward card and
`ReferralRewardRedemptionSheet`'s content switch on, returning one of three states (or `nil` for
"nothing to show"): `.earned(count:)` (the normal, pre-existing "go claim it" state),
`.issuedCode` (a live code exists — reopen the sheet to see/copy/redeem it, never re-claim), and
`.needsRefresh` (the code expired — the ONLY remaining way back to `claim_referral_reward`'s own
recovery logic is calling `claim_reward` again). Precedence is fixed and total: a live issued code
always wins (it is structurally the most specific, most actionable state), then `earned`, then
`needsRefresh`. The redemption sheet's `.needsRefresh` state shows a "Refresh Reward" action that
calls the IDENTICAL `ReferralManager.shared.claimReward(requestedProductID:)` a normal claim uses
(same plan-picker/active-subscriber branching when a plan choice is needed) — the sheet never
duplicates `claim_referral_reward`'s own reissue-vs-revoke decision; it only picks copy ("Refresh
Reward" vs. "Redeem Free Month") based on which state triggered the confirmation. After the
response: a `"claimed"` outcome re-renders from the backend's fresh status (a new code now
appears); any other outcome (including `expired_no_longer_qualified` — §7c) surfaces its existing
explanatory copy, now also shown in the "nothing to redeem" fallback state so a refresh attempt that
ends there isn't silently unexplained.

**Why this couldn't be caught by the second hardening pass's own tests:** every existing Swift
preview/test for the "reward code issued" state had `earnedMonthsAvailable: 1` alongside a
populated `issuedRewardCode` — a combination the real backend NEVER produces once rule 3's
`earned -> issued -> fulfilled` lifecycle is in effect (§7c), since `earned_months_available`
excludes `issued` rows by construction. That artificial combination happened to keep the
`earnedMonthsAvailable > 0` gate satisfied, masking the exact bug this pass fixes. The "Reward code
issued" preview is corrected to `earnedMonthsAvailable: 0` (the real post-claim state), and a new
"Reward needs refresh" preview models the expired-code state explicitly — see §11.

## 8. Files changed

**Migrations:** `supabase/migrations/20260928000000_referral_reward_redemption_foundation.sql` (new).

**Edge Functions / shared:**
`supabase/functions/referral-api/index.ts` (second hardening pass —
`authenticateInstallation`/`handleBootstrap`/`loadStatusResponse`/`handleClaimReward` rewired for
current-installation environment resolution; `resolveClaimEnvironment` removed),
`supabase/functions/revenuecat-webhook/index.ts`,
`supabase/functions/_shared/database.ts`,
`supabase/functions/_shared/referral-classification.ts`,
`supabase/functions/_shared/referral-api-env.ts`,
`supabase/functions/_shared/referral-api-validation.ts`,
`supabase/functions/_shared/referral-api-response.ts` (second hardening pass — comment only:
`'issued'` exclusion from `earned_months_available`; THIRD hardening pass — new
`issued_reward_needs_refresh` field/derivation, see §7d),
`supabase/functions/_shared/referral-milestones.ts` (second hardening pass — `'issued'` added to
`RewardMilestoneRow.status`; `computeNextMilestoneProgress` treats it like `earned`/`fulfilled`),
`supabase/functions/_shared/revenuecat-types.ts`,
`supabase/functions/_shared/referral-reward-offer-codes.ts` (new),
`supabase/functions/_shared/referral-active-product.ts` (new).

**Tests (Node, `_shared/*.test.ts`):**
`referral-reward-offer-codes.test.ts` (new), `referral-active-product.test.ts` (new),
`referral-classification.test.ts`, `referral-api-validation.test.ts`,
`referral-api-response.test.ts` (second hardening pass — new `'issued'`-exclusion case; THIRD
hardening pass — 4 new `issued_reward_needs_refresh` cases),
`referral-api-env.test.ts`,
`referral-milestones.test.ts` (second hardening pass — new `'issued'`-counts-as-reached case).

**iOS:**
`EightyFiveBlends/ReferralModels.swift` (second hardening pass — doc comments: new
`expired_no_longer_qualified` claim outcome, broadened `environmentUnresolvable` scope; THIRD
hardening pass — new `issuedRewardNeedsRefresh` field, and a new explicit `init(from:)` replacing
the synthesized Decodable conformance so a response missing this key still decodes it as `false`
rather than throwing — see §7d/§11),
`ReferralAPIService.swift`, `ReferralManager.swift` (second hardening pass — doc-comment-only
re-bootstrap verification note; no behavior change), `ReferralPresentation.swift` (second hardening
pass — new `claimStatusMessage` case for `expired_no_longer_qualified`; THIRD hardening pass — new
`RewardCardState` enum + `rewardCardState`/`rewardCardHeadline(for:)`/`rewardCardSubtitle(for:)`,
see §7d), `ReferEarnView.swift` (THIRD hardening pass — reward card now gates on `rewardCardState`
instead of `earnedMonthsAvailable > 0` alone; "Reward code issued" preview corrected, new "Reward
needs refresh" preview),
`ReviewRequestManager.swift` (new `AppStoreDestination.redeemOfferCode(_:)`),
`ReferralRewardRedemptionSheet.swift` (new — the real redemption UI; THIRD hardening pass — content
now switches on the same `rewardCardState`, new `.needsRefresh` "Refresh Reward" flow reusing the
identical `claimReward` call, `fulfilledOrNothingToRedeemSection` now surfaces a lingering
`claimMessage`),
`RevenueCatSubscriptionService.swift` (first hardening pass — new
`RevenueCatClient.syncPurchases()` + `syncAfterExternalRedemption()`), `SubscriptionManager.swift`
(first hardening pass — thin `syncAfterExternalRedemption()` wrapper).

**iOS tests:** `ReferralModelsTests.swift` (THIRD hardening pass — new
`issued_reward_needs_refresh` decode cases, including the critical missing-key-defaults-to-false
backward-compatibility case), `ReferralPresentationTests.swift` (second hardening pass — new
`expired_no_longer_qualified` cases; THIRD hardening pass — new `rewardCardState` test suite),
`ReferralManagerTests.swift`, `ReviewRequestManagerTests.swift`.

**Untouched, as scoped:** the Nearby E85 widget, station/ethanol reporting, Trip Planner, ads, the
general promo-campaign system (`20260921000000_promo_campaign_foundation.sql` remains unapplied and
untouched — this feature deliberately does not build on it, per its own header comment), the public
85BLENDS promo configuration, unrelated subscription/paywall UI, and the 2.4.0 What's New PR (#109).

## 9. Deployment order (NOT executed — documented for a future, separate deployment pass)

1. Create the three Apple referral Offer Code offers in App Store Connect (Monthly/3-Month/Annual),
   each entered under the offer's own **Reference Name** field using the values in §4.
2. Generate Sandbox test codes for each offer, for pre-release verification, and import them into
   `private.referral_reward_offer_codes` tagged `environment = 'SANDBOX'` (see §7a — never
   `'PRODUCTION'`, and never mixed into the same pool rows as real codes).
3. Verify each Sandbox offer's reference name → product mapping matches §4 exactly.
4. Apply this migration (`20260928000000_referral_reward_redemption_foundation.sql`) to production.
5. Verify grants/RLS on the new table and both new functions (service_role-only, zero
   anon/authenticated policies) — same verification style as
   `docs/PRE_RELEASE_SUPABASE_CHECKLIST.md`. Also verify the
   `referral_rewards_guard_transition` trigger exists and is enabled (§7c).
6. Deploy the updated `referral-api` function (with the two new `REVENUECAT_*` env vars set).
7. Deploy the updated `revenuecat-webhook` function.
8. Import production Apple one-time code pools into `private.referral_reward_offer_codes` securely
   (direct database access only — never through any client-facing path, never logged), tagged
   `environment = 'PRODUCTION'`.
9. Verify pool counts/expiry/product mapping in production before any user can claim.
10. Merge and ship the iOS client changes.
11. **Sandbox/TestFlight end-to-end verification (per §7a — this is the step the environment-
    isolation design exists to make safe):** seed one dedicated SANDBOX test participant
    (bootstrapped with a SANDBOX RevenueCat identity) and one operator-inserted
    `private.referral_rewards` row for them with `environment = 'SANDBOX'`. Exercise the full
    real flow against that participant only — `claim_reward` (confirm it returns a SANDBOX-tagged
    code from the pool seeded in step 2), the App Store Offer Code redemption URL, and webhook
    fulfillment (confirm `fulfill_referral_reward_offer_code` marks it `fulfilled`) — before any
    production Apple code is ever handed to a real user. Confirm in the same pass that this
    SANDBOX activity never reads or mutates any PRODUCTION-tagged reward or code row.
12. Confirm the RevenueCat webhook actually marks the SANDBOX test reward `fulfilled`.
13. Confirm entitlement updates correctly follow the Sandbox redemption, via
    `syncAfterExternalRedemption()` (§0 issue 4) on return to the app.
14. Only then consider this feature release-ready for real users.

**Replenishing codes:** monitor `private.referral_reward_offer_codes` per product for
`status = 'available'` counts approaching zero, and for `apple_expires_at` horizons — import a new
batch (step 8) before either runs out. There is no automatic reordering; this is an operational
task, matching how the existing Apple offer-code system itself works (codes are generated/exported
manually in App Store Connect).

## 10. Security review (Phase 12)

- **Service-role leakage:** the referral schema stays `private` (never in `[api].schemas`), RLS
  enabled with zero policies, and `service_role`-only grants on every new object — unchanged pattern
  from the rest of this backend.
- **Raw offer-code logging:** neither `referral-api/index.ts` nor `revenuecat-webhook/index.ts` logs
  `apple_code`/`offer_reference_name`/`product_id` — only safe outcome strings and masked
  participant IDs (see the new log lines in both files).
- **Analytics containing the Apple code:** nothing in this feature touches
  `AnalyticsEvent.swift`/the analytics pipeline at all; the raw code exists only in
  `ReferralStatus`/`ReferralClaimRewardResponse` and the redemption sheet's own local state.
- **Accidental PostgREST access:** `private.referral_reward_offer_codes` follows the exact
  revoke/RLS/zero-policy pattern already verified for every other `private.referral_*` table.
- **Code pool enumeration:** no endpoint ever lists available codes; `claim_reward` only ever
  returns the ONE code allocated to the calling participant's own reward.
- **Cross-participant claim:** `claim_referral_reward` takes `p_referrer_participant_id` from the
  server's own `authenticateInstallation` resolution — never client-supplied.
- **Double allocation:** `FOR UPDATE`/`FOR UPDATE SKIP LOCKED` row locking (participant row, then
  reward row, then code row) plus the partial-unique-index backstops make double allocation
  structurally rejected, not merely discouraged.
- **Race conditions:** locking order mirrors `process_referral_subscription_event`'s own
  (participant row first, then the specific resource) — no new lock-ordering deadlock introduced.
- **Replay:** fulfillment is keyed on `redemption_original_transaction_id`; a redelivered webhook
  event for an already-`redeemed` code is a clean no-op (the terminal-state trigger would reject a
  mutation attempt regardless).
- **Webhook spoof/cross-account match:** fulfillment identity resolution reuses the exact
  zero/one/many alias-set pattern already reviewed for `process_referral_subscription_event` — a
  multi-match is a fail-closed `identity_conflict`, never a guess.
- **Environment mismatch:** both `private.referral_rewards` and `private.referral_reward_offer_codes`
  carry `NOT NULL environment`; `claim_referral_reward` and `fulfill_referral_reward_offer_code` both
  require an exact environment match at every lookup (reward selection, existing-code check,
  outstanding-issued-code lookup, allocation). **Second hardening pass:** the caller's environment
  for every action is resolved server-side from THIS installation's own `current_environment`
  (`private.referral_client_installations`, written on every successful bootstrap) — never a
  client-supplied value, and never a scan of every alias the underlying participant has ever
  accumulated (the first hardening pass's own design, which could misclassify a currently-SANDBOX
  installation as PRODUCTION). See §7a for the full design and the alternative considered and
  rejected.
- **Reward state-machine integrity (second hardening pass):** `private.referral_rewards` now has a
  real `earned -> issued -> fulfilled` lifecycle, structurally guarded by
  `referral_rewards_guard_transition` (fulfilled is terminal, reachable only from issued; revoked is
  impossible while a live issued code exists) — not merely enforced by application-code discipline.
  See §7c.
- **Fulfillment partial-update integrity (second hardening pass):** an impossible zero-row result on
  either of `fulfill_referral_reward_offer_code`'s final UPDATEs now aborts the entire surrounding
  transaction (`RAISE EXCEPTION`, not a typed outcome) — a real one-time-use Apple code can never be
  left marked redeemed while the matching reward silently fails to transition. Proven with a forced-
  invariant-failure test (two test-only copies of the function with one UPDATE's WHERE clause
  deliberately mismatched), not merely written. See §2/§7c.
- **Expired-code allocation:** `apple_expires_at` is `NOT NULL` on every pooled code, so
  `claim_referral_reward`'s allocation query filters `apple_expires_at > now()` unconditionally —
  no "unknown expiration" row can ever exist to slip past the filter. An existing `issued` code
  that has since expired is atomically voided and replaced within the same claim call (§2 Step 5b)
  rather than left to block the reward.
- **Revoked-reward / issued-code consistency:** structurally impossible for a reward to be both
  `revoked` and paired with a live `issued` code — enforced by the `referral_rewards_guard_transition`
  trigger (second hardening pass), with `fulfill_referral_reward_offer_code` independently requiring
  `status = 'issued'` (not `'earned'`) before ever marking a code redeemed, verified via
  `GET DIAGNOSTICS` after its own UPDATE. See §7b/§7c.
- **External-redemption entitlement reconciliation (hardening pass):** the redemption sheet calls
  `Purchases.shared.syncPurchases()` (not `restorePurchases()`, no restore UI) through the same
  authoritative `SubscriptionManager`/`RevenueCatSubscriptionService` entitlement bridge already
  used elsewhere, and only when this sheet itself sent the user to the external App Store URL — a
  failure degrades to "confirmation pending," never a locally-asserted fulfilled state. See §0
  issue 4.
- **Client-supplied active-product spoofing:** `claim_reward` never trusts a client's own claim to
  be Pro or on a given plan — the active product is always freshly resolved server-side via
  RevenueCat (now environment-scoped — see above), and a lookup failure refuses the claim rather
  than falling back to a guess.
- **Terminology accuracy (hardening pass):** every reference to the three Apple Offer Code
  constants, in migration comments, `referral-reward-offer-codes.ts`, and this document, now
  correctly identifies them as App Store Connect Offer Code **Reference Names** — not a
  nonexistent separate "Offer Identifier" field. See §0 issue 1 and §4. This matters for security
  review specifically because a misconfigured field in App Store Connect would silently break
  webhook fulfillment matching in production with no client-visible error.
- **Recovery-signal read-only guarantee (third hardening pass):** `issued_reward_needs_refresh`
  (§7d) is computed purely from already-fetched data inside `buildReferralStatusResponse` — reading
  it (`status`/`bootstrap`/`apply_code`, none of which call `claim_reward`) never voids a code,
  revalidates a milestone, or writes to `referral_rewards`/`referral_reward_offer_codes`. It never
  exposes the expired code itself or any internal identifier; the only state it can influence is
  whether the CLIENT decides to call `claim_reward` again, and that call's own outcome is decided
  entirely server-side, exactly as before this signal existed.
- **Claim partial-update integrity (third hardening pass):** `claim_referral_reward`'s final
  code-issuance + reward earned -> issued pair (and its own expiration-revalidation transitions) now
  carry the SAME `GET DIAGNOSTICS` + `RAISE EXCEPTION` discipline §0b issue 3 added to
  `fulfill_referral_reward_offer_code` — an impossible zero-row result aborts the whole call rather
  than ever returning `'claimed'` on top of a partial mutation. Proven with a second dedicated
  forced-invariant-failure test. See §2/§7c.

Raw Apple codes are treated as sensitive credentials throughout — never stored in app source, never
logged, never in analytics, never reachable through anon/authenticated PostgREST, and returned only
to the authenticated installation they were assigned to.

## 11. What could not be verified in this environment

- **The migration's SQL was actually executed and verified**, against a real, temporary local
  Postgres 16 server (this container has the full server binaries, not just `psql`) replaying the
  entire existing migration chain — FOUR times (once before, once after the first hardening pass,
  once after the second, and once more, fully from a clean database, after this third hardening
  pass) — see §2 for exactly what was exercised, including all real bugs this process found and
  fixed (a column-ambiguity bug in the first pass; the `referral_rewards_status` CHECK constraint gap
  in the second), and the full scenario lists across all three passes (expiration replacement in both
  directions, revocation immunity while issued, requalification, a same-participant
  PRODUCTION/SANDBOX switch, status-response environment scoping, and TWO dedicated
  forced-invariant-failure tests proving the transaction-rollback mechanism in both
  `fulfill_referral_reward_offer_code` and `claim_referral_reward`, all exercised with real data via
  `psql`). What that local replay does **not** cover: genuine multi-connection concurrency (SKIP
  LOCKED behavior under two truly simultaneous claims, lock-ordering under load), RLS enforcement
  from an actual `anon`/`authenticated` role connection (grants were verified by reading them, not by
  attempting a live denied connection), and anything specific to Supabase's own connection
  pooler/transaction mode.
- **Correction to an earlier revision of this document:** an earlier revision said Deno-file testing
  was "entirely unavailable" in this environment, implying the `_shared/*.test.ts` suite was only
  written/reviewed, not actually run. That undersold what this environment can do: Node.js 22 is
  installed (`/opt/node22/bin/node`) with native TypeScript stripping, and `node --test
  supabase/functions/_shared/*.test.ts` directly executes the entire pure-TS, Deno-free `_shared`
  test suite for real — no transpile step, no Deno runtime needed for these files specifically.
  That run currently passes **352/352** (0 failing; 347 after the first hardening pass, 348 after the
  second, +4 new tests for `issued_reward_needs_refresh` added by this third pass). What genuinely
  remains unrun is narrower than the earlier claim: `referral-api/index.ts` and
  `revenuecat-webhook/index.ts` themselves (the HTTP handler entry points) and `database.ts` (which
  only runs under Deno's `npm:postgres` specifier) still require an actual Deno runtime, which is
  not available here — those three files remain static-review-only, including the second hardening
  pass's own `authenticateInstallation`/`handleBootstrap` rewrite. Every `_shared/*.ts` module they
  call into, including `referral-milestones.ts`'s `'issued'`-state handling,
  `referral-reward-offer-codes.ts`, `referral-active-product.ts`, and
  `referral-api-response.ts`'s `issued_reward_needs_refresh` derivation, was Node-executed.
- **No Xcode/xcodebuild/swift toolchain was available** — every Swift file in this PR, including
  `RevenueCatSubscriptionService.swift`'s new `syncPurchases()`/`syncAfterExternalRedemption()`, the
  redemption sheet's updated `scenePhase` handler, and this third hardening pass's own
  `ReferralPresentation.rewardCardState`/`ReferEarnView`/`ReferralRewardRedemptionSheet`/
  `ReferralStatus.init(from:)` changes, is static-review-only; nothing was compiled or run. New Swift
  Testing cases for `rewardCardState` and the new decode paths were written and carefully
  hand-traced against Swift's actual `Decodable`/enum semantics, but never compiled or executed — do
  not treat anything in this document as a claim of successful Swift compilation.
- **No real App Store Connect access** — the three Offer Code offers, their exact behavior for
  New/Existing/Expired subscribers, and the `apps.apple.com/redeem?ctx=offercodes&id=…&code=…`
  redemption URL format could not be opened/verified end-to-end against a live app. The URL format
  itself is Apple's well-established, documented Offer Code redemption link pattern, but Sandbox
  verification (deployment step 11) is the first point this can be confirmed for certain. Likewise,
  the corrected Reference-Name-only terminology (§0 issue 1, §4) is based on Apple's own documented
  Offer Code setup flow, not on having actually created an offer in a live App Store Connect account
  in this session.
- **No Sandbox RevenueCat/StoreKit environment was available** — the exact RevenueCat event
  type(s) an Offer Code redemption produces for an Existing/Expired subscriber (INITIAL_PURCHASE vs.
  RENEWAL vs. PRODUCT_CHANGE) could not be observed directly; fulfillment detection is deliberately
  event-type-independent (§7/§5) specifically so this doesn't matter, but this design choice itself
  is unverified against a real transaction. Likewise, `Purchases.shared.syncPurchases()`'s exact
  behavior and timing after a real external Offer Code redemption (§0 issue 4) is based on
  RevenueCat's own SDK source/changelog documentation, not an observed live call in this
  environment.
- **47 backend test scenarios, 18 iOS test scenarios** were specified across the original PR and all
  three hardening passes (28 original + 5 from the first pass + 8 from the second + 6 from this
  third pass's own required-tests list: issued-reward-with-live-code, expired-issued-code,
  wrong-environment-never-triggers-refresh, claim-from-needs-refresh-still-qualified,
  claim-from-needs-refresh-no-longer-qualified, and the claim-issuance transaction-rollback
  invariant). All are backed by new or updated Node/Swift Testing unit tests in this PR (pure
  classification, validation, response-shape, card-state-decision, and manager-level logic —
  352/352 Node tests passing, see above), and every SQL-level scenario among them — across all three
  hardening passes — was additionally exercised directly against a local Postgres replay:
  qualification counts, claim issuance and idempotency, legacy-product/invalid-product safe failure,
  fulfillment matching/rejection/idempotency, code void-and-replacement, terminal-state enforcement,
  expired-issued-code replacement in both directions (still-qualified and no-longer-qualified),
  revoke-immunity while issued, requalification after revocation, sandbox/production isolation at
  both the claim and fulfillment layers including a same-participant multi-environment case,
  status-response environment scoping, and TWO forced-invariant-violation-forces-full-rollback
  behaviors (fulfillment and claim issuance, via two dedicated forced-failure tests, §2). What
  remains genuinely unverified even after all four replays: TRUE multi-connection concurrent claims
  (one code total under a real race, not just sequential calls), and anything requiring an actual
  `anon`/`authenticated` Postgres role connection to prove RLS denial rather than reading the grants.
