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

**Verified via a real local Postgres 16 replay, TWICE** (this container has full `postgres`/`initdb`
server binaries, not just the `psql` client) — once against the first revision of this PR, and
again, fully from a clean database, against this hardened revision. Both replays applied the
ENTIRE existing migration chain in order (skipping only the one pre-existing, unrelated migration
that requires the `pg_cron` extension, which this sandbox doesn't have installed), then this
migration. The first replay caught and fixed one real bug before it ever reached the original PR:
several `where`/`order by` clauses referenced `reward_id`/`milestone_number`/`product_id`/
`apple_expires_at`/`referrer_participant_id` unqualified, which PL/pgSQL treated as ambiguous
against those same names appearing as this function's own `RETURNS TABLE` columns ("column
reference ... is ambiguous") — fixed by table-qualifying every reference in both functions. (This
exact bug class — an unqualified column colliding with a `RETURNS TABLE` name — was independently
found by a prior, unrelated review of a DIFFERENT migration in this repo,
`20260921000000_promo_campaign_foundation.sql`, whose own `.test.ts` file documents it could only
be caught by a real Postgres instance, never a static text check; this feature's own local replay
is exactly that missing verification step, now actually performed.)

This revision's hardening-pass replay exercised, with real data, every one of the five fixes in
§0: 5 and 10 qualifying referrals producing the expected earned reward(s); `claim_referral_reward`
issuing a code and returning the identical code on a repeat call; an ALREADY-EXPIRED available code
correctly never allocated; an issued code backdated to expired correctly auto-voided on the next
claim, with the SAME reward staying `earned` and receiving a fresh code on that same call, never
consuming a second reward; a REAL refund (via the existing, unmodified `refund_reversal` action)
correctly revoking a reward that already had an issued code, with the new trigger automatically
voiding that code in the same transaction; a webhook against that now-void code correctly
no-op'ing; REFUND_REVERSED correctly restoring the reward to `earned`, with the next claim
allocating a genuinely fresh code; an artificially-forced inconsistent state (the trigger
temporarily disabled, to isolate the DEFENSIVE reward-status check in
`fulfill_referral_reward_offer_code` from the trigger that normally prevents this state from ever
occurring) correctly refused fulfillment (`reward_not_earned`) without ever marking the code
redeemed or the reward fulfilled; a dedicated SANDBOX test participant's claim only ever able to
receive a SANDBOX-tagged code, never touching an available PRODUCTION code for the same product; a
PRODUCTION-environment claim for that same participant finding no eligible reward at all (their
only reward is SANDBOX-tagged); a malformed/unknown environment value failing closed on both the
claim and fulfillment paths; and — isolated specifically from the alias-level identity check, using
a participant with BOTH a SANDBOX and a PRODUCTION alias — a PRODUCTION webhook event correctly
unable to fulfill that participant's SANDBOX-tagged issued code (proving the CODE-level environment
check works on its own, not merely as a side effect of alias-level identity resolution already
failing), while the matching SANDBOX webhook event correctly fulfilled it. Every scenario above
passed on the first attempt after this revision's edits. This is real, executed verification, not
a static read-through or a description of intended behavior — see §11 for what still could not be
verified even with this replay (App Store Connect / Sandbox / RevenueCat specifics, and genuine
multi-connection concurrency).

**Every pure `_shared/*.ts` Node test in this feature was also actually EXECUTED** (not merely
written) — `node --test supabase/functions/_shared/*.test.ts` runs cleanly under this container's
Node 22 (native TypeScript support, no transpile step needed): **347 tests, 347 passing, 0
failing**, across every shared module this feature touches or added. An earlier revision of this
document said Deno-file testing was entirely unavailable in this environment; that undersold what
Node 22 can actually execute here — corrected in this revision.

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
- `private.referral_rewards` (existing table, additive change — hardening pass) — new `environment`
  column, `NOT NULL`, defaulting to `'PRODUCTION'`. Every existing row (empty or not; this
  migration does not assume the table is empty live) is safely backfilled to `'PRODUCTION'` before
  the `NOT NULL` is applied, because every reward this schema has ever been able to create (via
  `process_referral_subscription_event`'s own PRODUCTION-only v1 scope lock) is unambiguously
  `'PRODUCTION'` — the existing, unmodified `INSERT` inside that function needs zero changes; it
  picks up the new column's default automatically. See §7 for the full design rationale, including
  why the REWARD row (not just the code pool) needed this tag.
- `private.referral_rewards_void_issued_code_on_revoke` (new trigger, hardening pass) — the moment
  a reward transitions `earned` → `revoked`, any code still `issued` for it is immediately voided.
  See §0/§7.
- `private.claim_referral_reward(...)` (new function, signature changed in the hardening pass to
  add `p_environment`, hardening pass) — the one atomic claim operation (see §4/§7a).
- `private.fulfill_referral_reward_offer_code(...)` (new function, hardened in place per §7a/§7b) —
  the one atomic fulfillment operation (see §5/§7b).

## 3. Edge Function / webhook changes

**`supabase/functions/referral-api`** — new `claim_reward` action:
- Authenticates with the exact same installation-secret model as `bootstrap`/`status`/`apply_code`.
- Resolves which environment (SANDBOX/PRODUCTION) this exact claim belongs to, backend-
  authoritatively, from this participant's own `private.referral_participant_aliases` rows (new
  `resolveClaimEnvironment` — hardening pass; see §7a). Refuses the request
  (`environment_unresolvable`) rather than guessing if no alias exists at all yet (unreachable in
  practice — a successful bootstrap always creates one).
- Resolves the participant's RevenueCat identity/identities IN THAT ENVIRONMENT from
  `private.referral_participant_aliases` and calls the existing `fetchCustomerSubscriptions` REST
  client (same one `revenuecat-webhook` already uses, now called with the resolved environment
  rather than a hardcoded `'production'`) to determine, backend-authoritatively, whether the
  participant is an active Pro subscriber and which product they're on
  (`_shared/referral-active-product.ts`, new — deliberately a separate file from `entitlement.ts`,
  which stays untouched).
- If the RevenueCat lookup itself fails, the claim is refused (`revenuecat_lookup_failed`) rather
  than guessing — never lets an active subscriber be misrouted through the "choose any plan" path
  because of a transient failure.
- Calls `private.claim_referral_reward(...)` (now also passing the resolved environment) and
  returns a safe payload: claim outcome, which milestone it concerned, and the full (already-
  updated) referral status — which now also carries the issued code's product/offer
  reference/raw code/expiration when one exists (see §6), excluding any code that has since
  expired.
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

**Backend-authoritative environment resolution for `claim_reward`:** `referral-api/index.ts`'s new
`resolveClaimEnvironment` derives the caller's environment from their OWN
`private.referral_participant_aliases` rows — never a client-supplied value (the request carries no
such field). A participant with any PRODUCTION alias is always treated as PRODUCTION, even if they
also carry older SANDBOX aliases; only a participant with SANDBOX aliases and no PRODUCTION alias
at all is treated as SANDBOX. A participant with no aliases at all (unreachable in practice — a
successful bootstrap always creates one) fails the request closed rather than guessing.

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

**Why `loadStatusResponse` (the client-facing status payload) was deliberately NOT scoped by
environment:** a real PRODUCTION participant structurally never has a SANDBOX reward row (see
above), so filtering there would be a no-op for every real user — and for the ONE case it would
actually change anything (a dedicated SANDBOX test participant), filtering it OUT would be actively
unhelpful: the whole point of Sandbox/TestFlight verification is to see the seeded test reward
show up in status exactly like a real one would. The two write paths that actually move state
(`claim_referral_reward`, `fulfill_referral_reward_offer_code`) are where cross-contamination is
structurally possible, and those are where the environment gate lives.

## 7b. Revoked-reward / issued-code consistency (hardening pass)

**The bug:** a reward can transition `earned` → `revoked` (the existing, unmodified milestone
shrink logic in `process_referral_subscription_event`, triggered by a refund) at ANY time —
including after an Apple Offer Code has already been issued for it. Left alone, that code would
stay `status='issued'`, pointing at a reward that no longer justifies it, until the user eventually
redeemed it — at which point nothing would have told `fulfill_referral_reward_offer_code` not to
honor that redemption.

**The fix, at two independent layers:**
1. A new trigger, `private.referral_rewards_void_issued_code_on_revoke`, fires the instant a reward
   transitions `earned` → `revoked` and immediately voids any code still `issued` for it, in the
   SAME transaction as the revocation. If the reward is later restored (`revoked` → `earned`, a
   `REFUND_REVERSED` requalification), the old code stays permanently void — Section 1's own
   `redeemed`/`void` terminal-state trigger already guarantees this — and the next
   `claim_referral_reward` call allocates a genuinely fresh code; no special-case code was needed
   for the restore direction.
2. `fulfill_referral_reward_offer_code` no longer trusts "the code is still `status='issued'`" as
   proof the reward is still valid. It now locks and re-reads the associated reward BEFORE ever
   marking the code redeemed, refuses to proceed unless the reward is genuinely `earned` (a
   `revoked` reward returns `reward_not_earned` and the code is never touched), and — after writing
   `status='fulfilled'` — verifies via `GET DIAGNOSTICS` that its own UPDATE actually affected a
   row before ever reporting success, rather than assuming it did.

Layer 2 is deliberately NOT redundant with layer 1: it was verified independently, by temporarily
disabling the trigger and forcing the exact inconsistent state layer 1 exists to prevent, then
confirming `fulfill_referral_reward_offer_code`'s own check still refused to fulfill it (see §2).
A future bug in the trigger, or an event ordering this migration didn't anticipate, can never be
the ONLY thing standing between a revoked reward and an incorrect fulfillment.

## 8. Files changed

**Migrations:** `supabase/migrations/20260928000000_referral_reward_redemption_foundation.sql` (new).

**Edge Functions / shared:**
`supabase/functions/referral-api/index.ts`,
`supabase/functions/revenuecat-webhook/index.ts`,
`supabase/functions/_shared/database.ts`,
`supabase/functions/_shared/referral-classification.ts`,
`supabase/functions/_shared/referral-api-env.ts`,
`supabase/functions/_shared/referral-api-validation.ts`,
`supabase/functions/_shared/referral-api-response.ts`,
`supabase/functions/_shared/revenuecat-types.ts`,
`supabase/functions/_shared/referral-reward-offer-codes.ts` (new),
`supabase/functions/_shared/referral-active-product.ts` (new).

**Tests (Node, `_shared/*.test.ts`):**
`referral-reward-offer-codes.test.ts` (new), `referral-active-product.test.ts` (new),
`referral-classification.test.ts`, `referral-api-validation.test.ts`,
`referral-api-response.test.ts`, `referral-api-env.test.ts`.

**iOS:**
`EightyFiveBlends/ReferralModels.swift`, `ReferralAPIService.swift`, `ReferralManager.swift`,
`ReferralPresentation.swift`, `ReferEarnView.swift`, `ReviewRequestManager.swift` (new
`AppStoreDestination.redeemOfferCode(_:)`), `ReferralRewardRedemptionSheet.swift` (new — the real
redemption UI), `RevenueCatSubscriptionService.swift` (hardening pass — new
`RevenueCatClient.syncPurchases()` + `syncAfterExternalRedemption()`), `SubscriptionManager.swift`
(hardening pass — thin `syncAfterExternalRedemption()` wrapper).

**iOS tests:** `ReferralModelsTests.swift`, `ReferralPresentationTests.swift`,
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
   `docs/PRE_RELEASE_SUPABASE_CHECKLIST.md`. Also verify the new
   `referral_rewards_void_issued_code_on_revoke` trigger exists and is enabled.
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
- **Environment mismatch (hardening pass):** both `private.referral_rewards` and
  `private.referral_reward_offer_codes` carry `NOT NULL environment`; `claim_referral_reward`
  and `fulfill_referral_reward_offer_code` both require an exact environment match at every
  lookup (reward selection, existing-code check, outstanding-issued-code lookup, allocation). The
  caller's environment for `claim_reward` is resolved server-side from the caller's own
  `referral_participant_aliases`, never client-supplied. See §7a for the full design and the
  alternative considered and rejected.
- **Expired-code allocation:** `apple_expires_at` is `NOT NULL` on every pooled code, so
  `claim_referral_reward`'s allocation query filters `apple_expires_at > now()` unconditionally —
  no "unknown expiration" row can ever exist to slip past the filter. An existing `issued` code
  that has since expired is atomically voided and replaced within the same claim call (§2 Step 5b)
  rather than left to block the reward.
- **Revoked-reward / issued-code consistency (hardening pass):** a reward revoked after its code
  was already issued can no longer result in a fulfillable code — enforced at two independent
  layers (a proactive trigger that voids the code the instant the reward is revoked, and a
  defensive re-check inside `fulfill_referral_reward_offer_code` that locks and re-reads the
  reward and refuses unless it is genuinely `earned`, verified via `GET DIAGNOSTICS` after its own
  UPDATE). See §7b.
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

Raw Apple codes are treated as sensitive credentials throughout — never stored in app source, never
logged, never in analytics, never reachable through anon/authenticated PostgREST, and returned only
to the authenticated installation they were assigned to.

## 11. What could not be verified in this environment

- **The migration's SQL was actually executed and verified**, against a real, temporary local
  Postgres 16 server (this container has the full server binaries, not just `psql`) replaying the
  entire existing migration chain — twice, once before and once after the hardening pass — see §2
  for exactly what was exercised, including the column-ambiguity bug this found and fixed, and the
  full hardening-pass scenario list (expiration replacement, revocation while issued, requalification
  after revocation, webhook against a revoked reward, sandbox/production isolation, all exercised
  with real data via `psql`). What that local replay does **not** cover: genuine multi-connection
  concurrency (SKIP LOCKED behavior under two truly simultaneous claims, lock-ordering under load),
  RLS enforcement from an actual `anon`/`authenticated` role connection (grants were verified by
  reading them, not by attempting a live denied connection), and anything specific to Supabase's own
  connection pooler/transaction mode.
- **Correction to an earlier revision of this document:** an earlier revision said Deno-file testing
  was "entirely unavailable" in this environment, implying the `_shared/*.test.ts` suite was only
  written/reviewed, not actually run. That undersold what this environment can do: Node.js 22 is
  installed (`/opt/node22/bin/node`) with native TypeScript stripping, and `node --test
  supabase/functions/_shared/*.test.ts` directly executes the entire pure-TS, Deno-free `_shared`
  test suite for real — no transpile step, no Deno runtime needed for these files specifically.
  That run currently passes **347/347** (0 failing), re-confirmed after the hardening-pass edits.
  What genuinely remains unrun is narrower than the earlier claim: `referral-api/index.ts` and
  `revenuecat-webhook/index.ts` themselves (the HTTP handler entry points) and `database.ts` (which
  only runs under Deno's `npm:postgres` specifier) still require an actual Deno runtime, which is
  not available here — those three files remain static-review-only. Every `_shared/*.ts` module
  they call into, including the new/changed `resolveClaimEnvironment`,
  `referral-reward-offer-codes.ts`, and `referral-active-product.ts` logic, was Node-executed.
- **No Xcode/xcodebuild/swift toolchain was available** — every Swift file in this PR, including
  `RevenueCatSubscriptionService.swift`'s new `syncPurchases()`/`syncAfterExternalRedemption()` and
  the redemption sheet's updated `scenePhase` handler, is static-review-only; nothing was compiled
  or run. Do not treat anything in this document as a claim of successful Swift compilation.
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
- **33 backend test scenarios, 12 iOS test scenarios** were specified across the original PR and
  this hardening pass (the original 28 backend scenarios plus 5 new ones from §0 issues 2, 3, and
  5's "required tests" lists). All are backed by new or updated Node/Swift Testing unit tests in
  this PR (pure classification, validation, response-shape, and manager-level logic — 347/347 Node
  tests passing, see above), and the SQL-level scenarios among them were additionally exercised
  directly against the local Postgres replay (qualification counts, claim issuance and idempotency,
  legacy-product/invalid-product safe failure, fulfillment matching/rejection/idempotency, code
  void-and-replacement, terminal-state enforcement, expired-issued-code replacement, revoke-while-
  issued auto-void, requalification after revocation, a revoked reward's code failing fulfillment,
  and sandbox/production isolation at both the claim and fulfillment layers). What remains
  genuinely unverified even after both replays: TRUE multi-connection concurrent claims (one code
  total under a real race, not just sequential calls), and anything requiring an actual
  `anon`/`authenticated` Postgres role connection to prove RLS denial rather than reading the
  grants.
