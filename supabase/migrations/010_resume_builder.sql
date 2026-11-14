-- Resume builder: CV and cover letter drafts, plus a log of the builder's AI calls (the resume-ai Edge Function
-- writes it with the service key and uses it for a daily limit per user).

create table if not exists resume_drafts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('cv', 'letter')),
  title      text not null default 'Untitled',
  data       jsonb not null default '{}'::jsonb,   -- answers, mode, CV type, generated sections / letter parts
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists resume_drafts_user_idx on resume_drafts(user_id, updated_at desc);
alter table resume_drafts enable row level security;
drop policy if exists "own drafts" on resume_drafts;
create policy "own drafts" on resume_drafts for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "approved users only" on resume_drafts;
create policy "approved users only" on resume_drafts as restrictive for all to authenticated
  using ((select public.is_approved())) with check ((select public.is_approved()));
grant select, insert, update, delete on resume_drafts to authenticated;
drop trigger if exists resume_drafts_touch on resume_drafts;
create trigger resume_drafts_touch before update on resume_drafts for each row execute function touch_updated_at();

create table if not exists builder_usage (
  id      bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  action  text not null,
  model   text,
  ok      boolean not null default true,
  error   text,
  at      timestamptz not null default now()
);
create index if not exists builder_usage_user_idx on builder_usage(user_id, at desc);
alter table builder_usage enable row level security;
drop policy if exists "own usage read" on builder_usage;
create policy "own usage read" on builder_usage for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on builder_usage from anon, authenticated;
grant select on builder_usage to authenticated;

-- the builder gets its own row in the admin model routing editor
alter table model_routing drop constraint if exists model_routing_agent_check;
alter table model_routing add constraint model_routing_agent_check
  check (agent in ('profile', 'scout', 'salary', 'search', 'scorer', 'tailor', 'coach', 'writer', 'builder'));
