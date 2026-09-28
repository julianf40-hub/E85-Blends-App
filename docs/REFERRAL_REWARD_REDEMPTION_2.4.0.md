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

One new file: `supabase/migrations/20260928000000_referral_reward_redemption_foundation.sql`.

**Verified via a real local Postgres 16 replay** (this container has full `postgres`/`initdb`
server binaries, not just the `psql` client) — applied the ENTIRE existing migration chain in
order (skipping only the one pre-existing, unrelated migration that requires the `pg_cron`
extension, which this sandbox doesn't have installed), then this new migration, then exercised
both new functions directly with real data: 5 and then 10 qualifying referrals producing the
expected earned reward(s); `claim_referral_reward` issuing a code and returning the identical code
on a repeat call; `fulfill_referral_reward_offer_code` rejecting a wrong participant/SANDBOX
environment/mismatched offer reference, then correctly fulfilling on an exact match, then treating
a redelivered webhook as an idempotent no-op; the terminal-state trigger rejecting an attempt to
revert a `redeemed` or `void` code; an active subscriber on the legacy quarterly product and a free
user requesting an unsupported product both failing safely without touching the reward; and a
voided issued code correctly leaving its reward `earned` and able to receive a fresh code on the
next claim, never consuming a second reward. This replay caught and fixed one real bug before it
ever reached this PR: three `where`/`order by` clauses referenced `reward_id`/`milestone_number`/
`product_id`/`apple_expires_at`/`referrer_participant_id` unqualified, which PL/pgSQL treated as
ambiguous against those same names appearing as this function's own `RETURNS TABLE` columns
("column reference ... is ambiguous") — fixed by table-qualifying every reference in both new
functions. This is real, executed verification, not a static read-through — see §11 for what
still could not be verified even with this replay (App Store Connect / Sandbox / RevenueCat
specifics).

**Zero changes to any existing migration or function** — in particular,
`private.process_referral_subscription_event` (the existing qualification/refund function) is
**not modified**. The one new qualification-timing rule this feature needs (a RENEWAL may qualify
a still-pending attribution only if it followed one of our own free reward months) is enforced in
TypeScript (`_shared/database.ts`), as an extra check performed **before** that existing function
is ever called — see §7 below.

New objects:

- `private.referral_reward_offer_codes` — the Apple one-time-use code pool. RLS enabled, zero
  policies, `service_role`-only grants (no DELETE, even for service_role — a depleted pool is
  replenished by inserting fresh rows, never by deleting history). Key constraints:
  - `apple_code` UNIQUE.
  - `product_id` restricted to the three shipping products.
  - `offer_reference_name` restricted to the three dedicated referral-reward offers, and a CHECK
    permanently pairs each reference with its own product (mismatched pairs are rejected at the
    database level, not just in application code).
  - A partial unique index enforces "a reward owns at most one live (issued/redeemed) code."
  - A partial unique index enforces "a participant has at most one outstanding **issued** code at a
    time" — the non-negotiable business rule that keeps webhook fulfillment matching unambiguous.
  - A `BEFORE UPDATE` trigger makes `redeemed`/`void` terminal states and forbids any code
    returning to `available` once issued.
- `private.claim_referral_reward(...)` — the one atomic claim operation (see §4).
- `private.fulfill_referral_reward_offer_code(...)` — the one atomic fulfillment operation (see
  §7).

## 3. Edge Function / webhook changes

**`supabase/functions/referral-api`** — new `claim_reward` action:
- Authenticates with the exact same installation-secret model as `bootstrap`/`status`/`apply_code`.
- Resolves the participant's PRODUCTION RevenueCat identity/identities from
  `private.referral_participant_aliases` and calls the existing `fetchCustomerSubscriptions` REST
  client (same one `revenuecat-webhook` already uses) to determine, backend-authoritatively,
  whether the participant is an active Pro subscriber and which product they're on
  (`_shared/referral-active-product.ts`, new — deliberately a separate file from `entitlement.ts`,
  which stays untouched).
- If the RevenueCat lookup itself fails, the claim is refused (`revenuecat_lookup_failed`) rather
  than guessing — never lets an active subscriber be misrouted through the "choose any plan" path
  because of a transient failure.
- Calls `private.claim_referral_reward(...)` and returns a safe payload: claim outcome, which
  milestone it concerned, and the full (already-updated) referral status — which now also carries
  the issued code's product/offer reference/raw code/expiration when one exists (see §6).
- New required env vars: `REVENUECAT_PROJECT_ID`, `REVENUECAT_V2_SECRET_API_KEY` (same values
  `revenuecat-webhook` already uses).

**`supabase/functions/revenuecat-webhook`** — new fulfillment detection, checked on every "normal"
parsed event (any type — see §7 for why): if the event carries one of the three dedicated referral
reward offer references, `private.fulfill_referral_reward_offer_code(...)` runs inside the SAME
transaction as the existing entitlement-mirror write. A fulfillment candidate is never gated on
`isReferralRelevantEventType` — a RENEWAL can be simultaneously "not itself a qualifying event" and
"exactly the event fulfillment exists to detect."

**`supabase/functions/_shared`** — new files: `referral-reward-offer-codes.ts` (offer reference
constants + classification), `referral-active-product.ts` (active-product resolution). Extended:
`referral-classification.ts` (offer-code exclusion, RENEWAL qualification candidate — see §7),
`database.ts` (the reward-redemption-proof gate + the new fulfillment call path),
`revenuecat-types.ts` (`product_id` field), `referral-api-env.ts`/`-validation.ts`/`-response.ts`
(the new action's config/request/response shapes).

## 4. Apple Offer Code lifecycle

Three dedicated Apple subscription Offer Codes, one per shipping plan — **never** the public
85BLENDS launch promotion, and never a general promo-campaign system:

| Plan | Offer Identifier (App Store Connect) | Product |
|---|---|---|
| Monthly | `REFERRAL_REWARD_MONTHLY_1M_FREE` | `com.85blends.subscription.monthly` |
| 3 Months | `REFERRAL_REWARD_3MONTH_1M_FREE` | `com.85blends.subscription.threemonth` |
| Annual | `REFERRAL_REWARD_ANNUAL_1M_FREE` | `com.85blends.subscription.annual` |

Each: 1 month free, eligible for New/Existing/Expired subscribers, auto-renews at the product's
normal price unless cancelled. **Terminology note:** "Offer Identifier" above is App Store
Connect's *developer-facing* field — the value actually communicated through StoreKit/RevenueCat
(RevenueCat's webhook `offer_code` field). This is **not** the same as App Store Connect's
separate, *internal-only* "Reference Name" field, which Apple never exposes to StoreKit,
RevenueCat, or any webhook. Every one of the three values above must be entered as the **Offer
Identifier**, not the Reference Name — using the wrong field silently breaks fulfillment matching
in production with no client-visible error.

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
redemption UI).

**iOS tests:** `ReferralModelsTests.swift`, `ReferralPresentationTests.swift`,
`ReferralManagerTests.swift`, `ReviewRequestManagerTests.swift`.

**Untouched, as scoped:** the Nearby E85 widget, station/ethanol reporting, Trip Planner, ads, the
general promo-campaign system (`20260921000000_promo_campaign_foundation.sql` remains unapplied and
untouched — this feature deliberately does not build on it, per its own header comment), the public
85BLENDS promo configuration, unrelated subscription/paywall UI, and the 2.4.0 What's New PR (#109).

## 9. Deployment order (NOT executed — documented for a future, separate deployment pass)

1. Create the three Apple referral Offer Code offers in App Store Connect (Monthly/3-Month/Annual),
   each using the **Offer Identifier** values in §4 (not the internal-only Reference Name).
2. Generate Sandbox test codes for each offer, for pre-release verification.
3. Verify each Sandbox offer's reference name → product mapping matches §4 exactly.
4. Apply this migration (`20260928000000_referral_reward_redemption_foundation.sql`) to production.
5. Verify grants/RLS on the new table and both new functions (service_role-only, zero
   anon/authenticated policies) — same verification style as
   `docs/PRE_RELEASE_SUPABASE_CHECKLIST.md`.
6. Deploy the updated `referral-api` function (with the two new `REVENUECAT_*` env vars set).
7. Deploy the updated `revenuecat-webhook` function.
8. Import production Apple one-time code pools into `private.referral_reward_offer_codes` securely
   (direct database access only — never through any client-facing path, never logged).
9. Verify pool counts/expiry/product mapping in production before any user can claim.
10. Merge and ship the iOS client changes.
11. Test Sandbox/TestFlight redemption end-to-end (claim → App Store redemption → webhook
    fulfillment) before any production Apple code is ever handed to a real user.
12. Confirm the RevenueCat webhook actually marks a test reward `fulfilled` in Sandbox.
13. Confirm entitlement updates correctly follow a Sandbox redemption.
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
- **Environment mismatch:** fulfillment is PRODUCTION-only by explicit check (a reward can only ever
  originate from a PRODUCTION-qualified referral, so this is not merely defensive).
- **Expired-code allocation:** `claim_referral_reward`'s allocation query explicitly filters
  `apple_expires_at is null or apple_expires_at > now()`.
- **Client-supplied active-product spoofing:** `claim_reward` never trusts a client's own claim to
  be Pro or on a given plan — the active product is always freshly resolved server-side via
  RevenueCat, and a lookup failure refuses the claim rather than falling back to a guess.

Raw Apple codes are treated as sensitive credentials throughout — never stored in app source, never
logged, never in analytics, never reachable through anon/authenticated PostgREST, and returned only
to the authenticated installation they were assigned to.

## 11. What could not be verified in this environment

- **The migration's SQL was actually executed and verified**, against a real, temporary local
  Postgres 16 server (this container has the full server binaries, not just `psql`) replaying the
  entire existing migration chain — see §2 for exactly what was exercised, including the one real
  bug this found and fixed. What that local replay does **not** cover: genuine multi-connection
  concurrency (SKIP LOCKED behavior under two truly simultaneous claims, lock-ordering under load),
  RLS enforcement from an actual `anon`/`authenticated` role connection (grants were verified by
  reading them, not by attempting a live denied connection), and anything specific to Supabase's own
  connection pooler/transaction mode.
- **No Deno runtime was available** — `referral-api/index.ts` and `revenuecat-webhook/index.ts`
  (and `database.ts`, which only runs under Deno's `npm:postgres` specifier) are static-review-only;
  only the pure, Deno-free `_shared/*.ts` modules were actually Node-tested (via their `.test.ts`
  files) in this environment.
- **No Xcode/xcodebuild/swift toolchain was available** — every Swift file in this PR is
  static-review-only; nothing was compiled or run.
- **No real App Store Connect access** — the three Offer Code offers, their exact behavior for
  New/Existing/Expired subscribers, and the `apps.apple.com/redeem?ctx=offercodes&id=…&code=…`
  redemption URL format could not be opened/verified end-to-end against a live app. The URL format
  itself is Apple's well-established, documented Offer Code redemption link pattern, but Sandbox
  verification (deployment step 11) is the first point this can be confirmed for certain.
- **No Sandbox RevenueCat/StoreKit environment was available** — the exact RevenueCat event
  type(s) an Offer Code redemption produces for an Existing/Expired subscriber (INITIAL_PURCHASE vs.
  RENEWAL vs. PRODUCT_CHANGE) could not be observed directly; fulfillment detection is deliberately
  event-type-independent (§7/§5) specifically so this doesn't matter, but this design choice itself
  is unverified against a real transaction.
- **28 backend test scenarios, 12 iOS test scenarios** were specified. Nineteen are backed by new or
  updated Node/Swift Testing unit tests in this PR (pure classification, validation, response-shape,
  and manager-level logic), and roughly a dozen of the SQL-level scenarios were additionally
  exercised directly against the local Postgres replay above (qualification counts, claim issuance
  and idempotency, legacy-product/invalid-product safe failure, fulfillment matching/rejection/
  idempotency, code void-and-replacement, terminal-state enforcement). What remains genuinely
  unverified even after that replay: TRUE multi-connection concurrent claims (one code total under
  a real race, not just sequential calls), and anything requiring an actual `anon`/`authenticated`
  Postgres role connection to prove RLS denial rather than reading the grants.
