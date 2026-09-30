-- JobFinder: admin tools for @rajkumar.codes accounts.
--   * shared_api_keys – the shared (owner) key pool, managed in the app: see which key is in use, switch order,
--     disable keys. Keys stored in GitHub secrets appear here too (value stays in GitHub, only the last 4 chars).
--   * request_agents_run() – "Run now" button: starts the agents GitHub workflow via pg_net.
-- Run once in the Supabase SQL editor after 003_seen_postings.sql, then store the GitHub token (see bottom).

create or replace function public.is_admin() returns boolean
language sql stable as $$
  select coalesce(auth.jwt() ->> 'email', '') ilike '%@rajkumar.codes'
$$;

-- ---------------------------------------------------------------------------
-- Shared key pool
-- ---------------------------------------------------------------------------
create table if not exists shared_api_keys (
  id              uuid primary key default gen_random_uuid(),
  provider        text not null check (provider in ('gemini', 'adzuna', 'rapidapi')),
  label           text not null default '',
  source          text not null default 'app' check (source in ('app', 'github')),
  app_id          text,
  key_value       text,                           -- null for GitHub-secret keys (the value stays in GitHub)
  fingerprint     text unique,                    -- set by the pipeline; identifies GitHub-secret keys
  hint            text not null default '',
  priority        int  not null default 100,      -- lower = tried first
  enabled         boolean not null default true,
  in_use          boolean not null default false, -- served the most recent successful call for its provider
  exhausted_until timestamptz,
  last_error      text,
  last_used_at    timestamptz,
  created_at      timestamptz not null default now(),
  check (source = 'github' or key_value is not null)
);

create or replace function public.shared_key_hint() returns trigger language plpgsql as $$
begin
  if new.key_value is not null then new.hint := '…' || right(new.key_value, 4); end if;
  return new;
end $$;
drop trigger if exists shared_key_hint on shared_api_keys;
create trigger shared_key_hint before insert or update of key_value on shared_api_keys
  for each row execute function public.shared_key_hint();

alter table shared_api_keys enable row level security;
drop policy if exists "admin read shared keys" on shared_api_keys;
create policy "admin read shared keys"   on shared_api_keys for select to authenticated using (public.is_admin());
drop policy if exists "admin add shared keys" on shared_api_keys;
create policy "admin add shared keys"    on shared_api_keys for insert to authenticated with check (public.is_admin() and source = 'app');
drop policy if exists "admin change shared keys" on shared_api_keys;
create policy "admin change shared keys" on shared_api_keys for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin remove shared keys" on shared_api_keys;
create policy "admin remove shared keys" on shared_api_keys for delete to authenticated using (public.is_admin() and source = 'app');

-- key values are write-only for admins too
revoke all on shared_api_keys from anon, authenticated;
grant select (id, provider, label, source, app_id, hint, priority, enabled, in_use, exhausted_until, last_error,
              last_used_at, created_at) on shared_api_keys to authenticated;
grant insert (provider, label, app_id, key_value, priority) on shared_api_keys to authenticated;
grant update (label, priority, enabled) on shared_api_keys to authenticated;
grant delete on shared_api_keys to authenticated;

-- ---------------------------------------------------------------------------
-- "Run now": start the agents workflow through GitHub's API (pg_net), token kept in Supabase Vault
-- ---------------------------------------------------------------------------
create extension if not exists pg_net;

create table if not exists agent_run_requests (
  id           bigserial primary key,
  requested_by uuid default auth.uid(),
  requested_at timestamptz not null default now(),
  all_sources  boolean not null default true,
  request_id   bigint                       -- pg_net request, for the status check
);
alter table agent_run_requests enable row level security;
drop policy if exists "admin read run requests" on agent_run_requests;
create policy "admin read run requests" on agent_run_requests for select to authenticated using (public.is_admin());
revoke insert, update, delete on agent_run_requests from anon, authenticated;

create or replace function public.request_agents_run(all_sources boolean default true) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_token text;
  v_last  timestamptz;
  v_req   bigint;
  v_id    bigint;
begin
  if not public.is_admin() then
    raise exception 'Only @rajkumar.codes accounts can start runs';
  end if;
  select max(requested_at) into v_last from agent_run_requests;
  if v_last > now() - interval '5 minutes' then
    raise exception 'A run was started less than 5 minutes ago – check Agents → Runs';
  end if;
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'gh_dispatch_token';
  if v_token is null then
    raise exception 'GitHub token not stored yet: run  select vault.create_secret(''<token>'', ''gh_dispatch_token'');  in the SQL editor';
  end if;
  select net.http_post(
    url     := 'https://api.github.com/repos/rajkumar-code29/JobFinder/actions/workflows/agents.yml/dispatches',
    body    := jsonb_build_object('ref', 'main', 'inputs',
                 jsonb_build_object('trigger', 'manual', 'all_sources', case when all_sources then 'true' else 'false' end)),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_token, 'Accept', 'application/vnd.github+json',
                 'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'jobfinder-app', 'Content-Type', 'application/json')
  ) into v_req;
  insert into agent_run_requests (all_sources, request_id) values (all_sources, v_req) returning id into v_id;
  return v_id;
end $$;

-- GitHub's answer for a request: 204 = run started.
create or replace function public.agents_run_request_status(p_id bigint)
returns table (status_code int, message text)
language sql stable security definer set search_path = public as $$
  select r.status_code, coalesce(r.error_msg, left(r.content::text, 300))
  from agent_run_requests q
  join net._http_response r on r.id = q.request_id
  where q.id = p_id and public.is_admin()
$$;

revoke all on function public.request_agents_run(boolean) from public, anon;
grant execute on function public.request_agents_run(boolean) to authenticated;
revoke all on function public.agents_run_request_status(bigint) from public, anon;
grant execute on function public.agents_run_request_status(bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- After running this file, store the GitHub token (the same fine-grained token as the GH_DISPATCH_TOKEN
-- secret: this repo only, Actions: read and write) in Vault – run this line on its own with your token:
--
--   select vault.create_secret('github_pat_…', 'gh_dispatch_token', 'Starts the JobFinder agents workflow');
--
-- To replace it later:  select vault.update_secret((select id from vault.secrets where name = 'gh_dispatch_token'), 'github_pat_…');
