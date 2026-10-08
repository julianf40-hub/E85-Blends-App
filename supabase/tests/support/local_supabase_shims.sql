-- LOCAL REPLAY ONLY. Stand-ins for the Supabase-hosted pieces the migration chain expects, so the
-- chain can be replayed on a plain scratch Postgres 16+. NEVER run this against a hosted project:
-- the real project already has all of this (pg_cron, pg_net, Vault, the API roles).
--
-- What it provides, and how closely it mirrors the hosted objects:
--   * roles anon / authenticated / service_role (NOLOGIN) - the same names and privileges model the
--     migrations grant to; PostgREST's JWT-to-role switch is simulated in tests with SET ROLE and
--     set_config('request.jwt.claim.role', ...).
--   * schema extensions with pgcrypto + uuid-ossp (where Supabase installs them).
--   * cron.job / cron.schedule / cron.alter_job / cron.job_run_details - enough for the migrations
--     (job name uniqueness, active flag, schedule, command). Nothing ever runs on a schedule here.
--   * net.http_post - RECORDS the request in net.sent_requests and returns an id. It never sends
--     anything, so no test can reach a network. net._http_response exists (empty) like the real pg_net's.
--   * vault.secrets / vault.decrypted_secrets - a plain table and view.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;

-- Supabase's API roles can use the public schema.
grant usage on schema public to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Vault stand-in
-- ---------------------------------------------------------------------------------------------
create schema if not exists vault;
create table if not exists vault.secrets (
  id          uuid primary key default gen_random_uuid(),
  name        text unique,
  description text not null default '',
  secret      text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create or replace view vault.decrypted_secrets as
  select id, name, description, secret, secret as decrypted_secret, created_at, updated_at
  from vault.secrets;

create or replace function vault.create_secret(
  new_secret text,
  new_name text default null,
  new_description text default '',
  new_key_id uuid default null
)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  insert into vault.secrets (name, description, secret)
  values (new_name, coalesce(new_description, ''), new_secret)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- pg_cron stand-in
-- ---------------------------------------------------------------------------------------------
create schema if not exists cron;
create table if not exists cron.job (
  jobid     bigserial primary key,
  schedule  text    not null,
  command   text    not null,
  nodename  text    not null default 'localhost',
  nodeport  integer not null default 5432,
  database  text    not null default current_database(),
  username  text    not null default current_user,
  active    boolean not null default true,
  jobname   text unique
);
create table if not exists cron.job_run_details (
  jobid          bigint,
  runid          bigserial primary key,
  job_pid        integer,
  database       text,
  username       text,
  command        text,
  status         text,
  return_message text,
  start_time     timestamptz,
  end_time       timestamptz
);

create or replace function cron.schedule(job_name text, schedule text, command text)
returns bigint
language plpgsql
as $$
declare
  v_id bigint;
begin
  insert into cron.job (jobname, schedule, command)
  values (job_name, schedule, command)
  on conflict (jobname) do update
    set schedule = excluded.schedule, command = excluded.command, active = true
  returning jobid into v_id;
  return v_id;
end;
$$;

create or replace function cron.schedule(schedule text, command text)
returns bigint
language sql
as $$
  insert into cron.job (schedule, command) values (schedule, command) returning jobid;
$$;

create or replace function cron.alter_job(
  job_id bigint,
  schedule text default null,
  command text default null,
  database text default null,
  username text default null,
  active boolean default null
)
returns void
language plpgsql
as $$
begin
  update cron.job j
  set schedule = coalesce(alter_job.schedule, j.schedule),
      command  = coalesce(alter_job.command,  j.command),
      database = coalesce(alter_job.database, j.database),
      username = coalesce(alter_job.username, j.username),
      active   = coalesce(alter_job.active,   j.active)
  where j.jobid = alter_job.job_id;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- pg_net stand-in: record, never send.
-- ---------------------------------------------------------------------------------------------
create schema if not exists net;
create table if not exists net.sent_requests (
  id                   bigserial primary key,
  url                  text,
  headers              jsonb,
  body                 jsonb,
  timeout_milliseconds integer,
  created_at           timestamptz not null default now()
);

-- The real pg_net keeps the response of every request it made in net._http_response (the scheduler's "did the worker answer
-- 2xx" evidence). Empty here: nothing is ever sent. The read-only observation query in supabase/runbooks reads its status codes.
create table if not exists net._http_response (
  id           bigint,
  status_code  integer,
  content_type text,
  headers      jsonb,
  content      text,
  timed_out    boolean,
  error_msg    text,
  created      timestamptz not null default now()
);

create or replace function net.http_post(
  url text,
  body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb,
  timeout_milliseconds integer default 5000
)
returns bigint
language plpgsql
as $$
declare
  v_id bigint;
begin
  insert into net.sent_requests (url, headers, body, timeout_milliseconds)
  values (url, headers, body, timeout_milliseconds)
  returning id into v_id;
  return v_id;
end;
$$;
