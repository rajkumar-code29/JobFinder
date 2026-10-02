-- Self-registration with admin approval. Until an admin approves an account it can't read or change anything.
-- Afterwards: Authentication > Sign In / Providers > turn ON "Allow new users to sign up".

-- registration details and approval status (existing users are approved, new ones wait)
alter table accounts add column if not exists status text not null default 'approved'
  check (status in ('pending', 'approved', 'rejected'));
alter table accounts alter column status set default 'pending';
alter table accounts add column if not exists status_changed_at timestamptz;
alter table accounts add column if not exists status_changed_by text;
alter table accounts add column if not exists first_name text;
alter table accounts add column if not exists last_name text;
alter table accounts add column if not exists phone text;
alter table accounts add column if not exists wants_mobile_app boolean;
alter table accounts add column if not exists mobile_platform text;

-- the app checks the exact rules; these stop junk sent straight to the API
alter table accounts drop constraint if exists accounts_first_name_check;
alter table accounts add constraint accounts_first_name_check
  check (first_name ~ '^[^[:digit:][:punct:][:space:][:cntrl:]]{1,50}$');
alter table accounts drop constraint if exists accounts_last_name_check;
alter table accounts add constraint accounts_last_name_check
  check (last_name ~ '^[^[:digit:][:punct:][:space:][:cntrl:]]{1,50}$');
alter table accounts drop constraint if exists accounts_phone_check;
alter table accounts add constraint accounts_phone_check check (phone ~ '^\+?[0-9]{7,15}$');
alter table accounts drop constraint if exists accounts_mobile_platform_check;
alter table accounts add constraint accounts_mobile_platform_check
  check (mobile_platform is null or (mobile_platform in ('ios', 'android') and wants_mobile_app is true));
alter table accounts drop constraint if exists accounts_mobile_choice_check;
alter table accounts add constraint accounts_mobile_choice_check
  check (wants_mobile_app is not true or mobile_platform is not null);

-- new users: copy the sign-up form (user metadata) into accounts
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.accounts (user_id, first_name, last_name, phone, wants_mobile_app, mobile_platform)
  values (new.id, nullif(trim(m ->> 'first_name'), ''), nullif(trim(m ->> 'last_name'), ''),
          nullif(trim(m ->> 'phone'), ''),
          case m ->> 'wants_mobile_app' when 'true' then true when 'false' then false end,
          nullif(m ->> 'mobile_platform', ''))
  on conflict do nothing;
  insert into public.settings (user_id) values (new.id) on conflict do nothing;
  insert into public.profile  (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;

create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from accounts where user_id = auth.uid() and status = 'approved')
$$;
revoke all on function public.is_approved() from public, anon;
grant execute on function public.is_approved() to authenticated;

-- anyone can register an @rajkumar.codes address now, so admin also needs an approved account
create or replace function public.is_admin() returns boolean
language sql stable as $$
  select coalesce(auth.jwt() ->> 'email', '') ilike '%@rajkumar.codes' and public.is_approved()
$$;

-- the gate: restrictive policies are ANDed with the existing ones
do $$
declare t text;
begin
  foreach t in array array['settings', 'profile', 'jobs', 'pipeline_runs', 'agent_runs', 'api_keys', 'batches',
                           'model_feedback', 'agent_control'] loop
    execute format('drop policy if exists "approved users only" on public.%I', t);
    execute format('create policy "approved users only" on public.%I as restrictive for all to authenticated '
                   'using ((select public.is_approved())) with check ((select public.is_approved()))', t);
  end loop;
end $$;

drop policy if exists "approved users only" on storage.objects;
create policy "approved users only" on storage.objects as restrictive for all to authenticated
  using (bucket_id not in ('parent', 'jobs') or (select public.is_approved()))
  with check (bucket_id not in ('parent', 'jobs') or (select public.is_approved()));

-- admins see every account (live pending count on Home); users still see only their own
drop policy if exists "admin read accounts" on accounts;
create policy "admin read accounts" on accounts for select to authenticated using (public.is_admin());

do $$ begin
  alter publication supabase_realtime add table accounts;
exception when others then null; end $$;

create or replace function public.admin_set_status(p_user uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Only @rajkumar.codes accounts can approve users';
  end if;
  if p_status not in ('pending', 'approved', 'rejected') then
    raise exception 'Unknown status %', p_status;
  end if;
  if p_user = auth.uid() and p_status <> 'approved' then
    raise exception 'You can''t remove your own access';
  end if;
  update accounts
     set status = p_status, status_changed_at = now(), status_changed_by = auth.jwt() ->> 'email'
   where user_id = p_user;
end $$;
revoke all on function public.admin_set_status(uuid, text) from public, anon;
grant execute on function public.admin_set_status(uuid, text) to authenticated;

-- users panel: same as 007 plus the registration details
drop function if exists public.admin_users();
create function public.admin_users()
returns table (
  user_id uuid, email text, created_at timestamptz, last_sign_in_at timestamptz,
  enabled boolean, use_shared_keys boolean, llm_calls_per_run int, privacy_accepted boolean,
  has_resume_docx boolean, ai_keys int, has_locations boolean, has_roles boolean,
  last_run_at timestamptz, last_run_status text, last_run_errors int, last_run_note text,
  jobs_total int, jobs_ready int, jobs_applied int, jobs_error int, open_batch int, storage_mb numeric,
  status text, first_name text, last_name text, phone text, wants_mobile_app boolean, mobile_platform text,
  email_confirmed boolean
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
                     where o.bucket_id in ('parent', 'jobs') and o.name like u.id::text || '/%'), 0) / 1048576.0, 1),
    a.status, a.first_name, a.last_name, a.phone, a.wants_mobile_app, a.mobile_platform,
    u.email_confirmed_at is not null
  from auth.users u
  join accounts a on a.user_id = u.id
  left join settings s on s.user_id = u.id
  left join profile p on p.user_id = u.id
  left join lateral (select * from pipeline_runs pr where pr.user_id = u.id order by pr.started_at desc limit 1) r on true
  order by u.created_at;
end $$;
revoke all on function public.admin_users() from public, anon;
grant execute on function public.admin_users() to authenticated;
