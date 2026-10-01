-- Privacy notice and the admin Users panel. (Old unapplied jobs are cleaned up by the pipeline.)

alter table accounts add column if not exists privacy_accepted_at timestamptz;

-- accounts is read-only for users, so this goes through a function
create or replace function public.accept_privacy() returns void
language sql security definer set search_path = public as $$
  update accounts set privacy_accepted_at = now() where user_id = auth.uid();
$$;
revoke all on function public.accept_privacy() from public, anon;
grant execute on function public.accept_privacy() to authenticated;

-- users panel
create or replace function public.admin_users()
returns table (
  user_id uuid, email text, created_at timestamptz, last_sign_in_at timestamptz,
  enabled boolean, use_shared_keys boolean, llm_calls_per_run int, privacy_accepted boolean,
  has_resume_docx boolean, ai_keys int, has_locations boolean, has_roles boolean,
  last_run_at timestamptz, last_run_status text, last_run_errors int, last_run_note text,
  jobs_total int, jobs_ready int, jobs_applied int, jobs_error int, open_batch int, storage_mb numeric
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Only @rajkumar.codes accounts can list users';
  end if;
  return query
  select
    u.id, u.email::text, u.created_at, u.last_sign_in_at,
    a.enabled, a.use_shared_keys, a.llm_calls_per_run, a.privacy_accepted_at is not null,
    exists (select 1 from storage.objects o where o.bucket_id = 'parent'
              and o.name like u.id::text || '/resume/%' and lower(o.name) like '%.docx'),
    (select count(*)::int from api_keys k where k.user_id = u.id and k.provider in ('gemini', 'groq', 'openrouter')),
    coalesce(cardinality(s.countries), 0) > 0,
    coalesce(cardinality(s.target_roles), 0) > 0 or coalesce(jsonb_array_length(p.titles), 0) > 0,
    r.started_at, r.status, r.errors,
    (select l from regexp_split_to_table(coalesce(r.log, ''), E'\n') l
      where l ~* 'skipping this user|stopping|paused|failed' limit 1),
    (select count(*)::int from jobs j where j.user_id = u.id),
    (select count(*)::int from jobs j where j.user_id = u.id and j.status = 'ready'),
    (select count(*)::int from jobs j where j.user_id = u.id and j.status = 'applied'),
    (select count(*)::int from jobs j where j.user_id = u.id and j.status = 'error'),
    (select b.number from batches b where b.user_id = u.id and b.status = 'processing' order by b.number desc limit 1),
    round(coalesce((select sum((o.metadata ->> 'size')::bigint) from storage.objects o
                     where o.bucket_id in ('parent', 'jobs') and o.name like u.id::text || '/%'), 0) / 1048576.0, 1)
  from auth.users u
  join accounts a on a.user_id = u.id
  left join settings s on s.user_id = u.id
  left join profile p on p.user_id = u.id
  left join lateral (select * from pipeline_runs pr where pr.user_id = u.id order by pr.started_at desc limit 1) r on true
  order by u.created_at;
end $$;
revoke all on function public.admin_users() from public, anon;
grant execute on function public.admin_users() to authenticated;

create or replace function public.admin_update_account(p_user uuid, p_enabled boolean, p_use_shared_keys boolean,
                                                       p_llm_calls_per_run int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Only @rajkumar.codes accounts can change users';
  end if;
  update accounts
     set enabled = p_enabled, use_shared_keys = p_use_shared_keys,
         llm_calls_per_run = greatest(5, least(p_llm_calls_per_run, 200))
   where user_id = p_user;
end $$;
revoke all on function public.admin_update_account(uuid, boolean, boolean, int) from public, anon;
grant execute on function public.admin_update_account(uuid, boolean, boolean, int) to authenticated;
