-- SYNTHETIC RECONSTRUCTION -- not an original migration, never applied anywhere. Reconstructs the
-- three private.referral_* tables and their supporting objects exactly as they exist live today.
-- No migration anywhere in the live ledger, this repository's git history, or the one remote
-- branch inspected during the prior rehearsal turn (fix/2.3.2-community-station-upsert-security)
-- creates these objects. The only trace of their existence in any recorded migration is a single
-- comment inside 20260910212848 (price_alert_backend_foundation): "Reuse the existing
-- private.set_updated_at() trigger helper used by the RevenueCat/referral backend" -- treating
-- this backend as already-established at that point. That is why this baseline is ordered
-- immediately before that migration.
--
-- Placeholder version 20260910000000: chosen to sort after the RevenueCat foundation
-- (20260823060735) and every 2026-09-09 analytics migration, and immediately before
-- price_alert_backend_foundation (20260910212848) on the same calendar day, consistent with that
-- migration's own comment treating this backend as pre-existing. Illustrative only, not
-- authoritative -- pending your own decision if this is ever pursued for real.
--
-- Reuses private.set_updated_at() from 20260823060735 rather than redefining it -- that function
-- must already exist (created by the RevenueCat foundation migration, which this chain places
-- first). Depends on the private schema itself, also created by that same migration.
--
-- Every definition below is VERIFIED directly against live catalog metadata (pg_class,
-- pg_policies, information_schema.columns/role_table_grants, pg_constraint via
-- pg_get_constraintdef, pg_indexes, information_schema.triggers), queried during this rehearsal.
-- No application rows, no secrets -- structure only.

create table private.referral_participants (
  id               uuid        primary key default gen_random_uuid(),
  installation_id  uuid        not null,
  referral_code    text        not null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint referral_participants_installation_id_key unique (installation_id),
  constraint referral_participants_referral_code_key unique (referral_code),
  constraint referral_participants_code_format
    check (referral_code ~ '^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$')
);
-- referral_code excludes visually ambiguous characters (0/O, 1/I/L) by construction of this
-- character class -- a deliberate human-friendly design choice, reproduced exactly as observed
-- live, not altered.

create table private.referral_participant_aliases (
  app_user_id     text        not null,
  environment     text        not null,
  participant_id  uuid        not null references private.referral_participants(id) on delete cascade,
  created_at      timestamptz not null default now(),

  constraint referral_participant_aliases_pkey primary key (app_user_id, environment),
  constraint referral_participant_aliases_app_user_id_nonblank check (length(btrim(app_user_id)) > 0),
  constraint referral_participant_aliases_environment check (environment in ('SANDBOX', 'PRODUCTION'))
);

create index referral_participant_aliases_participant_idx
  on private.referral_participant_aliases (participant_id, environment);

create table private.referral_attributions (
  id                       uuid        primary key default gen_random_uuid(),
  referrer_participant_id  uuid        not null references private.referral_participants(id) on delete restrict,
  referred_participant_id  uuid        not null references private.referral_participants(id) on delete restrict,
  referral_code_used       text        not null,
  status                   text        not null default 'pending',
  attributed_at            timestamptz not null default now(),
  qualified_at             timestamptz,
  qualifying_event_id      text,
  qualifying_product_id    text,
  disqualified_at          timestamptz,
  disqualified_reason      text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint referral_attributions_not_self check (referrer_participant_id <> referred_participant_id),
  constraint referral_attributions_status
    check (status in ('pending','qualified','disqualified','reversed')),
  constraint referral_attributions_code_format
    check (referral_code_used ~ '^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$'),
  constraint referral_attributions_qualified_fields check (
    (status = 'qualified' and qualified_at is not null and qualifying_event_id is not null)
    or (status <> 'qualified')
  ),
  constraint referral_attributions_one_referrer_per_referred unique (referred_participant_id),
  constraint referral_attributions_qualifying_event_id_key unique (qualifying_event_id)
);
-- referral_attributions_one_referrer_per_referred (UNIQUE on referred_participant_id alone)
-- enforces that each participant can be the *referred* side of at most one attribution --
-- reproduced exactly as observed live.

create index referral_attributions_referrer_status_idx
  on private.referral_attributions (referrer_participant_id, status, qualified_at);

create table private.referral_rewards (
  id                             uuid        primary key default gen_random_uuid(),
  referrer_participant_id        uuid        not null references private.referral_participants(id) on delete restrict,
  milestone_number               integer     not null,
  required_qualified_referrals   integer     not null default 5,
  reward_type                    text        not null default 'one_month_pro',
  status                         text        not null default 'earned',
  earned_at                      timestamptz not null default now(),
  fulfilled_at                   timestamptz,
  fulfillment_reference          text,
  revoked_at                     timestamptz,
  revoke_reason                  text,
  created_at                     timestamptz not null default now(),
  updated_at                     timestamptz not null default now(),

  constraint referral_rewards_status check (status in ('earned','fulfilled','revoked')),
  constraint referral_rewards_milestone_positive check (milestone_number > 0),
  constraint referral_rewards_type check (reward_type = 'one_month_pro'),
  constraint referral_rewards_required_positive check (required_qualified_referrals > 0),
  constraint referral_rewards_unique_milestone unique (referrer_participant_id, milestone_number)
);

create index referral_rewards_referrer_status_idx
  on private.referral_rewards (referrer_participant_id, status, milestone_number);

-- Reuses the RevenueCat foundation's existing trigger helper -- not redefined here.
create trigger referral_participants_set_updated_at
  before update on private.referral_participants
  for each row execute function private.set_updated_at();

create trigger referral_attributions_set_updated_at
  before update on private.referral_attributions
  for each row execute function private.set_updated_at();

create trigger referral_rewards_set_updated_at
  before update on private.referral_rewards
  for each row execute function private.set_updated_at();
-- Note: referral_participant_aliases has no updated_at column live and correspondingly no
-- trigger, matching private.revenuecat_aliases' identical shape -- reproduced faithfully, not an
-- omission.

alter table private.referral_participants enable row level security;
alter table private.referral_participant_aliases enable row level security;
alter table private.referral_attributions enable row level security;
alter table private.referral_rewards enable row level security;

revoke all on table private.referral_participants from public, anon, authenticated;
revoke all on table private.referral_participant_aliases from public, anon, authenticated;
revoke all on table private.referral_attributions from public, anon, authenticated;
revoke all on table private.referral_rewards from public, anon, authenticated;

grant select, insert, update, delete on table private.referral_participants to service_role;
grant select, insert, update, delete on table private.referral_participant_aliases to service_role;
grant select, insert, update, delete on table private.referral_attributions to service_role;
grant select, insert, update, delete on table private.referral_rewards to service_role;
-- VERIFIED directly (information_schema.role_table_grants, queried live during this rehearsal):
-- all four tables show explicit service_role SELECT/INSERT/UPDATE/DELETE and zero grants to
-- anon/authenticated/PUBLIC. Zero RLS policies exist on any of the four (confirmed via
-- pg_policies), consistent with and harmless given zero grants to any role RLS would apply to --
-- the same "RLS enabled, no policy" pattern already established for the RevenueCat tables.

-- CORRECTION (2026-09-19, found during fresh-database replay validation of the full 29-migration
-- sequence): this baseline's original reconstruction captured the four tables above but omitted
-- three helper functions that also predate all tracked migration history and, like the tables
-- above, are created by no migration anywhere in this repository. A truly empty-database replay of
-- all 29 files (Supabase CLI 2.117.0 + Docker, local project "eightyfiveblends") confirmed these
-- three functions are completely absent afterward -- not just different, but never created -- while
-- production has all three live. Bodies below are reproduced verbatim from
-- pg_get_functiondef(oid) against the live project, re-styled to this repository's lowercase-
-- keyword convention only (a cosmetic, meaning-preserving transform Postgres treats identically);
-- no logic, identifier, or literal was altered. Grants match the exact live grantee set
-- (information_schema.routine_privileges): postgres (owner) and service_role only -- no
-- anon/authenticated/PUBLIC, consistent with every other private-schema function in this project.
--
-- Note: create_or_get_referral_participant's on-conflict clause below silently no-ops (no error)
-- when an alias is already attached to a different participant -- reproduced exactly as it exists
-- live, not corrected here. This is the same bug PR #78's 20260919150000 migration (not part of
-- this branch) separately fixes going forward with an insert-then-verify pattern; faithfully
-- reconstructing the pre-fix behavior here is intentional, not an oversight.

create or replace function private.generate_referral_code()
returns text
language plpgsql
set search_path to 'pg_catalog', 'private', 'extensions'
as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  bytes bytea := gen_random_bytes(8);
  result text := '';
  i integer;
begin
  for i in 0..7 loop
    result := result || substr(alphabet, (get_byte(bytes, i) % length(alphabet)) + 1, 1);
  end loop;
  return result;
end;
$$;

create or replace function private.create_or_get_referral_participant(
  p_installation_id uuid,
  p_app_user_id text default null::text,
  p_environment text default 'PRODUCTION'::text
)
returns table(participant_id uuid, referral_code text)
language plpgsql
set search_path to 'pg_catalog', 'private'
as $$
declare
  v_participant private.referral_participants%rowtype;
  v_code text;
  v_attempt integer := 0;
begin
  if p_installation_id is null then
    raise exception 'installation_id_required';
  end if;
  if p_environment not in ('SANDBOX','PRODUCTION') then
    raise exception 'invalid_environment';
  end if;

  select * into v_participant
  from private.referral_participants rp
  where rp.installation_id = p_installation_id;

  if v_participant.id is null then
    loop
      v_attempt := v_attempt + 1;
      v_code := private.generate_referral_code();
      begin
        insert into private.referral_participants (installation_id, referral_code)
        values (p_installation_id, v_code)
        returning * into v_participant;
        exit;
      exception when unique_violation then
        if v_attempt >= 10 then
          raise;
        end if;
      end;
    end loop;
  end if;

  if p_app_user_id is not null and length(btrim(p_app_user_id)) > 0 then
    insert into private.referral_participant_aliases (app_user_id, environment, participant_id)
    values (btrim(p_app_user_id), p_environment, v_participant.id)
    on conflict (app_user_id, environment) do update
      set participant_id = excluded.participant_id
      where private.referral_participant_aliases.participant_id = excluded.participant_id;
  end if;

  return query select v_participant.id, v_participant.referral_code;
end;
$$;

create or replace function private.apply_referral_code(
  p_referred_participant_id uuid,
  p_referral_code text
)
returns uuid
language plpgsql
set search_path to 'pg_catalog', 'private'
as $$
declare
  v_code text := upper(btrim(p_referral_code));
  v_referrer_id uuid;
  v_attribution_id uuid;
begin
  if p_referred_participant_id is null then
    raise exception 'referred_participant_required';
  end if;
  if v_code !~ '^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$' then
    raise exception 'invalid_referral_code';
  end if;

  select id into v_referrer_id
  from private.referral_participants
  where referral_code = v_code;

  if v_referrer_id is null then
    raise exception 'referral_code_not_found';
  end if;
  if v_referrer_id = p_referred_participant_id then
    raise exception 'self_referral_not_allowed';
  end if;

  insert into private.referral_attributions (
    referrer_participant_id,
    referred_participant_id,
    referral_code_used,
    status
  ) values (
    v_referrer_id,
    p_referred_participant_id,
    v_code,
    'pending'
  )
  returning id into v_attribution_id;

  return v_attribution_id;
exception
  when unique_violation then
    raise exception 'referral_already_attributed';
end;
$$;

revoke execute on function private.generate_referral_code() from public, anon, authenticated;
revoke execute on function private.create_or_get_referral_participant(uuid, text, text) from public, anon, authenticated;
revoke execute on function private.apply_referral_code(uuid, text) from public, anon, authenticated;

grant execute on function private.generate_referral_code() to postgres, service_role;
grant execute on function private.create_or_get_referral_participant(uuid, text, text) to postgres, service_role;
grant execute on function private.apply_referral_code(uuid, text) to postgres, service_role;
