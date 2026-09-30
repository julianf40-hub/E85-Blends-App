-- 85Blends 2.4.0 — Referral reward active-product fallback + reward state machine + webhook
-- fulfillment regression matrix.
--
-- WHAT THIS COVERS (every scenario RAISEs on any unexpected outcome; a clean run that reaches the
-- final \echo line is a full pass):
--   F1-F10  private.claim_referral_reward's webhook-history fallback (migration 20260929230218):
--           gating (active Pro AND NULL/unsupported product only), no-evidence fails closed,
--           same-environment only in both directions + alias/event environment binding, processed
--           events only, event-type restriction, supported-product allowlist (legacy quarterly and
--           RevenueCat-internal ids never resolve), expired/malformed expiration evidence,
--           greatest expiration wins, cross-product tie at the greatest expiration fails closed
--           (same-product tie resolves), unrelated aliases never influence resolution.
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

-- helper: insert a processed webhook event carrying product/expiration evidence
create or replace function pg_temp.evt(p_id text, p_type text, p_user text, p_env text, p_product text, p_exp_ms text, p_status text default 'processed')
returns void language sql as $$
  insert into private.revenuecat_webhook_events (event_id, event_type, app_user_id, environment, event_timestamp, payload_hash, raw_payload, processing_status, processed_at)
  values (p_id, p_type, p_user, p_env, now(), md5(p_id),
          jsonb_build_object('event', jsonb_build_object('product_id', p_product, 'expiration_at_ms', p_exp_ms)),
          p_status, case when p_status = 'processed' then now() else null end);
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
-- F1. Fallback runs ONLY when active Pro = true AND active product = NULL/unsupported
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

\echo 'ALL FALLBACK / STATE-MACHINE / FULFILLMENT SCENARIOS PASSED (F1-F10, S1-S7, W1-W6)'
rollback;
