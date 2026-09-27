-- JobFinder: multi-user + per-user API keys with fallback.
-- Run once in the Supabase SQL editor AFTER 001_init.sql.
-- The earliest-created auth user becomes the owner: existing data is assigned to them and they may use the
-- shared keys from GitHub secrets. Everyone else only uses the keys they add in Settings.

-- ---------------------------------------------------------------------------
-- Accounts: per-user limits, controlled by you (users can read but not change their own row).
-- ---------------------------------------------------------------------------
create table if not exists accounts (
  user_id           uuid primary key references auth.users(id) on delete cascade,
  enabled           boolean not null default true,
  use_shared_keys   boolean not null default false,  -- may fall back to the keys in GitHub secrets
  llm_calls_per_run int     not null default 40,     -- Gemini call cap per hourly run for this user
  created_at        timestamptz not null default now()
);

do $$
declare owner uuid;
begin
  select id into owner from auth.users order by created_at limit 1;
  if owner is null then
    raise exception 'Create your own user first (Authentication → Users → Add user), then run this migration.';
  end if;
  raise notice 'Owner user id: %', owner;

  alter table settings      add column if not exists user_id uuid references auth.users(id) on delete cascade;
  alter table profile       add column if not exists user_id uuid references auth.users(id) on delete cascade;
  alter table jobs          add column if not exists user_id uuid references auth.users(id) on delete cascade;
  alter table pipeline_runs add column if not exists user_id uuid references auth.users(id) on delete cascade;
  alter table agent_runs    add column if not exists user_id uuid references auth.users(id) on delete cascade;

  update settings      set user_id = owner where user_id is null;
  update profile       set user_id = owner where user_id is null;
  update jobs          set user_id = owner where user_id is null;
  update pipeline_runs set user_id = owner where user_id is null;
  update agent_runs    set user_id = owner where user_id is null;

  insert into accounts (user_id, use_shared_keys, llm_calls_per_run) values (owner, true, 60)
  on conflict (user_id) do update set use_shared_keys = true;
end $$;

-- settings / profile: one row per user instead of the single id = 1 row
alter table settings drop column if exists id;
alter table profile  drop column if exists id;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.settings'::regclass and contype = 'p') then
    alter table settings add primary key (user_id);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.profile'::regclass and contype = 'p') then
    alter table profile add primary key (user_id);
  end if;
end $$;
alter table settings alter column user_id set default auth.uid();
alter table profile  alter column user_id set default auth.uid();

alter table jobs          alter column user_id set not null, alter column user_id set default auth.uid();
alter table pipeline_runs alter column user_id set not null;
alter table agent_runs    alter column user_id set not null;

-- the same posting can be captured separately for different users
alter table jobs drop constraint if exists jobs_source_external_id_key;
create unique index if not exists jobs_user_source_external_idx on jobs(user_id, source, external_id);
create index if not exists jobs_user_status_idx   on jobs(user_id, status);
create index if not exists agent_runs_user_idx    on agent_runs(user_id, started_at desc);
create index if not exists pipeline_runs_user_idx on pipeline_runs(user_id, started_at desc);

-- rows for any other users that already exist
insert into accounts (user_id) select id from auth.users on conflict do nothing;
insert into settings (user_id) select id from auth.users on conflict do nothing;
insert into profile  (user_id) select id from auth.users on conflict do nothing;

-- new users get empty settings/profile automatically
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.accounts (user_id) values (new.id) on conflict do nothing;
  insert into public.settings (user_id) values (new.id) on conflict do nothing;
  insert into public.profile  (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- API keys added by users in the app. Write-only from the app: users can list their keys
-- (label + last 4 chars + status) but can never read a key value back.
-- ---------------------------------------------------------------------------
create table if not exists api_keys (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  provider        text not null check (provider in ('gemini', 'adzuna', 'rapidapi')),
  label           text not null default '',
  app_id          text,                         -- Adzuna application id
  key_value       text not null,
  hint            text generated always as ('…' || right(key_value, 4)) stored,
  priority        int  not null default 0,      -- lower = tried first
  exhausted_until timestamptz,                  -- set by the pipeline when a limit is hit
  last_error      text,
  last_used_at    timestamptz,
  created_at      timestamptz not null default now()
);
create index if not exists api_keys_user_idx on api_keys(user_id, provider, priority);

-- Fallback bookkeeping for every key (including the shared GitHub-secret keys), by fingerprint.
-- No policies: only the pipeline (service role) can touch it.
create table if not exists key_state (
  id              text primary key,             -- <sha256 fingerprint>:<scope, e.g. model name>
  provider        text not null,
  exhausted_until timestamptz,
  last_error      text,
  updated_at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Row level security: every user sees only their own rows.
-- ---------------------------------------------------------------------------
alter table accounts  enable row level security;
alter table api_keys  enable row level security;
alter table key_state enable row level security;

drop policy if exists "auth read settings"   on settings;
drop policy if exists "auth write settings"  on settings;
drop policy if exists "auth read profile"    on profile;
drop policy if exists "auth read jobs"       on jobs;
drop policy if exists "auth update jobs"     on jobs;
drop policy if exists "auth read runs"       on pipeline_runs;
drop policy if exists "auth read agent runs" on agent_runs;

drop policy if exists "own settings read"   on settings;
create policy "own settings read"   on settings for select to authenticated using (user_id = auth.uid());
drop policy if exists "own settings write"  on settings;
create policy "own settings write"  on settings for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "own profile read"    on profile;
create policy "own profile read"    on profile  for select to authenticated using (user_id = auth.uid());
drop policy if exists "own jobs read"       on jobs;
create policy "own jobs read"       on jobs     for select to authenticated using (user_id = auth.uid());
drop policy if exists "own jobs update"     on jobs;
create policy "own jobs update"     on jobs     for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "own runs read"       on pipeline_runs;
create policy "own runs read"       on pipeline_runs for select to authenticated using (user_id = auth.uid());
drop policy if exists "own agent runs read" on agent_runs;
create policy "own agent runs read" on agent_runs    for select to authenticated using (user_id = auth.uid());
drop policy if exists "own account read"    on accounts;
create policy "own account read"    on accounts for select to authenticated using (user_id = auth.uid());

drop policy if exists "own keys read"   on api_keys;
create policy "own keys read"   on api_keys for select to authenticated using (user_id = auth.uid());
drop policy if exists "own keys insert" on api_keys;
create policy "own keys insert" on api_keys for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "own keys delete" on api_keys;
create policy "own keys delete" on api_keys for delete to authenticated using (user_id = auth.uid());

-- column-level privileges: the key value is insert-only for app users
revoke all on api_keys from anon, authenticated;
grant select (id, user_id, provider, label, app_id, hint, priority, exhausted_until, last_error, last_used_at, created_at)
  on api_keys to authenticated;
grant insert (provider, label, app_id, key_value, priority) on api_keys to authenticated;
grant delete on api_keys to authenticated;
revoke all on key_state from anon, authenticated;
revoke insert, update, delete on accounts from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Storage: files live under <user_id>/…  (parent/<uid>/resume/…, jobs/<uid>/<job_id>/…)
-- ---------------------------------------------------------------------------
drop policy if exists "auth read parent"    on storage.objects;
drop policy if exists "auth upload parent"  on storage.objects;
drop policy if exists "auth replace parent" on storage.objects;
drop policy if exists "auth delete parent"  on storage.objects;

drop policy if exists "own files read" on storage.objects;
create policy "own files read" on storage.objects for select to authenticated
  using (bucket_id in ('parent', 'jobs') and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own parent insert" on storage.objects;
create policy "own parent insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'parent' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own parent update" on storage.objects;
create policy "own parent update" on storage.objects for update to authenticated
  using (bucket_id = 'parent' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'parent' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own parent delete" on storage.objects;
create policy "own parent delete" on storage.objects for delete to authenticated
  using (bucket_id = 'parent' and (storage.foldername(name))[1] = auth.uid()::text);
