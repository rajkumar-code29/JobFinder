-- Custom jobs: title + JD entered by hand on the Custom page, processed only when the user asks.
-- They use source = 'custom', never join the hourly batches, and are grouped by custom_batch instead.

alter table jobs add column if not exists custom_batch int;
create index if not exists jobs_custom_idx on jobs(user_id, custom_batch) where source = 'custom';

create or replace function public.add_custom_job(p_title text, p_description text, p_company text default null,
                                                 p_url text default null, p_batch int default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_id    text;
  v_batch int;
  v_url   text := nullif(trim(coalesce(p_url, '')), '');
begin
  if v_uid is null or not public.is_approved() then
    raise exception 'Your account needs to be approved first';
  end if;
  if length(trim(coalesce(p_title, ''))) < 2 then
    raise exception 'Add the job title';
  end if;
  if length(trim(coalesce(p_description, ''))) < 50 then
    raise exception 'Paste the full job description';
  end if;
  if v_url is not null and v_url !~* '^https?://' then
    v_url := 'https://' || v_url;
  end if;
  v_batch := coalesce(p_batch, (select coalesce(max(custom_batch), 0) + 1 from jobs
                                where user_id = v_uid and source = 'custom'));
  if v_batch < 1 then
    raise exception 'Batch number must be 1 or more';
  end if;
  v_id := 'JF-' || to_char(now() at time zone 'utc', 'YYYYMMDD') || '-'
          || (select string_agg(substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1), '')
              from generate_series(1, 5));
  insert into jobs (job_id, user_id, source, external_id, title, company, description, url, apply_url,
                    relevance, relevance_reason, status, custom_batch)
  values (v_id, v_uid, 'custom', v_id, left(trim(p_title), 300),
          coalesce(nullif(left(trim(coalesce(p_company, '')), 200), ''), 'NA'),
          left(trim(p_description), 30000), coalesce(v_url, 'NA'), coalesce(v_url, 'NA'),
          100, 'Added by hand', 'new', v_batch);
  return v_id;
end $$;
revoke all on function public.add_custom_job(text, text, text, text, int) from public, anon;
grant execute on function public.add_custom_job(text, text, text, text, int) to authenticated;

-- "Process now": starts the agents workflow for this user's custom jobs only
create table if not exists custom_run_requests (
  id           bigserial primary key,
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  requested_at timestamptz not null default now(),
  request_id   bigint
);
alter table custom_run_requests enable row level security;
drop policy if exists "own custom run requests" on custom_run_requests;
create policy "own custom run requests" on custom_run_requests for select to authenticated
  using (user_id = auth.uid());
revoke insert, update, delete on custom_run_requests from anon, authenticated;

create or replace function public.request_custom_run() returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_token text;
  v_req   bigint;
  v_id    bigint;
begin
  if v_uid is null or not public.is_approved() then
    raise exception 'Your account needs to be approved first';
  end if;
  if exists (select 1 from custom_run_requests
             where user_id = v_uid and requested_at > now() - interval '3 minutes') then
    raise exception 'A run was started less than 3 minutes ago, it will show up under Agents > Runs';
  end if;
  if not exists (select 1 from jobs where user_id = v_uid and source = 'custom'
                 and status in ('new', 'scored', 'tailored') and attempts < 3) then
    raise exception 'Nothing to process: add a job first';
  end if;
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'gh_dispatch_token';
  if v_token is null then
    raise exception 'Runs from the app are not set up yet (GitHub token missing in Vault)';
  end if;
  select net.http_post(
    url     := 'https://api.github.com/repos/rajkumar-code29/JobFinder/actions/workflows/agents.yml/dispatches',
    body    := jsonb_build_object('ref', 'main', 'inputs',
                 jsonb_build_object('trigger', 'manual', 'all_sources', 'false', 'custom', v_uid::text)),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_token, 'Accept', 'application/vnd.github+json',
                 'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'pounce-app', 'Content-Type', 'application/json')
  ) into v_req;
  insert into custom_run_requests (user_id, request_id) values (v_uid, v_req) returning id into v_id;
  return v_id;
end $$;
revoke all on function public.request_custom_run() from public, anon;
grant execute on function public.request_custom_run() to authenticated;

create or replace function public.custom_run_request_status(p_id bigint)
returns table (status_code int, message text)
language sql stable security definer set search_path = public as $$
  select r.status_code, coalesce(r.error_msg, left(r.content::text, 300))
  from custom_run_requests q
  join net._http_response r on r.id = q.request_id
  where q.id = p_id and q.user_id = auth.uid()
$$;
revoke all on function public.custom_run_request_status(bigint) from public, anon;
grant execute on function public.custom_run_request_status(bigint) to authenticated;

-- Home totals link to the Jobs page, which doesn't show custom jobs, so leave them out here too
create or replace view dashboard_stats as
select
  (select coalesce(sum(jobs_scanned),0) from pipeline_runs)                       as total_scanned,
  (select count(*) from jobs where source <> 'custom')                            as total_matched,
  (select count(*) from jobs where status = 'ready' and source <> 'custom')       as ready,
  (select count(*) from jobs where status = 'applied' and source <> 'custom')     as applied,
  (select count(*) from agent_runs where status = 'error')                        as total_errors,
  (select count(*) from agent_runs where status = 'error'
      and started_at > now() - interval '24 hours')                               as errors_24h,
  (select count(*) from agent_runs where status = 'running'
      and started_at > now() - interval '2 hours')                                as agents_running,
  (select max(started_at) from pipeline_runs)                                      as last_run_at;
alter view dashboard_stats set (security_invoker = true);
