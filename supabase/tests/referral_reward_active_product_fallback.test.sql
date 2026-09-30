-- 85Blends 2.4.0 — Referral reward active-product fallback + reward state machine + webhook
-- fulfillment regression matrix.
--
-- WHAT THIS COVERS (every scenario RAISEs on any unexpected outcome; a clean run that reaches the
-- final \echo line is a full pass):
--   F1-F10  private.claim_referral_reward's webhook-history fallback (migrations 20260929230218 +
--           20260930090000): gating (active Pro AND NULL product only), no-evidence fails closed,
--           same-environment only in both directions + alias/event environment binding, processed
--           events only, event-type restriction, supported-product allowlist (legacy quarterly and
--           RevenueCat-internal ids never resolve), expired/malformed expiration evidence,
--           greatest expiration wins, cross-product tie at the greatest expiration fails closed
--           (same-product tie resolves), unrelated aliases never influence resolution.
--   U1-U3   (20260930090000, issue 1) a confidently RESOLVED unsupported product (legacy quarterly,
--           a RevenueCat-internal id, or a blank string) never enters the fallback: supported
--           webhook evidence cannot override it, the claim fails closed, reward untouched.
--   H1-H14  (20260930090000, issue 2) subscription-state reduction by original_transaction_id:
--           purchase->refund and renewal->refund invalidate a subscription whatever expiration its
--           earlier rows advertise; a later EXPIRATION invalidates; a valid newer subscription after
--           an invalidated older one resolves (even when the stale one has the later expiration);
--           insertion order is irrelevant (event_timestamp ordering) and identical timestamps
--           tie-break on received_at; a non-processed invalidating row still invalidates; a voluntary
--           cancellation / uncancellation keeps evidence; a REFUND_REVERSED after a refund stays
--           closed until the next processed purchase/renewal; the latest state within ONE
--           subscription wins over a longer expiration on its earlier row; PRODUCT_CHANGE is neutral;
--           evidence without original_transaction_id never counts; a newer NON-processed
--           purchase/renewal shadows the older processed one; an exact timestamp tie is won by the
--           invalidating event; a JSON-number expiration works; an owned lifecycle row with an
--           unreadable subscription identity shadows anything not strictly newer; an absurdly large
--           expiration fails closed without raising.
--   R1-R2   (20260930090000, issues 2+3 combined) the reduction runs over EVERY row of a touched
--           subscription: an invalidating row that is ambiguous, or that carries only another
--           participant's identity, still invalidates (it is never skipped in favour of the older
--           purchase); a subscription whose latest row belongs to another participant yields
--           nothing for the claimant and nothing for the other participant.
--   A1-A9   (20260930090000, issue 3) identity: ledger primary id, original_app_user_id and payload
--           aliases[] all resolve when bound to the SAME participant in the SAME environment;
--           multiple own aliases resolve; an alias bound only in the other environment never
--           resolves; identities bound to ANOTHER participant (in any of the three places) make the
--           event ambiguous and it is excluded (never a cross-participant grant), without poisoning
--           unambiguous evidence; identities are compared trimmed.
--   S8      idempotent re-claim through the fallback path returns the same live code.
--   S1-S7   claim state machine: Free-user plan selection x3 (+ legacy/internal ids rejected),
--           active-Pro mapping (requested product ignored; legacy active fails closed), idempotent
--           re-claim returns the same live code, one issued code per referrer per environment,
--           fulfilled/redeemed are terminal and a fulfilled reward is never re-claimable, expired
--           issued code is voided and replaced on the same reward (S6) or revoked when the
--           milestone is no longer justified (S6b), a refund reversal shrinks the qualified count
--           but never revokes a reward holding a live issued code (S7).
--   W1-W6   private.fulfill_referral_reward_offer_code: wrong offer reference (public launch promo),
--           wrong product, wrong environment and unknown/unbound user never fulfill; the correct
--           dedicated offer fulfills (code issued->redeemed, reward issued->fulfilled); a duplicate
--           delivery is idempotent (already_fulfilled, no state change).
--
-- HOW TO RUN (local replay only — never against production):
--   1. Replay supabase/migrations/*.sql in version order into a scratch Postgres 16+ database
--      (see supabase/tests/README.md; 20260918001657_price_alert_job_processor_cron.sql needs the
--      pg_cron extension and may be skipped locally — nothing here depends on it).
--   2. psql -v ON_ERROR_STOP=1 -d <scratch_db> -f supabase/tests/referral_reward_active_product_fallback.test.sql
--
-- DETERMINISM / SAFETY: the whole file runs inside one transaction that is ROLLED BACK at the end,
-- and every scenario is isolated with a SAVEPOINT, so it can be re-run repeatedly against the same
-- replayed database. All ids are synthetic fixtures (no production participant ids, codes or
-- credentials); no network access; the only time dependence is relative (`now() +/- interval`).
begin;
set search_path to pg_catalog, private, public;

-- Shared setup ----------------------------------------------------------------------------------
insert into private.referral_participants (id, installation_id, referral_code) values
  ('aaaaaaaa-0000-0000-0000-000000000001', gen_random_uuid(), 'FALLBKAA'),  -- P1 active Pro (fallback subject)
  ('aaaaaaaa-0000-0000-0000-000000000002', gen_random_uuid(), 'FALLBKAB'),  -- P2 free user
  ('aaaaaaaa-0000-0000-0000-000000000003', gen_random_uuid(), 'FALLBKAC'),  -- P3 unrelated
  ('aaaaaaaa-0000-0000-0000-000000000004', gen_random_uuid(), 'FALLBKAD');  -- P4 fulfilled-terminal subject

insert into private.referral_participant_aliases (app_user_id, environment, participant_id) values
  ('rc_p1',    'PRODUCTION', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('rc_p1_sb', 'SANDBOX',    'aaaaaaaa-0000-0000-0000-000000000001'),
  ('rc_p2',    'PRODUCTION', 'aaaaaaaa-0000-0000-0000-000000000002'),
  ('rc_p3',    'PRODUCTION', 'aaaaaaaa-0000-0000-0000-000000000003'),
  ('rc_p4',    'PRODUCTION', 'aaaaaaaa-0000-0000-0000-000000000004');

insert into private.referral_rewards (id, referrer_participant_id, milestone_number, environment) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 'PRODUCTION'),
  ('bbbbbbbb-0000-0000-0000-000000000011', 'aaaaaaaa-0000-0000-0000-000000000001', 2, 'SANDBOX'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000002', 1, 'PRODUCTION'),
  ('bbbbbbbb-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000004', 1, 'PRODUCTION');

insert into private.referral_reward_offer_codes (product_id, offer_reference_name, apple_code, apple_expires_at, environment) values
  ('com.85blends.subscription.monthly',    'REFERRAL_REWARD_MONTHLY_1M_FREE', 'PRODMON1', now() + interval '60 days', 'PRODUCTION'),
  ('com.85blends.subscription.monthly',    'REFERRAL_REWARD_MONTHLY_1M_FREE', 'PRODMON2', now() + interval '60 days', 'PRODUCTION'),
  ('com.85blends.subscription.threemonth', 'REFERRAL_REWARD_3MONTH_1M_FREE',  'PROD3MO1', now() + interval '60 days', 'PRODUCTION'),
  ('com.85blends.subscription.annual',     'REFERRAL_REWARD_ANNUAL_1M_FREE',  'PRODANN1', now() + interval '60 days', 'PRODUCTION'),
  ('com.85blends.subscription.monthly',    'REFERRAL_REWARD_MONTHLY_1M_FREE', 'SBOXMON1', now() + interval '60 days', 'SANDBOX');

-- helper: insert a processed webhook event carrying product/expiration evidence. Each event is its
-- own subscription (original_transaction_id derived from the event id) unless p_otx is given.
create or replace function pg_temp.evt(p_id text, p_type text, p_user text, p_env text, p_product text, p_exp_ms text, p_status text default 'processed', p_otx text default null)
returns void language sql as $$
  insert into private.revenuecat_webhook_events (event_id, event_type, app_user_id, environment, event_timestamp, payload_hash, raw_payload, processing_status, processed_at)
  values (p_id, p_type, p_user, p_env, now(), md5(p_id),
          jsonb_build_object('event', jsonb_build_object('product_id', p_product, 'expiration_at_ms', p_exp_ms,
                                                         'original_transaction_id', coalesce(p_otx, 'otx_' || p_id))),
          p_status, case when p_status = 'processed' then now() else null end);
$$;
-- helper: full lifecycle event — explicit subscription identity, event time (and optional distinct
-- received_at), cancel_reason, payload aliases[] and original_app_user_id. NULL fields are omitted
-- from the payload exactly as RevenueCat omits absent keys.
create or replace function pg_temp.evt_sub(
  p_id text, p_type text, p_user text, p_env text, p_product text, p_exp_ms text, p_otx text, p_ts timestamptz,
  p_cancel_reason text default null, p_aliases text[] default null, p_orig_user text default null,
  p_status text default 'processed', p_received timestamptz default null)
returns void language sql as $$
  insert into private.revenuecat_webhook_events (event_id, event_type, app_user_id, original_app_user_id, environment, event_timestamp, received_at, payload_hash, raw_payload, processing_status, processed_at)
  values (p_id, p_type, p_user, p_orig_user, p_env, p_ts, coalesce(p_received, p_ts), md5(p_id),
          jsonb_build_object('event', jsonb_strip_nulls(jsonb_build_object(
            'product_id', p_product, 'expiration_at_ms', p_exp_ms, 'original_transaction_id', p_otx,
            'cancel_reason', p_cancel_reason, 'aliases', to_jsonb(p_aliases)))),
          p_status, case when p_status = 'processed' then coalesce(p_received, p_ts) else null end);
$$;
create or replace function pg_temp.future_ms(days int) returns text language sql as $$
  select ((extract(epoch from now() + make_interval(days => days)) * 1000)::bigint)::text
$$;
create or replace function pg_temp.claim(p_participant uuid, p_env text, p_active boolean, p_product text, p_requested text)
returns text language plpgsql as $$
declare r record; begin
  select * into r from private.claim_referral_reward(p_participant, p_env, p_active, p_product, p_requested);
  return r.outcome || ':' || coalesce(r.product_id, '-');
end $$;

-- ============================================================================================
-- F1. Fallback runs ONLY when active Pro = true AND active product = NULL (see U1-U3 for the
--     resolved-but-unsupported case, which never enters the fallback since 20260930090000)
-- ============================================================================================
savepoint f1;
do $$ declare o text; begin
  perform pg_temp.evt('e_f1', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  -- active + confidently-known product: the passed product wins, evidence (monthly) is ignored
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, 'com.85blends.subscription.annual', null);
  if o <> 'claimed:com.85blends.subscription.annual' then raise exception 'F1a: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; begin
  perform pg_temp.evt('e_f1b', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(30));
  -- NOT active: requested product wins, evidence (annual) is ignored entirely
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', false, null, 'com.85blends.subscription.monthly');
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'F1b: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; begin
  perform pg_temp.evt('e_f1c', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.threemonth', pg_temp.future_ms(30));
  -- active + NULL product: fallback resolves from evidence
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, 'com.85blends.subscription.annual');
  if o <> 'claimed:com.85blends.subscription.threemonth' then raise exception 'F1c: %', o; end if;
end $$;
rollback to savepoint f1;

-- F2. active + NULL + no evidence -> fails closed, reward untouched, nothing issued
do $$ declare o text; st text; n int; begin
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, 'com.85blends.subscription.monthly');
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'F2: %', o; end if;
  select status into st from private.referral_rewards where id = 'bbbbbbbb-0000-0000-0000-000000000001';
  select count(*) into n from private.referral_reward_offer_codes where status = 'issued';
  if st <> 'earned' or n <> 0 then raise exception 'F2 state: % %', st, n; end if;
end $$;
rollback to savepoint f1;

-- F3. Same environment only (both directions)
do $$ declare o text; begin
  perform pg_temp.evt('e_f3', 'INITIAL_PURCHASE', 'rc_p1_sb', 'SANDBOX', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'F3a PROD consumed SANDBOX evidence: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; begin
  perform pg_temp.evt('e_f3b', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'SANDBOX', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'F3b SANDBOX consumed PROD evidence: %', o; end if;
  -- and the SANDBOX evidence on the SANDBOX alias DOES resolve the SANDBOX reward
  perform pg_temp.evt('e_f3c', 'INITIAL_PURCHASE', 'rc_p1_sb', 'SANDBOX', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'SANDBOX', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'F3c: %', o; end if;
end $$;
rollback to savepoint f1;
-- F3d. alias/event environment mismatch: event tagged PRODUCTION but on the SANDBOX-only alias
do $$ declare o text; begin
  perform pg_temp.evt('e_f3d', 'INITIAL_PURCHASE', 'rc_p1_sb', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'F3d: %', o; end if;
end $$;
rollback to savepoint f1;

-- F4. processed events only
do $$ declare o text; begin
  perform pg_temp.evt('e_f4a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30), 'received');
  perform pg_temp.evt('e_f4b', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual',  pg_temp.future_ms(30), 'error');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'F4: %', o; end if;
end $$;
rollback to savepoint f1;

-- F5. event types: unrelated types never count; INITIAL_PURCHASE and RENEWAL do
do $$ declare o text; begin
  perform pg_temp.evt('e_f5a', 'PRODUCT_CHANGE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  perform pg_temp.evt('e_f5b', 'EXPIRATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual',  pg_temp.future_ms(30));
  perform pg_temp.evt('e_f5c', 'BILLING_ISSUE',  'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual',  pg_temp.future_ms(30));
  perform pg_temp.evt('e_f5d', 'TEST',           'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual',  pg_temp.future_ms(30));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'F5 unrelated types: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; begin
  perform pg_temp.evt('e_f5e', 'RENEWAL', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(30));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.annual' then raise exception 'F5 RENEWAL: %', o; end if;
end $$;
rollback to savepoint f1;

-- F6. only supported shipping products (legacy quarterly / unrelated fail closed)
do $$ declare o text; begin
  perform pg_temp.evt('e_f6a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.quarterly', pg_temp.future_ms(30));
  perform pg_temp.evt('e_f6b', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'prod_internal_id_abc',               pg_temp.future_ms(30));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'F6: %', o; end if;
end $$;
rollback to savepoint f1;

-- F7. expired / malformed expiration evidence cannot be selected
do $$ declare o text; begin
  perform pg_temp.evt('e_f7a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', ((extract(epoch from now() - interval '1 day') * 1000)::bigint)::text);
  perform pg_temp.evt('e_f7b', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual',  'not-a-number');
  insert into private.revenuecat_webhook_events (event_id, event_type, app_user_id, environment, event_timestamp, payload_hash, raw_payload, processing_status, processed_at)
  values ('e_f7c', 'RENEWAL', 'rc_p1', 'PRODUCTION', now(), md5('e_f7c'), '{"event":{"product_id":"com.85blends.subscription.annual"}}'::jsonb, 'processed', now());
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'F7: %', o; end if;
end $$;
rollback to savepoint f1;

-- F8. greatest expiration wins
do $$ declare o text; begin
  perform pg_temp.evt('e_f8a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(10));
  perform pg_temp.evt('e_f8b', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual',  pg_temp.future_ms(300));
  perform pg_temp.evt('e_f8c', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.threemonth', pg_temp.future_ms(80));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.annual' then raise exception 'F8: %', o; end if;
end $$;
rollback to savepoint f1;

-- F9. tie at the greatest expiration across DISTINCT products fails closed; same product ties resolve
do $$ declare o text; t text; begin
  t := pg_temp.future_ms(90);
  perform pg_temp.evt('e_f9a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', t);
  perform pg_temp.evt('e_f9b', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual',  t);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'F9a tie did not fail closed: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; t text; begin
  t := pg_temp.future_ms(90);
  perform pg_temp.evt('e_f9c', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', t);
  perform pg_temp.evt('e_f9d', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', t);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'F9b same-product tie: %', o; end if;
end $$;
rollback to savepoint f1;

-- F10. unrelated aliases cannot influence resolution
do $$ declare o text; begin
  perform pg_temp.evt('e_f10a', 'INITIAL_PURCHASE', 'rc_p3',      'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300));
  perform pg_temp.evt('e_f10b', 'INITIAL_PURCHASE', 'rc_unknown', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'F10: %', o; end if;
end $$;
rollback to savepoint f1;

-- ============================================================================================
-- U. (issue 1) A confidently RESOLVED unsupported product never enters the fallback
-- ============================================================================================
-- U1. legacy quarterly resolved by RevenueCat + unexpired supported evidence -> fails closed
do $$ declare o text; st text; n int; begin
  perform pg_temp.evt('e_u1a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  perform pg_temp.evt('e_u1b', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual',  pg_temp.future_ms(300));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, 'com.85blends.subscription.quarterly', 'com.85blends.subscription.monthly');
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'U1: resolved quarterly was overridden by evidence: %', o; end if;
  select status into st from private.referral_rewards where id = 'bbbbbbbb-0000-0000-0000-000000000001';
  select count(*) into n from private.referral_reward_offer_codes where status = 'issued';
  if st <> 'earned' or n <> 0 then raise exception 'U1 state: % %', st, n; end if;
end $$;
rollback to savepoint f1;
-- U2. a resolved RevenueCat-internal / unknown id + supported evidence -> fails closed
do $$ declare o text; begin
  perform pg_temp.evt('e_u2', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, 'prod_internal_id_abc', null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'U2: %', o; end if;
end $$;
rollback to savepoint f1;
-- U3. only a literal NULL is "unresolved": a blank string is a resolved (unsupported) product
do $$ declare o text; begin
  perform pg_temp.evt('e_u3', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, '', null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'U3 blank: %', o; end if;
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'U3 NULL still falls back: %', o; end if;
end $$;
rollback to savepoint f1;

-- ============================================================================================
-- H. (issue 2) Subscription-state reduction: latest lifecycle event per original_transaction_id
-- ============================================================================================
-- H1. purchase -> support refund; the refunded annual (later expiration) must not outrank a valid
--     newer monthly; with no newer subscription the claim fails closed
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_h1a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h1', t0);
  perform pg_temp.evt_sub('e_h1b', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h1', t0 + interval '1 hour', 'CUSTOMER_SUPPORT');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H1a refunded purchase still resolved: %', o; end if;
  perform pg_temp.evt_sub('e_h1c', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(25), 'otx_h1m', t0 + interval '2 days');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'H1b stale annual outranked the live monthly: %', o; end if;
end $$;
rollback to savepoint f1;
-- H2. purchase -> renewal -> support refund (same subscription) fails closed; a valid newer
--     three-month subscription then resolves
do $$ declare o text; t0 timestamptz := now() - interval '40 days'; begin
  perform pg_temp.evt_sub('e_h2a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h2', t0);
  perform pg_temp.evt_sub('e_h2b', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(330), 'otx_h2', t0 + interval '30 days');
  perform pg_temp.evt_sub('e_h2c', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(330), 'otx_h2', t0 + interval '31 days', 'CUSTOMER_SUPPORT');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H2a refunded renewal still resolved: %', o; end if;
  perform pg_temp.evt_sub('e_h2d', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.threemonth', pg_temp.future_ms(80), 'otx_h2q', t0 + interval '35 days');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.threemonth' then raise exception 'H2b: %', o; end if;
end $$;
rollback to savepoint f1;
-- H3. older long-expiration product followed by EXPIRATION (payload expiration deliberately still in
--     the future: invalidation is by STATE, not by the timestamp check) -> only the newer sub counts
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_h3a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h3', t0);
  perform pg_temp.evt_sub('e_h3b', 'EXPIRATION',       'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h3', t0 + interval '1 day');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H3a expired subscription still resolved: %', o; end if;
  perform pg_temp.evt_sub('e_h3c', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(20), 'otx_h3m', t0 + interval '2 days');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'H3b: %', o; end if;
end $$;
rollback to savepoint f1;
-- H4. invalidation is per SUBSCRIPTION, not per product: a refunded annual does not block a newer,
--     distinct, valid annual subscription
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_h4a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h4_old', t0);
  perform pg_temp.evt_sub('e_h4b', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h4_old', t0 + interval '1 hour', 'CUSTOMER_SUPPORT');
  perform pg_temp.evt_sub('e_h4c', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(355), 'otx_h4_new', t0 + interval '3 days');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.annual' then raise exception 'H4: %', o; end if;
end $$;
rollback to savepoint f1;
-- H5. ordering: insertion order is irrelevant (event_timestamp decides); identical event_timestamp
--     tie-breaks on received_at; a NON-processed invalidating row still invalidates
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  -- refund inserted BEFORE the purchase it refunds
  perform pg_temp.evt_sub('e_h5b', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h5', t0 + interval '1 hour', 'CUSTOMER_SUPPORT');
  perform pg_temp.evt_sub('e_h5a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h5', t0);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H5a insertion order leaked: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  -- same event_timestamp: the later-received row (the refund) is the current state
  perform pg_temp.evt_sub('e_h5c', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h5t', t0, null, null, null, 'processed', t0);
  perform pg_temp.evt_sub('e_h5d', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h5t', t0, 'CUSTOMER_SUPPORT', null, null, 'processed', t0 + interval '1 minute');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H5b received_at tie-break: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  -- the refund row failed processing ('error'): it still counts as the latest state (fail closed)
  perform pg_temp.evt_sub('e_h5e', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h5e', t0);
  perform pg_temp.evt_sub('e_h5f', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h5e', t0 + interval '1 hour', 'CUSTOMER_SUPPORT', null, null, 'error');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H5c error-status refund ignored: %', o; end if;
end $$;
rollback to savepoint f1;
-- H6. a voluntary cancellation (auto-renew off) keeps evidence; an uncancellation after it too
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_h6a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(20), 'otx_h6', t0);
  perform pg_temp.evt_sub('e_h6b', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(20), 'otx_h6', t0 + interval '1 hour', 'UNSUBSCRIBE');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'H6a voluntary cancellation dropped evidence: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_h6c', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(20), 'otx_h6u', t0);
  perform pg_temp.evt_sub('e_h6d', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(20), 'otx_h6u', t0 + interval '1 hour', 'UNSUBSCRIBE');
  perform pg_temp.evt_sub('e_h6e', 'UNCANCELLATION',   'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(20), 'otx_h6u', t0 + interval '2 hours');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'H6b uncancellation: %', o; end if;
end $$;
rollback to savepoint f1;
-- H7. REFUND_REVERSED after a refund does NOT reopen evidence by itself (conservative: closed until
--     the next processed purchase/renewal on that subscription)
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_h7a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h7', t0);
  perform pg_temp.evt_sub('e_h7b', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h7', t0 + interval '1 hour', 'CUSTOMER_SUPPORT');
  perform pg_temp.evt_sub('e_h7c', 'REFUND_REVERSED',  'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h7', t0 + interval '2 hours');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H7 refund reversal reopened evidence: %', o; end if;
  perform pg_temp.evt_sub('e_h7d', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(360), 'otx_h7', t0 + interval '3 hours');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.annual' then raise exception 'H7b next renewal: %', o; end if;
end $$;
rollback to savepoint f1;
-- H8. within ONE subscription the latest state wins even when an earlier row advertises a later
--     expiration (annual -> monthly on the same original_transaction_id); PRODUCT_CHANGE is neutral
do $$ declare o text; t0 timestamptz := now() - interval '40 days'; begin
  perform pg_temp.evt_sub('e_h8a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual',  pg_temp.future_ms(300), 'otx_h8', t0);
  perform pg_temp.evt_sub('e_h8b', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(20),  'otx_h8', t0 + interval '30 days');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'H8a earlier longer-expiration row won: %', o; end if;
  perform pg_temp.evt_sub('e_h8c', 'PRODUCT_CHANGE',   'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(20),  'otx_h8', t0 + interval '31 days');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'H8b PRODUCT_CHANGE was not neutral: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; t0 timestamptz := now() - interval '40 days'; begin
  -- and the reverse direction: monthly -> annual on one subscription resolves annual
  perform pg_temp.evt_sub('e_h8d', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(20),  'otx_h8r', t0);
  perform pg_temp.evt_sub('e_h8e', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual',  pg_temp.future_ms(330), 'otx_h8r', t0 + interval '30 days');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.annual' then raise exception 'H8c: %', o; end if;
end $$;
rollback to savepoint f1;
-- H9. evidence without original_transaction_id (no subscription identity) never counts
do $$ declare o text; begin
  perform pg_temp.evt_sub('e_h9a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30), null, now() - interval '1 day');
  perform pg_temp.evt_sub('e_h9b', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30), '   ', now() - interval '1 day');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H9: %', o; end if;
end $$;
rollback to savepoint f1;
-- H10. a NEWER purchase/renewal row that is not `processed` shadows the older processed one (closed
--      until the next processed event on that subscription)
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_h10a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30), 'otx_h10', t0);
  perform pg_temp.evt_sub('e_h10b', 'RENEWAL',          'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(60), 'otx_h10', t0 + interval '1 day', null, null, null, 'error');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H10: %', o; end if;
end $$;
rollback to savepoint f1;
-- H11. exact tie on event_timestamp AND received_at: the invalidating event wins regardless of
--      event_id ordering (purchase id sorts after the refund id here)
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_h11z_purchase', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h11', t0, null, null, null, 'processed', t0);
  perform pg_temp.evt_sub('e_h11a_refund',   'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h11', t0, 'CUSTOMER_SUPPORT', null, null, 'processed', t0);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H11: %', o; end if;
end $$;
rollback to savepoint f1;
-- H12. expiration_at_ms stored as a JSON NUMBER (what RevenueCat actually sends) resolves
do $$ declare o text; begin
  insert into private.revenuecat_webhook_events (event_id, event_type, app_user_id, environment, event_timestamp, payload_hash, raw_payload, processing_status, processed_at)
  values ('e_h12', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', now() - interval '1 day', md5('e_h12'),
          jsonb_build_object('event', jsonb_build_object('product_id', 'com.85blends.subscription.monthly',
                                                         'expiration_at_ms', pg_temp.future_ms(30)::bigint,
                                                         'original_transaction_id', 'otx_h12')),
          'processed', now());
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'H12: %', o; end if;
end $$;
rollback to savepoint f1;
-- H13. an owned lifecycle row whose subscription identity is unreadable is UNKNOWN state: it shadows
--      every subscription not strictly newer than it; an older unknown row shadows nothing
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_h13a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h13', t0);
  perform pg_temp.evt_sub('e_h13b', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), null, t0 + interval '1 hour', 'CUSTOMER_SUPPORT');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H13a unknown-identity refund ignored: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_h13c', 'EXPIRATION',       'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), null, t0 - interval '1 day');
  perform pg_temp.evt_sub('e_h13d', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_h13n', t0);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.annual' then raise exception 'H13b older unknown row shadowed newer state: %', o; end if;
end $$;
rollback to savepoint f1;
-- H14. an absurdly large expiration fails closed with a typed outcome instead of raising
do $$ declare o text; begin
  perform pg_temp.evt('e_h14', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', '99999999999999999999');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'H14: %', o; end if;
end $$;
rollback to savepoint f1;

-- ============================================================================================
-- R. (issues 2+3) The reduction covers EVERY row of a touched subscription, whoever each row
--    belongs to; only the winning row is subject to ownership
-- ============================================================================================
-- R1. the refund row of the participant's own subscription is ambiguous (its aliases[] also names
--     another participant): it must still invalidate, never be skipped for the older purchase
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_r1a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_r1', t0);
  perform pg_temp.evt_sub('e_r1b', 'CANCELLATION',     'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_r1', t0 + interval '1 hour', 'CUSTOMER_SUPPORT', array['rc_p1', 'rc_p3']);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'R1a ambiguous refund was skipped: %', o; end if;
  perform pg_temp.evt_sub('e_r1c', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(25), 'otx_r1m', t0 + interval '2 days');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'R1b refunded annual outranked live monthly: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  -- same with an ambiguous EXPIRATION, and with a refund whose ledger primary id is the OTHER
  -- participant's (original_app_user_id ours) — both shapes still invalidate
  perform pg_temp.evt_sub('e_r1d', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_r1x', t0);
  perform pg_temp.evt_sub('e_r1e', 'EXPIRATION',       'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_r1x', t0 + interval '1 hour', null, array['rc_p1', 'rc_p3']);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'R1c ambiguous expiration was skipped: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_r1f', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_r1y', t0);
  perform pg_temp.evt_sub('e_r1g', 'CANCELLATION',     'rc_p3', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_r1y', t0 + interval '1 hour', 'CUSTOMER_SUPPORT', null, 'rc_p1');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'R1d foreign-primary refund was skipped: %', o; end if;
end $$;
rollback to savepoint f1;
-- R2. a subscription whose later rows carry ONLY another participant's identity: the claimant's
--     stale purchase row never resolves; the other participant gets nothing from it either
do $$ declare o text; o3 text; t0 timestamptz := now() - interval '10 days'; begin
  perform pg_temp.evt_sub('e_r2a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_r2', t0);
  perform pg_temp.evt_sub('e_r2b', 'RENEWAL',          'rc_p3', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(330), 'otx_r2', t0 + interval '1 day');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'R2a stale purchase resolved for P1: %', o; end if;
  perform pg_temp.evt_sub('e_r2c', 'CANCELLATION',     'rc_p3', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(330), 'otx_r2', t0 + interval '2 days', 'CUSTOMER_SUPPORT');
  perform pg_temp.evt_sub('e_r2d', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(25), 'otx_r2m', t0 + interval '3 days');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'R2b: %', o; end if;
  select r.outcome || ':' || coalesce(r.product_id, '-') into o3
  from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000003', 'PRODUCTION', true, null, null) r;
  if o3 like 'claimed:%' then raise exception 'R2c P3 was granted: %', o3; end if;
end $$;
rollback to savepoint f1;

-- ============================================================================================
-- A. (issue 3) Identity: every alias bound to the SAME participant in the SAME environment
-- ============================================================================================
savepoint a_setup;
insert into private.referral_participant_aliases (app_user_id, environment, participant_id) values
  ('rc_p1_alt', 'PRODUCTION', 'aaaaaaaa-0000-0000-0000-000000000001');
savepoint a1;
-- A1. secondary alias as the ledger primary id resolves
do $$ declare o text; begin
  perform pg_temp.evt('e_a1', 'INITIAL_PURCHASE', 'rc_p1_alt', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'A1: %', o; end if;
end $$;
rollback to savepoint a1;
-- A2. unregistered primary id, own alias as original_app_user_id resolves
do $$ declare o text; begin
  perform pg_temp.evt_sub('e_a2', 'INITIAL_PURCHASE', 'rc_new_device', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_a2', now() - interval '1 day', null, null, 'rc_p1');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.annual' then raise exception 'A2: %', o; end if;
end $$;
rollback to savepoint a1;
-- A3. unregistered primary id, own alias only inside payload aliases[] resolves
do $$ declare o text; begin
  perform pg_temp.evt_sub('e_a3', 'INITIAL_PURCHASE', 'rc_new_device', 'PRODUCTION', 'com.85blends.subscription.threemonth', pg_temp.future_ms(80), 'otx_a3', now() - interval '1 day', null, array['rc_new_device', 'rc_p1'], 'rc_other_original');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.threemonth' then raise exception 'A3: %', o; end if;
end $$;
rollback to savepoint a1;
-- A4. several identities all bound to the same participant are not a conflict
do $$ declare o text; begin
  perform pg_temp.evt_sub('e_a4', 'INITIAL_PURCHASE', 'rc_p1_alt', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30), 'otx_a4', now() - interval '1 day', null, array['rc_p1', 'rc_p1_alt'], 'rc_p1');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'A4: %', o; end if;
end $$;
rollback to savepoint a1;
-- A5. an alias bound to this participant ONLY in the other environment never resolves (both directions)
do $$ declare o text; begin
  perform pg_temp.evt_sub('e_a5a', 'INITIAL_PURCHASE', 'rc_new_device', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30), 'otx_a5a', now() - interval '1 day', null, array['rc_p1_sb'], 'rc_p1_sb');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'A5a SANDBOX alias resolved a PRODUCTION claim: %', o; end if;
  perform pg_temp.evt_sub('e_a5b', 'INITIAL_PURCHASE', 'rc_new_device', 'SANDBOX', 'com.85blends.subscription.monthly', pg_temp.future_ms(30), 'otx_a5b', now() - interval '1 day', null, array['rc_p1', 'rc_p1_alt'], 'rc_p1');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'SANDBOX', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'A5b PRODUCTION aliases resolved a SANDBOX claim: %', o; end if;
end $$;
rollback to savepoint a1;
-- A6. an identity bound to ANOTHER participant makes the event ambiguous -> excluded, never granted
do $$ declare o text; o3 text; begin
  perform pg_temp.evt_sub('e_a6a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30), 'otx_a6a', now() - interval '1 day', null, array['rc_p1', 'rc_p3']);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'A6a ambiguous event resolved for P1: %', o; end if;
  select r.outcome || ':' || coalesce(r.product_id, '-') into o3
  from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000003', 'PRODUCTION', true, null, null) r;
  if o3 like 'claimed:%' then raise exception 'A6a ambiguous event resolved for P3: %', o3; end if;
end $$;
rollback to savepoint a1;
do $$ declare o text; begin
  -- another participant's primary id with this participant's alias in the payload: still ambiguous
  perform pg_temp.evt_sub('e_a6b', 'INITIAL_PURCHASE', 'rc_p3', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_a6b', now() - interval '1 day', null, array['rc_p1']);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'A6b: %', o; end if;
end $$;
rollback to savepoint a1;
-- A7. an ambiguous event is excluded without poisoning the participant's unambiguous evidence
do $$ declare o text; begin
  perform pg_temp.evt('e_a7a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  perform pg_temp.evt_sub('e_a7b', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_a7b', now() - interval '1 day', null, array['rc_p1', 'rc_p3']);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'A7: %', o; end if;
end $$;
rollback to savepoint a1;
-- A8. original_app_user_id bound to ANOTHER participant makes the event ambiguous
do $$ declare o text; begin
  perform pg_temp.evt_sub('e_a8', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30), 'otx_a8', now() - interval '1 day', null, null, 'rc_p3');
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'A8: %', o; end if;
end $$;
rollback to savepoint a1;
-- A9. identities are compared trimmed: a padded own alias resolves, a padded foreign alias is
--     still detected as ambiguous
do $$ declare o text; begin
  perform pg_temp.evt_sub('e_a9a', 'INITIAL_PURCHASE', 'rc_new_device', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30), 'otx_a9a', now() - interval '1 day', null, array['  rc_p1  ']);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'A9a padded own alias: %', o; end if;
  perform pg_temp.evt_sub('e_a9b', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300), 'otx_a9b', now() - interval '1 day', null, array[' rc_p3 ']);
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'A9b padded foreign alias not detected: %', o; end if;
end $$;
rollback to savepoint a_setup;

-- S8. idempotent re-claim through the fallback path: the same live code is returned even after
--     newer, longer evidence appears
do $$ declare c1 text; c2 text; p1 text; p2 text; begin
  perform pg_temp.evt('e_s8a', 'INITIAL_PURCHASE', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.monthly', pg_temp.future_ms(30));
  select apple_code, product_id into c1, p1 from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  perform pg_temp.evt('e_s8b', 'RENEWAL', 'rc_p1', 'PRODUCTION', 'com.85blends.subscription.annual', pg_temp.future_ms(300));
  select apple_code, product_id into c2, p2 from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, null, null);
  if c1 is null or c1 <> c2 or p1 <> 'com.85blends.subscription.monthly' or p2 <> p1 then
    raise exception 'S8: c1=% c2=% p1=% p2=%', c1, c2, p1, p2;
  end if;
end $$;
rollback to savepoint f1;

-- ============================================================================================
-- S. Reward claim / state machine
-- ============================================================================================
-- S1. Free user can select each of the three plans
do $$ declare o text; begin
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.monthly');
  if o <> 'claimed:com.85blends.subscription.monthly' then raise exception 'S1 monthly: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; begin
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.threemonth');
  if o <> 'claimed:com.85blends.subscription.threemonth' then raise exception 'S1 threemonth: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; begin
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.annual');
  if o <> 'claimed:com.85blends.subscription.annual' then raise exception 'S1 annual: %', o; end if;
  -- free user cannot request legacy/unknown products
  perform 1;
end $$;
rollback to savepoint f1;
do $$ declare o text; begin
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.quarterly');
  if o <> 'invalid_product:-' then raise exception 'S1 quarterly: %', o; end if;
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'prod_internal');
  if o <> 'invalid_product:-' then raise exception 'S1 internal id: %', o; end if;
end $$;
rollback to savepoint f1;

-- S2. active Pro with a confidently-resolved product maps to it (requested ignored); legacy active fails closed
do $$ declare o text; begin
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, 'com.85blends.subscription.threemonth', 'com.85blends.subscription.annual');
  if o <> 'claimed:com.85blends.subscription.threemonth' then raise exception 'S2: %', o; end if;
end $$;
rollback to savepoint f1;
do $$ declare o text; begin
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000001', 'PRODUCTION', true, 'com.85blends.subscription.quarterly', null);
  if o <> 'legacy_or_unsupported_product_active:-' then raise exception 'S2 quarterly: %', o; end if;
end $$;
rollback to savepoint f1;

-- S3. idempotent: repeated claim returns the same still-live issued code; S4. one issued code per referrer/env
do $$ declare c1 text; c2 text; n int; begin
  select apple_code into c1 from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.monthly');
  select apple_code into c2 from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.annual');
  if c1 is null or c1 <> c2 then raise exception 'S3 idempotency: % vs %', c1, c2; end if;
  select count(*) into n from private.referral_reward_offer_codes where status = 'issued' and referrer_participant_id = 'aaaaaaaa-0000-0000-0000-000000000002';
  if n <> 1 then raise exception 'S3 issued count %', n; end if;
  begin
    update private.referral_reward_offer_codes set status = 'issued', referrer_participant_id = 'aaaaaaaa-0000-0000-0000-000000000002', reward_id = 'bbbbbbbb-0000-0000-0000-000000000002', issued_at = now()
    where apple_code = 'PRODMON2';
    raise exception 'S4: second issued code for the same referrer/environment was allowed';
  exception when unique_violation then null;
  end;
end $$;
rollback to savepoint f1;

-- S5. fulfilled is terminal (reward and code), and correct dedicated offer fulfills; W. wrong offer/product/env/user/duplicate
do $$ declare c text; o text; rs text; cs text; begin
  select apple_code into c from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000004', 'PRODUCTION', false, null, 'com.85blends.subscription.monthly');
  -- W1 wrong offer (public launch promo) does not fulfill
  select outcome into o from private.fulfill_referral_reward_offer_code(array['rc_p4'], 'PRODUCTION', 'com.85blends.subscription.monthly', '85Blends Launch - Monthly 1 Month Free', 'tx_w1', 'otx_w1', 'evt_w1');
  select status into cs from private.referral_reward_offer_codes where apple_code = c;
  if cs <> 'issued' then raise exception 'W1 wrong offer fulfilled (%): %', o, cs; end if;
  -- W2 wrong product for the dedicated offer does not fulfill
  select outcome into o from private.fulfill_referral_reward_offer_code(array['rc_p4'], 'PRODUCTION', 'com.85blends.subscription.annual', 'REFERRAL_REWARD_MONTHLY_1M_FREE', 'tx_w2', 'otx_w2', 'evt_w2');
  select status into cs from private.referral_reward_offer_codes where apple_code = c;
  if cs <> 'issued' then raise exception 'W2 wrong product fulfilled (%): %', o, cs; end if;
  -- W3 wrong environment does not fulfill
  select outcome into o from private.fulfill_referral_reward_offer_code(array['rc_p4'], 'SANDBOX', 'com.85blends.subscription.monthly', 'REFERRAL_REWARD_MONTHLY_1M_FREE', 'tx_w3', 'otx_w3', 'evt_w3');
  select status into cs from private.referral_reward_offer_codes where apple_code = c;
  if cs <> 'issued' then raise exception 'W3 wrong env fulfilled (%): %', o, cs; end if;
  -- W4 unknown / unbound user does not fulfill
  select outcome into o from private.fulfill_referral_reward_offer_code(array['rc_nobody'], 'PRODUCTION', 'com.85blends.subscription.monthly', 'REFERRAL_REWARD_MONTHLY_1M_FREE', 'tx_w4', 'otx_w4', 'evt_w4');
  select status into cs from private.referral_reward_offer_codes where apple_code = c;
  if cs <> 'issued' then raise exception 'W4 unknown user fulfilled (%): %', o, cs; end if;
  -- W5 correct dedicated offer + product + env + bound user fulfills
  select outcome into o from private.fulfill_referral_reward_offer_code(array['rc_p4'], 'PRODUCTION', 'com.85blends.subscription.monthly', 'REFERRAL_REWARD_MONTHLY_1M_FREE', 'tx_w5', 'otx_w5', 'evt_w5');
  select status into cs from private.referral_reward_offer_codes where apple_code = c;
  select status into rs from private.referral_rewards where id = 'bbbbbbbb-0000-0000-0000-000000000004';
  if cs <> 'redeemed' or rs <> 'fulfilled' then raise exception 'W5 correct offer did not fulfill (%): code=% reward=%', o, cs, rs; end if;
  raise notice 'W5 outcome=%', o;
  -- W6 duplicate delivery is idempotent
  select outcome into o from private.fulfill_referral_reward_offer_code(array['rc_p4'], 'PRODUCTION', 'com.85blends.subscription.monthly', 'REFERRAL_REWARD_MONTHLY_1M_FREE', 'tx_w5', 'otx_w5', 'evt_w5');
  select status into cs from private.referral_reward_offer_codes where apple_code = c;
  select status into rs from private.referral_rewards where id = 'bbbbbbbb-0000-0000-0000-000000000004';
  if cs <> 'redeemed' or rs <> 'fulfilled' then raise exception 'W6 duplicate changed state'; end if;
  raise notice 'W6 duplicate outcome=%', o;
  -- S5 terminal: reward cannot leave fulfilled; code cannot leave redeemed
  begin
    update private.referral_rewards set status = 'earned' where id = 'bbbbbbbb-0000-0000-0000-000000000004';
    raise exception 'S5 fulfilled reward transition allowed';
  exception when others then if sqlerrm like '%S5%' then raise; end if; end;
  begin
    update private.referral_reward_offer_codes set status = 'available' where apple_code = c;
    raise exception 'S5 redeemed code transition allowed';
  exception when others then if sqlerrm like '%S5%' then raise; end if; end;
  -- the fulfilled reward is never re-claimable
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000004', 'PRODUCTION', false, null, 'com.85blends.subscription.monthly');
  if o <> 'no_eligible_reward:-' then raise exception 'S5 reclaim after fulfilled: %', o; end if;
end $$;
rollback to savepoint f1;

-- S6. expired issued code is voided and replaced on the next claim (same reward, still issued)
do $$ declare c1 text; c2 text; s1 text; rs text; rid uuid; rid2 uuid; begin
  -- five qualified attributions keep milestone 1 justified at revalidation time
  insert into private.referral_participants (id, installation_id, referral_code)
    select ('cccccccc-0000-0000-0000-00000000000' || g)::uuid, gen_random_uuid(), 'REFRDAA' || chr(65 + g) from generate_series(1,5) g;
  insert into private.referral_attributions (referrer_participant_id, referred_participant_id, referral_code_used, status, qualified_at, qualifying_original_transaction_id, qualifying_transaction_id, qualifying_environment, qualifying_product_id, qualifying_event_id)
    select 'aaaaaaaa-0000-0000-0000-000000000002', ('cccccccc-0000-0000-0000-00000000000' || g)::uuid, 'FALLBKAB', 'qualified', now(), 'otx_s6_' || g, 'tx_s6_' || g, 'PRODUCTION', 'com.85blends.subscription.monthly', 'evt_s6_' || g from generate_series(1,5) g;
  select apple_code, reward_id into c1, rid from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.monthly');
  update private.referral_reward_offer_codes set apple_expires_at = now() - interval '1 minute' where apple_code = c1;
  select apple_code, reward_id into c2, rid2 from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.monthly');
  select status into s1 from private.referral_reward_offer_codes where apple_code = c1;
  select status into rs from private.referral_rewards where id = rid;
  if c2 is null or c2 = c1 or s1 <> 'void' or rs <> 'issued' or rid <> rid2 then
    raise exception 'S6: c1=% c2=% old=% reward=% same=%', c1, c2, s1, rs, (rid = rid2);
  end if;
end $$;
rollback to savepoint f1;
-- S6b. expired issued code whose milestone is NO LONGER justified is revoked, never replaced
do $$ declare c1 text; o text; s1 text; rs text; rid uuid; begin
  select apple_code, reward_id into c1, rid from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.monthly');
  update private.referral_reward_offer_codes set apple_expires_at = now() - interval '1 minute' where apple_code = c1;
  o := pg_temp.claim('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.monthly');
  select status into s1 from private.referral_reward_offer_codes where apple_code = c1;
  select status into rs from private.referral_rewards where id = rid;
  if o <> 'expired_no_longer_qualified:-' or s1 <> 'void' or rs <> 'revoked' then raise exception 'S6b: % code=% reward=%', o, s1, rs; end if;
end $$;
rollback to savepoint f1;

-- S7. milestone shrink (refund reversal) cannot revoke a reward that holds a live issued code
do $$ declare c1 text; rs text; cs text; o text; begin
  insert into private.referral_participants (id, installation_id, referral_code)
    select ('dddddddd-0000-0000-0000-00000000000' || g)::uuid, gen_random_uuid(), 'REFRDXA' || chr(65 + g) from generate_series(1,5) g;
  insert into private.referral_participant_aliases (app_user_id, environment, participant_id)
    select 'rc_r' || g, 'PRODUCTION', ('dddddddd-0000-0000-0000-00000000000' || g)::uuid from generate_series(1,5) g;
  insert into private.referral_attributions (referrer_participant_id, referred_participant_id, referral_code_used, status, qualified_at, qualifying_original_transaction_id, qualifying_transaction_id, qualifying_environment, qualifying_product_id, qualifying_event_id)
    select 'aaaaaaaa-0000-0000-0000-000000000002', ('dddddddd-0000-0000-0000-00000000000' || g)::uuid, 'FALLBKAB', 'qualified', now(), 'otx_r' || g, 'tx_r' || g, 'PRODUCTION', 'com.85blends.subscription.monthly', 'evt_q' || g from generate_series(1,5) g;
  select apple_code into c1 from private.claim_referral_reward('aaaaaaaa-0000-0000-0000-000000000002', 'PRODUCTION', false, null, 'com.85blends.subscription.monthly');
  select outcome into o from private.process_referral_subscription_event('refund_reversal', array['rc_r1'], 'PRODUCTION', 'evt_refund_1', null, 'com.85blends.subscription.monthly', 'tx_r1', 'otx_r1', false);
  raise notice 'S7 refund_reversal outcome=%', o;
  select status into rs from private.referral_rewards where id = 'bbbbbbbb-0000-0000-0000-000000000002';
  select status into cs from private.referral_reward_offer_codes where apple_code = c1;
  if rs <> 'issued' or cs <> 'issued' then raise exception 'S7: reward=% code=%', rs, cs; end if;
  if (select count(*) from private.referral_attributions where referrer_participant_id = 'aaaaaaaa-0000-0000-0000-000000000002' and status = 'qualified') <> 4 then
    raise exception 'S7 reversal did not reduce qualified count (outcome %)', o;
  end if;
end $$;
rollback to savepoint f1;

\echo 'ALL FALLBACK / STATE-MACHINE / FULFILLMENT SCENARIOS PASSED (F1-F10, U1-U3, H1-H14, R1-R2, A1-A9, S1-S8, W1-W6)'
rollback;
