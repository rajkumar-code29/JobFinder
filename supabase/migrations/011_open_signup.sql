-- Open sign-up: no more admin approval. People verify their email, agree to the privacy notice in the app, and
-- they're in. Admins can still block an account (status 'rejected'). Users can no longer add their own API keys;
-- existing keys stay and everyone also gets the shared keys.
-- Afterwards: Authentication > Sign In / Providers > Email > turn ON "Confirm email", and set up custom SMTP.

alter table accounts alter column status set default 'approved';
update accounts set status = 'approved', status_changed_at = now(), status_changed_by = 'open sign-up'
where status = 'pending';

-- "approved" now means: email verified and not blocked
create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from accounts a join auth.users u on u.id = a.user_id
                 where a.user_id = auth.uid() and a.status = 'approved' and u.email_confirmed_at is not null)
$$;

-- privacy notice versions: the app asks again when the notice changes
alter table accounts add column if not exists privacy_version int not null default 0;
update accounts set privacy_version = 1 where privacy_accepted_at is not null and privacy_version = 0;

create or replace function public.accept_privacy(p_version int) returns void
language sql security definer set search_path = public as $$
  update accounts set privacy_accepted_at = now(), privacy_version = greatest(p_version, privacy_version)
  where user_id = auth.uid();
$$;
revoke all on function public.accept_privacy(int) from public, anon;
grant execute on function public.accept_privacy(int) to authenticated;

-- everyone runs on the shared keys now (their own existing keys are still tried first)
alter table accounts alter column use_shared_keys set default true;
update accounts set use_shared_keys = true where not use_shared_keys;

-- only admins add keys from now on; existing rows are untouched
drop policy if exists "only admins add keys" on api_keys;
create policy "only admins add keys" on api_keys as restrictive for insert to authenticated
  with check (public.is_admin());
