-- Base schema. The app signs in as a normal user, the pipeline uses the service-role key.

create extension if not exists pgcrypto;

-- settings (single row until 002)
create table if not exists settings (
  id              int primary key default 1 check (id = 1),
  countries       text[]  not null default array['us','gb','in'],       -- ISO-3166 alpha-2, lower case
  target_roles    text[]  not null default array[]::text[],             -- e.g. {"Flutter Developer","Mobile Engineer"}; empty = derive from resume
  keywords        text[]  not null default array[]::text[],             -- extra must-consider keywords
  exclude_keywords text[] not null default array['intern','internship']::text[],
  job_boards      jsonb   not null default '[]'::jsonb,                  -- [{"url": "...", "enabled": true}]
  sources         jsonb   not null default '{"adzuna":true,"jsearch":true,"remotive":true,"arbeitnow":true,"google_search":true}'::jsonb,
  remote_ok       boolean not null default true,
  min_relevance   int     not null default 60,   -- Scout keeps jobs scoring >= this (0-100)
  target_ats      int     not null default 95,   -- Tailor aims for this ATS score
  max_jobs_per_run int    not null default 3,    -- jobs fully processed per hourly run (protects Gemini free-tier quota)
  updated_at      timestamptz not null default now()
);
insert into settings (id) values (1) on conflict do nothing;

-- profile: parsed parent resume + cover letter
create table if not exists profile (
  id                 int primary key default 1 check (id = 1),
  resume_filename    text not null default 'NA',   -- e.g. "RajKumarGK_Resume.docx" - tailored copies reuse this name
  resume_hash        text not null default 'NA',   -- re-parse only when the parent changes
  cover_letter_hash  text not null default 'NA',
  resume_text        text not null default 'NA',
  cover_letter_text  text not null default 'NA',
  summary            text not null default 'NA',
  skills             jsonb not null default '[]'::jsonb,   -- ["Flutter", "Dart", ...]
  titles             jsonb not null default '[]'::jsonb,   -- job titles the resume fits
  structured         jsonb not null default '{}'::jsonb,   -- full structured resume
  updated_at         timestamptz not null default now()
);
insert into profile (id) values (1) on conflict do nothing;

-- jobs: one row per posting, 'NA' for anything missing
create table if not exists jobs (
  id               uuid primary key default gen_random_uuid(),
  job_id           text not null unique,               -- human id, also the storage directory name, e.g. JF-20260927-8K2QX
  source           text not null,
  external_id      text not null,
  title            text not null default 'NA',
  company          text not null default 'NA',
  location         text not null default 'NA',
  country          text not null default 'NA',
  remote           text not null default 'NA',
  employment_type  text not null default 'NA',
  url              text not null default 'NA',
  apply_url        text not null default 'NA',
  description      text not null default 'NA',
  salary_text      text not null default 'NA',          -- human readable, e.g. "USD 120,000 - 150,000 / year"
  salary_min       numeric,
  salary_max       numeric,
  salary_currency  text not null default 'NA',
  salary_source    text not null default 'NA',          -- 'job_posting' | 'estimate:<site>' | 'NA'
  posted_at        text not null default 'NA',
  relevance        int,                                 -- Scout 0-100
  relevance_reason text not null default 'NA',
  ats_score        int,                                 -- parent resume vs JD
  shortlist_probability int,
  tailored_ats_score int,                               -- tailored resume vs JD
  added_skills     jsonb not null default '[]'::jsonb,  -- adjacent skills the Tailor added: REVIEW before applying
  files            jsonb not null default '{}'::jsonb,  -- {"resume_docx": "JF-.../Name.docx", ...}
  meta             jsonb not null default '{}'::jsonb,  -- source extras, salary sources, etc.
  status           text not null default 'new'
                   check (status in ('new','scored','tailored','ready','applied','error','skipped')),
  error            text,
  attempts         int not null default 0,          -- processing attempts; gives up after 3
  applied_at       timestamptz,
  applied_with     text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (source, external_id)
);
create index if not exists jobs_status_idx on jobs(status);
create index if not exists jobs_created_idx on jobs(created_at desc);

-- runs and agent task log (dashboard)
create table if not exists pipeline_runs (
  id            uuid primary key default gen_random_uuid(),
  trigger       text not null default 'schedule',
  status        text not null default 'running' check (status in ('running','success','error')),
  jobs_scanned  int not null default 0,     -- raw postings fetched from all sources
  jobs_matched  int not null default 0,     -- kept by Scout
  jobs_processed int not null default 0,    -- fully processed (tailored etc.)
  errors        int not null default 0,
  log           text,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz
);

create table if not exists agent_runs (
  id           uuid primary key default gen_random_uuid(),
  pipeline_run uuid references pipeline_runs(id) on delete cascade,
  agent        text not null,   -- profile | scout | salary | scorer | tailor | coach | writer
  job_id       text,
  status       text not null default 'running' check (status in ('running','success','error')),
  message      text,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz
);
create index if not exists agent_runs_started_idx on agent_runs(started_at desc);
create index if not exists agent_runs_status_idx on agent_runs(status);

-- dashboard numbers
create or replace view dashboard_stats as
select
  (select coalesce(sum(jobs_scanned),0) from pipeline_runs)                       as total_scanned,
  (select count(*) from jobs)                                                      as total_matched,
  (select count(*) from jobs where status = 'ready')                              as ready,
  (select count(*) from jobs where status = 'applied')                            as applied,
  (select count(*) from agent_runs where status = 'error')                        as total_errors,
  (select count(*) from agent_runs where status = 'error'
      and started_at > now() - interval '24 hours')                               as errors_24h,
  (select count(*) from agent_runs where status = 'running'
      and started_at > now() - interval '2 hours')                                as agents_running,
  (select max(started_at) from pipeline_runs)                                      as last_run_at;

-- updated_at triggers
create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists jobs_touch on jobs;
create trigger jobs_touch before update on jobs for each row execute function touch_updated_at();
drop trigger if exists settings_touch on settings;
create trigger settings_touch before update on settings for each row execute function touch_updated_at();

-- RLS (replaced by per-user policies in 002)
alter table settings      enable row level security;
alter table profile       enable row level security;
alter table jobs          enable row level security;
alter table pipeline_runs enable row level security;
alter table agent_runs    enable row level security;

drop policy if exists "auth read settings" on settings;
create policy "auth read settings"  on settings  for select to authenticated using (true);
drop policy if exists "auth write settings" on settings;
create policy "auth write settings" on settings  for update to authenticated using (true) with check (true);
drop policy if exists "auth read profile" on profile;
create policy "auth read profile"   on profile   for select to authenticated using (true);
drop policy if exists "auth read jobs" on jobs;
create policy "auth read jobs"      on jobs      for select to authenticated using (true);
drop policy if exists "auth update jobs" on jobs;
create policy "auth update jobs"    on jobs      for update to authenticated using (true) with check (true);
drop policy if exists "auth read runs" on pipeline_runs;
create policy "auth read runs"      on pipeline_runs for select to authenticated using (true);
drop policy if exists "auth read agent runs" on agent_runs;
create policy "auth read agent runs" on agent_runs for select to authenticated using (true);

alter view dashboard_stats set (security_invoker = true);

-- realtime
do $$ begin
  alter publication supabase_realtime add table agent_runs, pipeline_runs, jobs;
exception when others then null; end $$;

-- private buckets: parent/ for the master documents, jobs/ for generated files
insert into storage.buckets (id, name, public) values ('parent','parent',false) on conflict do nothing;
insert into storage.buckets (id, name, public) values ('jobs','jobs',false)     on conflict do nothing;

drop policy if exists "auth read parent" on storage.objects;
create policy "auth read parent"  on storage.objects for select to authenticated using (bucket_id in ('parent','jobs'));
drop policy if exists "auth upload parent" on storage.objects;
create policy "auth upload parent" on storage.objects for insert to authenticated with check (bucket_id = 'parent');
drop policy if exists "auth replace parent" on storage.objects;
create policy "auth replace parent" on storage.objects for update to authenticated using (bucket_id = 'parent');
drop policy if exists "auth delete parent" on storage.objects;
create policy "auth delete parent" on storage.objects for delete to authenticated using (bucket_id = 'parent');
