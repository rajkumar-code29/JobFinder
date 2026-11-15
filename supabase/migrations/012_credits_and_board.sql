-- Credits, referrals, work on request, and the shared Jobs board.
--
-- Matching stays free: the hourly agents still find and score jobs for everyone. A tailored resume + cover letter
-- (1 credit) or interview prep (1 credit) only happens when the user asks. Asking holds the credits; they're taken
-- when the work succeeds and released if it fails, so a failed job never costs anything and the balance can't go
-- below zero.
--
-- New accounts start with 0 credits. Credits come from referrals (30 for the new user and 30 for the person whose
-- code they used), purchases, or an admin. To stop the same person collecting referral credits again by deleting
-- and re-registering, a one-way hash of each (normalised) email is kept for good, even after the account is gone.

-- credits
alter table accounts add column if not exists credits int not null default 0;
alter table accounts alter column credits set default 0;
alter table accounts drop constraint if exists accounts_credits_check;
alter table accounts add constraint accounts_credits_check check (credits >= 0);

create table if not exists credit_ledger (
  id            bigserial primary key,
  user_id       uuid references auth.users(id) on delete set null,   -- kept (anonymised) for the accounts
  delta         int  not null,
  balance_after int  not null,
  reason        text not null check (reason in ('welcome', 'referral', 'spend', 'purchase', 'admin', 'refund')),
  job_id        text,
  request_id    bigint,
  note          text,
  created_by    text,
  at            timestamptz not null default now()
);
create index if not exists credit_ledger_user_idx on credit_ledger(user_id, at desc);
alter table credit_ledger enable row level security;
drop policy if exists "own ledger read" on credit_ledger;
create policy "own ledger read" on credit_ledger for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on credit_ledger from anon, authenticated;
grant select on credit_ledger to authenticated;

-- emails as one-way hashes. "Raj.Kumar+jobs@Gmail.com" and "rajkumar@googlemail.com" are the same person.
create or replace function public.normalize_email(p_email text) returns text
language plpgsql immutable as $$
declare
  e      text := lower(trim(coalesce(p_email, '')));
  local  text := split_part(e, '@', 1);
  domain text := split_part(e, '@', 2);
begin
  local := split_part(local, '+', 1);
  if domain in ('gmail.com', 'googlemail.com') then
    local := replace(local, '.', '');
    domain := 'gmail.com';
  end if;
  return local || '@' || domain;
end $$;

create or replace function public.email_hash(p_email text) returns text
language sql immutable as $$
  select encode(sha256(convert_to(public.normalize_email(p_email), 'UTF8')), 'hex')
$$;

create table if not exists email_ledger (
  email_hash           text primary key,
  first_seen           timestamptz not null default now(),
  referral_rewarded_at timestamptz,          -- this address already got sign-up credits once
  deleted_at           timestamptz
);
alter table email_ledger enable row level security;
revoke all on email_ledger from anon, authenticated;

-- throwaway inboxes don't get referral credits
create table if not exists disposable_domains (domain text primary key);
alter table disposable_domains enable row level security;
revoke all on disposable_domains from anon, authenticated;
insert into disposable_domains (domain) values
  ('mailinator.com'), ('guerrillamail.com'), ('guerrillamail.net'), ('sharklasers.com'), ('grr.la'),
  ('10minutemail.com'), ('10minutemail.net'), ('tempmail.com'), ('temp-mail.org'), ('tempmail.net'),
  ('tempmailo.com'), ('yopmail.com'), ('yopmail.net'), ('trashmail.com'), ('trashmail.de'), ('getnada.com'),
  ('nada.email'), ('dispostable.com'), ('maildrop.cc'), ('mailnesia.com'), ('mintemail.com'), ('mohmal.com'),
  ('throwawaymail.com'), ('fakeinbox.com'), ('emailondeck.com'), ('spamgourmet.com'), ('mailcatch.com'),
  ('moakt.com'), ('tempr.email'), ('discard.email'), ('burnermail.io'), ('33mail.com'), ('mail.tm'),
  ('inboxkitten.com'), ('linshiyouxiang.net'), ('emailfake.com'), ('crazymailing.com'), ('tempinbox.com'),
  ('mailpoof.com'), ('luxusmail.org'), ('owlymail.com'), ('1secmail.com'), ('1secmail.net'), ('1secmail.org')
on conflict do nothing;

-- referral codes: 8 characters without look-alikes (no 0/O, 1/I/L)
alter table accounts add column if not exists referral_code text;
alter table accounts add column if not exists referred_by_code text;
alter table accounts add column if not exists referral_status text;   -- null until checked, then none / rewarded / declined:<why>
create unique index if not exists accounts_referral_code_idx on accounts(referral_code);

create or replace function public.new_referral_code() returns text
language plpgsql volatile set search_path = public as $$
declare v text;
begin
  loop
    v := (select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '')
          from generate_series(1, 8));
    exit when not exists (select 1 from accounts where referral_code = v);
  end loop;
  return v;
end $$;

update accounts set referral_code = public.new_referral_code() where referral_code is null;

create table if not exists referrals (
  id         bigserial primary key,
  referrer   uuid references auth.users(id) on delete set null,
  referee    uuid references auth.users(id) on delete set null,
  code       text not null,
  status     text not null check (status in ('rewarded', 'declined')),
  reason     text,
  created_at timestamptz not null default now()
);
create index if not exists referrals_referrer_idx on referrals(referrer, status, created_at);
alter table referrals enable row level security;
drop policy if exists "own referrals read" on referrals;
create policy "own referrals read" on referrals for select to authenticated using (referrer = auth.uid() or referee = auth.uid());
revoke insert, update, delete on referrals from anon, authenticated;
grant select on referrals to authenticated;

-- people who were here before referrals keep 30 starting credits, once; their emails count as rewarded
update accounts a set credits = credits + 30
where not exists (select 1 from credit_ledger l where l.user_id = a.user_id and l.reason = 'welcome');
insert into credit_ledger (user_id, delta, balance_after, reason, note)
select a.user_id, 30, a.credits, 'welcome', 'Starting credits'
from accounts a
where not exists (select 1 from credit_ledger l where l.user_id = a.user_id and l.reason = 'welcome');
insert into email_ledger (email_hash, referral_rewarded_at)
select distinct public.email_hash(u.email), now() from auth.users u join accounts a on a.user_id = u.id
on conflict (email_hash) do update set referral_rewarded_at = coalesce(email_ledger.referral_rewarded_at, now());

-- new users: a code of their own, the code they signed up with, and their email remembered (as a hash)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.accounts (user_id, first_name, last_name, phone, wants_mobile_app, mobile_platform,
                               referral_code, referred_by_code)
  values (new.id, nullif(trim(m ->> 'first_name'), ''), nullif(trim(m ->> 'last_name'), ''),
          nullif(trim(m ->> 'phone'), ''),
          case m ->> 'wants_mobile_app' when 'true' then true when 'false' then false end,
          nullif(m ->> 'mobile_platform', ''), public.new_referral_code(),
          nullif(upper(regexp_replace(coalesce(m ->> 'referral_code', ''), '[^A-Za-z0-9]', '', 'g')), ''))
  on conflict do nothing;
  insert into public.email_ledger (email_hash) values (public.email_hash(new.email)) on conflict do nothing;
  insert into public.settings (user_id) values (new.id) on conflict do nothing;
  insert into public.profile  (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;

-- deleting an account (from the app or the dashboard) leaves only the email hash behind
create or replace function public.handle_deleted_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.email_ledger (email_hash, deleted_at) values (public.email_hash(old.email), now())
  on conflict (email_hash) do update set deleted_at = now();
  return old;
end $$;
drop trigger if exists on_auth_user_deleted on auth.users;
create trigger on_auth_user_deleted before delete on auth.users
  for each row execute function public.handle_deleted_user();

-- give referral credits, once per email, with limits per code. Runs when the new user first agrees to the privacy
-- notice (their email is verified by then), or when they type a code in later.
create or replace function public.redeem_referral() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid      uuid := auth.uid();
  a          accounts;
  v_email    text;
  v_hash     text;
  v_referrer accounts;
  v_ref_mail text;
  v_reason   text;
  v_bal      int;
begin
  select * into a from accounts where user_id = v_uid for update;
  if not found or a.referral_status is not null and a.referral_status not in ('none', 'declined:invalid_code') then
    return jsonb_build_object('status', coalesce(a.referral_status, 'none'));
  end if;
  if coalesce(a.referred_by_code, '') = '' then
    update accounts set referral_status = 'none' where user_id = v_uid;
    return jsonb_build_object('status', 'none');
  end if;
  select email into v_email from auth.users where id = v_uid and email_confirmed_at is not null;
  v_hash := public.email_hash(v_email);
  select * into v_referrer from accounts where referral_code = a.referred_by_code and user_id <> v_uid
    and status = 'approved';
  select email into v_ref_mail from auth.users where id = v_referrer.user_id;

  v_reason := case
    when v_email is null then 'email_not_verified'
    when v_referrer.user_id is null then 'invalid_code'
    when public.email_hash(v_ref_mail) = v_hash then 'self'
    when exists (select 1 from email_ledger where email_hash = v_hash and referral_rewarded_at is not null) then 'email_used'
    when split_part(public.normalize_email(v_email), '@', 2) in (select domain from disposable_domains) then 'disposable_email'
    when (select count(*) from referrals where referrer = v_referrer.user_id and status = 'rewarded') >= 20 then 'referrer_limit'
    when (select count(*) from referrals where referrer = v_referrer.user_id and status = 'rewarded'
          and created_at > now() - interval '1 day') >= 5 then 'referrer_daily_limit'
  end;

  if v_reason is not null then
    if v_reason <> 'email_not_verified' then
      insert into referrals (referrer, referee, code, status, reason)
      values (v_referrer.user_id, v_uid, a.referred_by_code, 'declined', v_reason);
      update accounts set referral_status = 'declined:' || v_reason where user_id = v_uid;
    end if;
    return jsonb_build_object('status', 'declined', 'reason', v_reason);
  end if;

  update accounts set credits = credits + 30, referral_status = 'rewarded' where user_id = v_uid returning credits into v_bal;
  insert into credit_ledger (user_id, delta, balance_after, reason, note)
  values (v_uid, 30, v_bal, 'referral', 'Joined with a friend''s code');
  update accounts set credits = credits + 30 where user_id = v_referrer.user_id returning credits into v_bal;
  insert into credit_ledger (user_id, delta, balance_after, reason, note)
  values (v_referrer.user_id, 30, v_bal, 'referral', 'A friend joined with your code');
  insert into referrals (referrer, referee, code, status) values (v_referrer.user_id, v_uid, a.referred_by_code, 'rewarded');
  insert into email_ledger (email_hash, referral_rewarded_at) values (v_hash, now())
  on conflict (email_hash) do update set referral_rewarded_at = now();
  return jsonb_build_object('status', 'rewarded', 'credits', 30);
end $$;
revoke all on function public.redeem_referral() from public, anon, authenticated;

-- agreeing to the privacy notice also settles the referral (it can't block the agreement)
create or replace function public.accept_privacy(p_version int) returns void
language plpgsql security definer set search_path = public as $$
begin
  update accounts set privacy_accepted_at = now(), privacy_version = greatest(p_version, privacy_version)
  where user_id = auth.uid();
  begin
    perform public.redeem_referral();
  exception when others then
    null;
  end;
end $$;
revoke all on function public.accept_privacy(int) from public, anon;
grant execute on function public.accept_privacy(int) to authenticated;

-- forgot the code at sign-up? It can still be entered within 7 days, once
create or replace function public.apply_referral_code(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a      accounts;
  v_code text := nullif(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), '');
begin
  if auth.uid() is null or not public.is_approved() then
    raise exception 'Your account needs to be verified first';
  end if;
  select * into a from accounts where user_id = auth.uid();
  if v_code is null then
    raise exception 'Enter a referral code';
  end if;
  if coalesce(a.referral_status, 'none') not in ('none', 'declined:invalid_code') then
    raise exception 'A referral code has already been used on this account';
  end if;
  if (select created_at from auth.users where id = auth.uid()) < now() - interval '7 days' then
    raise exception 'Referral codes can only be added in the first 7 days';
  end if;
  -- a typo shouldn't use up the one chance
  if not exists (select 1 from accounts where referral_code = v_code and user_id <> auth.uid()) then
    raise exception 'That code doesn''t exist. Check it with the person who shared it';
  end if;
  update accounts set referred_by_code = v_code, referral_status = null where user_id = auth.uid();
  return public.redeem_referral();
end $$;
revoke all on function public.apply_referral_code(text) from public, anon;
grant execute on function public.apply_referral_code(text) to authenticated;

create or replace function public.regenerate_referral_code() returns text
language plpgsql security definer set search_path = public as $$
declare v text := public.new_referral_code();
begin
  update accounts set referral_code = v where user_id = auth.uid();
  return v;
end $$;
revoke all on function public.regenerate_referral_code() from public, anon;
grant execute on function public.regenerate_referral_code() to authenticated;

-- your code and how it's going
create or replace function public.my_referrals()
returns table (code text, rewarded int, earned int, used_code text, status text, can_add_code boolean)
language sql stable security definer set search_path = public as $$
  select a.referral_code,
         (select count(*)::int from referrals r where r.referrer = a.user_id and r.status = 'rewarded'),
         (select coalesce(sum(delta), 0)::int from credit_ledger l where l.user_id = a.user_id and l.reason = 'referral'),
         a.referred_by_code, a.referral_status,
         coalesce(a.referral_status, 'none') in ('none', 'declined:invalid_code')
           and (select created_at from auth.users where id = a.user_id) > now() - interval '7 days'
  from accounts a where a.user_id = auth.uid()
$$;
revoke all on function public.my_referrals() from public, anon;
grant execute on function public.my_referrals() to authenticated;

-- admin: every referral, including the declined ones and why, to spot abuse
create or replace function public.admin_referrals(p_limit int default 200)
returns table (created_at timestamptz, referrer_email text, referee_email text, code text, status text, reason text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Admins only';
  end if;
  return query
    select r.created_at, coalesce(u1.email::text, '(deleted)'), coalesce(u2.email::text, '(deleted)'), r.code, r.status, r.reason
    from referrals r
    left join auth.users u1 on u1.id = r.referrer
    left join auth.users u2 on u2.id = r.referee
    order by r.created_at desc limit least(greatest(p_limit, 1), 1000);
end $$;
revoke all on function public.admin_referrals(int) from public, anon;
grant execute on function public.admin_referrals(int) to authenticated;

-- work requests: score (free), tailor = resume + cover letter (1), interview (1)
create table if not exists job_requests (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  job_id      text not null,
  kind        text not null check (kind in ('score', 'tailor', 'interview')),
  cost        int  not null default 0 check (cost >= 0),
  status      text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed', 'cancelled')),
  error_code  text,
  error       text,
  created_at  timestamptz not null default now(),
  started_at  timestamptz,
  finished_at timestamptz
);
create unique index if not exists job_requests_active_idx on job_requests(job_id, kind) where status in ('queued', 'running');
create index if not exists job_requests_user_idx on job_requests(user_id, status, created_at);
alter table job_requests enable row level security;
drop policy if exists "own requests read" on job_requests;
create policy "own requests read" on job_requests for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on job_requests from anon, authenticated;
grant select on job_requests to authenticated;
do $$ begin
  alter publication supabase_realtime add table job_requests;
exception when others then null; end $$;
do $$ begin
  alter publication supabase_realtime add table credit_ledger;
exception when others then null; end $$;

-- balance, held for queued work, and what's left to spend
create or replace function public.my_credits() returns table (credits int, held int, available int)
language sql stable security definer set search_path = public as $$
  select a.credits, h.held, a.credits - h.held
  from accounts a,
       lateral (select coalesce(sum(cost), 0)::int as held from job_requests
                where user_id = a.user_id and status in ('queued', 'running')) h
  where a.user_id = auth.uid()
$$;
revoke all on function public.my_credits() from public, anon;
grant execute on function public.my_credits() to authenticated;

create or replace function public.dispatch_work(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_token text;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'gh_dispatch_token';
  if v_token is null then return; end if;  -- the hourly run picks queued work up anyway
  perform net.http_post(
    url     := 'https://api.github.com/repos/rajkumar-code29/JobFinder/actions/workflows/agents.yml/dispatches',
    body    := jsonb_build_object('ref', 'main', 'inputs',
                 jsonb_build_object('trigger', 'manual', 'all_sources', 'false', 'work', p_user::text)),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_token, 'Accept', 'application/vnd.github+json',
                 'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'pounce-app', 'Content-Type', 'application/json'));
end $$;
revoke all on function public.dispatch_work(uuid) from public, anon, authenticated;

create or replace function public.request_job_work(p_job_id text, p_kinds text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_job     jobs;
  v_kind    text;
  v_new     text[] := '{}';
  v_cost    int := 0;
  v_credits int;
  v_held    int;
begin
  if v_uid is null or not public.is_approved() then
    raise exception 'Your account needs to be verified first';
  end if;
  select * into v_job from jobs where job_id = p_job_id and user_id = v_uid;
  if not found then
    raise exception 'Job not found';
  end if;
  foreach v_kind in array coalesce(p_kinds, '{}') loop
    if v_kind not in ('tailor', 'interview') then
      raise exception 'Unknown option %', v_kind;
    end if;
    continue when v_kind = 'tailor' and v_job.files ? 'resume_docx' and v_job.files ? 'cover_letter_docx';
    continue when v_kind = 'interview' and v_job.files ? 'interview';
    continue when exists (select 1 from job_requests where job_id = p_job_id and kind = v_kind
                          and status in ('queued', 'running'));
    continue when v_kind = any(v_new);
    v_new := v_new || v_kind;
    v_cost := v_cost + 1;
  end loop;
  -- a job has to be scored first; that part is free
  if v_job.status = 'new' and not exists (select 1 from job_requests where job_id = p_job_id and kind = 'score'
                                          and status in ('queued', 'running')) then
    v_new := array_prepend('score'::text, v_new);
  end if;
  if cardinality(v_new) = 0 then
    raise exception 'That''s already done or on its way';
  end if;

  select credits into v_credits from accounts where user_id = v_uid for update;
  select coalesce(sum(cost), 0) into v_held from job_requests where user_id = v_uid and status in ('queued', 'running');
  if v_credits - v_held < v_cost then
    raise exception 'Not enough credits: this needs %, and you have % to spend', v_cost, v_credits - v_held;
  end if;

  insert into job_requests (user_id, job_id, kind, cost)
  select v_uid, p_job_id, k, case when k = 'score' then 0 else 1 end from unnest(v_new) as k;
  perform public.dispatch_work(v_uid);
  return jsonb_build_object('queued', to_jsonb(v_new), 'cost', v_cost, 'available', v_credits - v_held - v_cost);
end $$;
revoke all on function public.request_job_work(text, text[]) from public, anon;
grant execute on function public.request_job_work(text, text[]) to authenticated;

create or replace function public.cancel_job_request(p_id bigint) returns void
language sql security definer set search_path = public as $$
  update job_requests set status = 'cancelled', finished_at = now()
  where id = p_id and user_id = auth.uid() and status = 'queued';
$$;
revoke all on function public.cancel_job_request(bigint) from public, anon;
grant execute on function public.cancel_job_request(bigint) to authenticated;

-- the pipeline (service key) closes a request: success takes the credit, failure releases it
create or replace function public.finish_job_request(p_id bigint, p_ok boolean, p_code text default null,
                                                     p_error text default null) returns int
language plpgsql security definer set search_path = public as $$
declare
  r     job_requests;
  v_bal int;
begin
  select * into r from job_requests where id = p_id for update;
  if not found or r.status not in ('queued', 'running') then
    return null;
  end if;
  if not p_ok then
    update job_requests set status = 'failed', error_code = coalesce(p_code, 'E_INTERNAL'),
                            error = left(p_error, 1000), finished_at = now()
    where id = p_id;
    return null;
  end if;
  update job_requests set status = 'done', finished_at = now() where id = p_id;
  if r.cost > 0 then
    -- holds mean the balance covers it; greatest() is only a guard
    update accounts set credits = greatest(credits - r.cost, 0) where user_id = r.user_id returning credits into v_bal;
    insert into credit_ledger (user_id, delta, balance_after, reason, job_id, request_id, note)
    values (r.user_id, -r.cost, v_bal, 'spend', r.job_id, r.id,
            case r.kind when 'tailor' then 'Tailored resume and cover letter' else 'Interview prep' end);
  end if;
  return v_bal;
end $$;
revoke all on function public.finish_job_request(bigint, boolean, text, text) from public, anon, authenticated;

-- admin: find people and give or take credits
create or replace function public.admin_search_users(p_query text default '')
returns table (user_id uuid, email text, first_name text, last_name text, credits int, status text,
               created_at timestamptz, last_sign_in_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Admins only';
  end if;
  return query
    select a.user_id, u.email::text, a.first_name, a.last_name, a.credits, a.status, u.created_at, u.last_sign_in_at
    from accounts a join auth.users u on u.id = a.user_id
    where coalesce(p_query, '') = ''
       or u.email ilike '%' || p_query || '%'
       or (coalesce(a.first_name, '') || ' ' || coalesce(a.last_name, '')) ilike '%' || p_query || '%'
    order by u.created_at desc
    limit 50;
end $$;
revoke all on function public.admin_search_users(text) from public, anon;
grant execute on function public.admin_search_users(text) to authenticated;

create or replace function public.admin_add_credits(p_user uuid, p_amount int, p_note text default null) returns int
language plpgsql security definer set search_path = public as $$
declare v_bal int;
begin
  if not public.is_admin() then
    raise exception 'Admins only';
  end if;
  if p_amount = 0 or abs(p_amount) > 10000 then
    raise exception 'Use an amount between -10000 and 10000, not 0';
  end if;
  begin
    update accounts set credits = credits + p_amount where user_id = p_user returning credits into v_bal;
  exception when check_violation then
    raise exception 'That would take them below zero';
  end;
  if v_bal is null then
    raise exception 'User not found';
  end if;
  insert into credit_ledger (user_id, delta, balance_after, reason, note, created_by)
  values (p_user, p_amount, v_bal, 'admin', nullif(trim(coalesce(p_note, '')), ''), auth.jwt() ->> 'email');
  return v_bal;
end $$;
revoke all on function public.admin_add_credits(uuid, int, text) from public, anon;
grant execute on function public.admin_add_credits(uuid, int, text) to authenticated;

-- the shared board: every posting the scouts fetch, de-duplicated, kept for 30 days
create table if not exists postings (
  id              bigserial primary key,
  source          text not null,
  external_id     text not null,
  title           text not null,
  company         text not null default 'NA',
  location        text not null default 'NA',
  country         text not null default 'NA',
  remote          text not null default 'NA',
  employment_type text not null default 'NA',
  url             text not null default 'NA',
  apply_url       text not null default 'NA',
  description     text not null default 'NA',
  salary_text     text not null default 'NA',
  salary_min      numeric,
  salary_max      numeric,
  salary_currency text not null default 'NA',
  posted_at       text not null default 'NA',
  added_by        text not null default 'scout',
  first_seen      timestamptz not null default now(),
  last_seen       timestamptz not null default now(),
  search          tsvector generated always as (
                    setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
                    setweight(to_tsvector('english', coalesce(company, '')), 'B') ||
                    setweight(to_tsvector('english', left(coalesce(description, ''), 6000)), 'C')) stored,
  unique (source, external_id)
);
create index if not exists postings_search_idx on postings using gin(search);
create index if not exists postings_first_seen_idx on postings(first_seen desc);
alter table postings enable row level security;
drop policy if exists "verified users read the board" on postings;
create policy "verified users read the board" on postings for select to authenticated using ((select public.is_approved()));
revoke insert, update, delete on postings from anon, authenticated;
grant select on postings to authenticated;

create or replace function public.board_search(
  p_query text default '', p_location text default '', p_remote text default '', p_type text default '',
  p_days int default 0, p_salary_min numeric default null, p_source text default '', p_sort text default 'newest',
  p_limit int default 30, p_offset int default 0)
returns table (id bigint, source text, title text, company text, location text, country text, remote text,
               employment_type text, url text, apply_url text, salary_text text, salary_min numeric,
               salary_max numeric, salary_currency text, posted_at text, first_seen timestamptz, snippet text,
               my_match int, my_job_id text, total bigint)
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_q   tsquery := case when trim(coalesce(p_query, '')) = '' then null
                        else websearch_to_tsquery('english', p_query) end;
begin
  if v_uid is null or not public.is_approved() then
    raise exception 'Your account needs to be verified first';
  end if;
  return query
    with hits as (
      select p.*,
             (select s.relevance from seen_postings s
              where s.user_id = v_uid and s.source = p.source and s.external_id = p.external_id
                and s.context <> '*' order by s.seen_at desc limit 1) as match,
             (select j.job_id from jobs j
              where j.user_id = v_uid and j.source = p.source and j.external_id = p.external_id limit 1) as mine,
             case when v_q is null then 0 else ts_rank(p.search, v_q) end as rank
      from postings p
      where (v_q is null or p.search @@ v_q)
        and (coalesce(p_location, '') = '' or p.location ilike '%' || p_location || '%'
             or p.country ilike '%' || p_location || '%')
        and (coalesce(p_remote, '') = '' or p.remote ilike '%' || p_remote || '%'
             or (p_remote = 'remote' and (p.location ilike '%remote%' or p.title ilike '%remote%')))
        and (coalesce(p_type, '') = '' or p.employment_type ilike '%' || p_type || '%'
             or p.title ilike '%' || p_type || '%')
        and (coalesce(p_days, 0) = 0 or p.first_seen > now() - make_interval(days => p_days))
        and (p_salary_min is null or coalesce(p.salary_max, p.salary_min) >= p_salary_min)
        and (coalesce(p_source, '') = '' or p.source = p_source)
    )
    select h.id, h.source, h.title, h.company, h.location, h.country, h.remote, h.employment_type, h.url,
           h.apply_url, h.salary_text, h.salary_min, h.salary_max, h.salary_currency, h.posted_at, h.first_seen,
           left(regexp_replace(h.description, '\s+', ' ', 'g'), 280), h.match, h.mine, count(*) over ()
    from hits h
    order by case when p_sort = 'match' then coalesce(h.match, -1) end desc nulls last,
             case when p_sort = 'relevance' then h.rank end desc nulls last,
             h.first_seen desc
    limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
end $$;
revoke all on function public.board_search(text, text, text, text, int, numeric, text, text, int, int) from public, anon;
grant execute on function public.board_search(text, text, text, text, int, numeric, text, text, int, int) to authenticated;

-- one posting with its full description (and the caller's match, if rated)
create or replace function public.board_posting(p_id bigint)
returns table (posting jsonb, my_match int, my_job_id text)
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or not public.is_approved() then
    raise exception 'Your account needs to be verified first';
  end if;
  return query
    select to_jsonb(p) - 'search',
           (select s.relevance from seen_postings s where s.user_id = v_uid and s.source = p.source
              and s.external_id = p.external_id and s.context <> '*' order by s.seen_at desc limit 1),
           (select j.job_id from jobs j where j.user_id = v_uid and j.source = p.source
              and j.external_id = p.external_id limit 1)
    from postings p where p.id = p_id;
end $$;
revoke all on function public.board_posting(bigint) from public, anon;
grant execute on function public.board_posting(bigint) to authenticated;

create or replace function public.new_job_id() returns text
language sql volatile set search_path = public as $$
  select 'JF-' || to_char(now() at time zone 'utc', 'YYYYMMDD') || '-'
         || (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
             from generate_series(1, 5))
$$;

-- save a board posting into your own jobs (so it can be scored, tailored and tracked)
create or replace function public.save_posting(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  p     postings;
  v_id  text;
  v_rel int;
begin
  if v_uid is null or not public.is_approved() then
    raise exception 'Your account needs to be verified first';
  end if;
  select * into p from postings where id = p_id;
  if not found then
    raise exception 'That job is no longer on the board';
  end if;
  select job_id into v_id from jobs where user_id = v_uid and source = p.source and external_id = p.external_id;
  if v_id is not null then
    return v_id;
  end if;
  select relevance into v_rel from seen_postings where user_id = v_uid and source = p.source
    and external_id = p.external_id and context <> '*' order by seen_at desc limit 1;
  v_id := public.new_job_id();
  insert into jobs (job_id, user_id, source, external_id, title, company, location, country, remote, employment_type,
                    url, apply_url, description, salary_text, salary_min, salary_max, salary_currency, posted_at,
                    relevance, relevance_reason, status)
  values (v_id, v_uid, p.source, p.external_id, p.title, p.company, p.location, p.country, p.remote,
          p.employment_type, p.url, p.apply_url, p.description, p.salary_text, p.salary_min, p.salary_max,
          p.salary_currency, p.posted_at, v_rel, 'Saved from the Jobs board', 'new');
  return v_id;
end $$;
revoke all on function public.save_posting(bigint) from public, anon;
grant execute on function public.save_posting(bigint) to authenticated;

-- admin: add a job by hand, to the board for everyone or straight into one person's jobs
create or replace function public.admin_add_job(p_title text, p_company text, p_description text,
                                                p_location text default null, p_url text default null,
                                                p_remote text default null, p_type text default null,
                                                p_salary text default null, p_user uuid default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ext text := 'M-' || replace(gen_random_uuid()::text, '-', '');
  v_url text := nullif(trim(coalesce(p_url, '')), '');
  v_id  text;
begin
  if not public.is_admin() then
    raise exception 'Admins only';
  end if;
  if length(trim(coalesce(p_title, ''))) < 2 or length(trim(coalesce(p_description, ''))) < 50 then
    raise exception 'Add a title and the full job description';
  end if;
  if v_url is not null and v_url !~* '^https?://' then
    v_url := 'https://' || v_url;
  end if;
  if p_user is null then
    insert into postings (source, external_id, title, company, location, remote, employment_type, url, apply_url,
                          description, salary_text, added_by)
    values ('manual', v_ext, left(trim(p_title), 300), coalesce(nullif(trim(coalesce(p_company, '')), ''), 'NA'),
            coalesce(nullif(trim(coalesce(p_location, '')), ''), 'NA'), coalesce(nullif(trim(coalesce(p_remote, '')), ''), 'NA'),
            coalesce(nullif(trim(coalesce(p_type, '')), ''), 'NA'), coalesce(v_url, 'NA'), coalesce(v_url, 'NA'),
            left(trim(p_description), 30000), coalesce(nullif(trim(coalesce(p_salary, '')), ''), 'NA'),
            coalesce(auth.jwt() ->> 'email', 'admin'));
    return 'board';
  end if;
  v_id := public.new_job_id();
  insert into jobs (job_id, user_id, source, external_id, title, company, location, remote, employment_type, url,
                    apply_url, description, salary_text, relevance_reason, status)
  values (v_id, p_user, 'manual', v_ext, left(trim(p_title), 300), coalesce(nullif(trim(coalesce(p_company, '')), ''), 'NA'),
          coalesce(nullif(trim(coalesce(p_location, '')), ''), 'NA'), coalesce(nullif(trim(coalesce(p_remote, '')), ''), 'NA'),
          coalesce(nullif(trim(coalesce(p_type, '')), ''), 'NA'), coalesce(v_url, 'NA'), coalesce(v_url, 'NA'),
          left(trim(p_description), 30000), coalesce(nullif(trim(coalesce(p_salary, '')), ''), 'NA'),
          'Added by an admin', 'new');
  return v_id;
end $$;
revoke all on function public.admin_add_job(text, text, text, text, text, text, text, text, uuid) from public, anon;
grant execute on function public.admin_add_job(text, text, text, text, text, text, text, text, uuid) to authenticated;
