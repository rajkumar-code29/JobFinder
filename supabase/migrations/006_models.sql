-- JobFinder: per-agent model routing, model scorecard, 👍/👎 feedback and head-to-head comparisons.
-- Run once in the Supabase SQL editor after 005_batches_and_control.sql.

-- ---------------------------------------------------------------------------
-- More AI providers for API keys (Groq, OpenRouter)
-- ---------------------------------------------------------------------------
alter table api_keys drop constraint if exists api_keys_provider_check;
alter table api_keys add constraint api_keys_provider_check
  check (provider in ('gemini', 'groq', 'openrouter', 'adzuna', 'rapidapi'));
alter table shared_api_keys drop constraint if exists shared_api_keys_provider_check;
alter table shared_api_keys add constraint shared_api_keys_provider_check
  check (provider in ('gemini', 'groq', 'openrouter', 'adzuna', 'rapidapi'));

-- ---------------------------------------------------------------------------
-- Routing: ordered model list per agent, e.g. scout = {groq:openai/gpt-oss-120b, gemini:flash-lite}.
-- "gemini:flash" / "gemini:flash-lite" mean every available model of that family, newest first.
-- Agents without a row use the built-in defaults.
-- ---------------------------------------------------------------------------
create table if not exists model_routing (
  agent      text primary key check (agent in ('profile', 'scout', 'salary', 'search', 'scorer', 'tailor', 'coach', 'writer')),
  chain      text[] not null check (cardinality(chain) between 1 and 8),
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table model_routing enable row level security;
drop policy if exists "admin routing read" on model_routing;
create policy "admin routing read"   on model_routing for select to authenticated using (public.is_admin());
drop policy if exists "admin routing insert" on model_routing;
create policy "admin routing insert" on model_routing for insert to authenticated with check (public.is_admin());
drop policy if exists "admin routing update" on model_routing;
create policy "admin routing update" on model_routing for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin routing delete" on model_routing;
create policy "admin routing delete" on model_routing for delete to authenticated using (public.is_admin());

-- ---------------------------------------------------------------------------
-- Scorecard: per day / agent / model counters written by the pipeline.
-- ---------------------------------------------------------------------------
create table if not exists model_stats (
  day          date not null,
  agent        text not null,
  model        text not null,
  ok           int not null default 0,
  rate_limited int not null default 0,
  overloaded   int not null default 0,
  invalid_json int not null default 0,
  too_large    int not null default 0,
  errors       int not null default 0,
  ms           bigint not null default 0,   -- total time of successful calls
  primary key (day, agent, model)
);
alter table model_stats enable row level security;
drop policy if exists "admin stats read" on model_stats;
create policy "admin stats read" on model_stats for select to authenticated using (public.is_admin());
revoke insert, update, delete on model_stats from anon, authenticated;

-- 👍/👎 on a job's tailored resume, interview pack or cover letter (any user, for their own jobs).
create table if not exists model_feedback (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  job_id     text not null,
  agent      text not null check (agent in ('tailor', 'coach', 'writer')),
  model      text not null,
  rating     smallint not null check (rating in (-1, 1)),
  created_at timestamptz not null default now(),
  primary key (user_id, job_id, agent)
);
alter table model_feedback enable row level security;
drop policy if exists "own feedback" on model_feedback;
create policy "own feedback" on model_feedback for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.model_scorecard(p_days int default 14)
returns table (agent text, model text, ok bigint, rate_limited bigint, overloaded bigint, invalid_json bigint,
               too_large bigint, errors bigint, avg_seconds numeric, thumbs_up bigint, thumbs_down bigint)
language sql stable security definer set search_path = public as $$
  with s as (
    select agent, model, sum(ok) ok, sum(rate_limited) rl, sum(overloaded) ov, sum(invalid_json) ij,
           sum(too_large) tl, sum(errors) er, sum(ms) ms
    from model_stats where day >= current_date - p_days group by 1, 2),
  f as (
    select agent, model, count(*) filter (where rating = 1) up, count(*) filter (where rating = -1) down
    from model_feedback where created_at >= now() - make_interval(days => p_days) group by 1, 2)
  select coalesce(s.agent, f.agent), coalesce(s.model, f.model),
         coalesce(s.ok, 0), coalesce(s.rl, 0), coalesce(s.ov, 0), coalesce(s.ij, 0), coalesce(s.tl, 0), coalesce(s.er, 0),
         case when coalesce(s.ok, 0) > 0 then round(s.ms::numeric / s.ok / 1000, 1) end,
         coalesce(f.up, 0), coalesce(f.down, 0)
  from s full join f on s.agent = f.agent and s.model = f.model
  where public.is_admin()
  order by 1, 3 desc
$$;
revoke all on function public.model_scorecard(int) from public, anon;
grant execute on function public.model_scorecard(int) to authenticated;

-- ---------------------------------------------------------------------------
-- Head-to-head comparisons: the same jobs through 2–4 candidate models for one agent.
-- ---------------------------------------------------------------------------
create table if not exists model_comparisons (
  id           bigserial primary key,
  requested_by uuid not null default auth.uid() references auth.users(id) on delete cascade,
  agent        text not null check (agent in ('scout', 'scorer', 'tailor', 'coach', 'writer')),
  models       text[] not null check (cardinality(models) between 2 and 4),
  job_count    int not null default 3 check (job_count between 1 and 5),
  status       text not null default 'queued' check (status in ('queued', 'running', 'done', 'error')),
  message      text,
  request_id   bigint,
  created_at   timestamptz not null default now(),
  finished_at  timestamptz
);
create table if not exists comparison_results (
  id            bigserial primary key,
  comparison_id bigint not null references model_comparisons(id) on delete cascade,
  job_id        text not null,
  model         text not null,
  output        text,
  metrics       jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);
create index if not exists comparison_results_idx on comparison_results(comparison_id, job_id);
create table if not exists comparison_votes (
  comparison_id bigint not null references model_comparisons(id) on delete cascade,
  job_id        text not null,
  user_id       uuid not null default auth.uid(),
  winner        text not null,
  created_at    timestamptz not null default now(),
  primary key (comparison_id, job_id, user_id)
);
alter table model_comparisons  enable row level security;
alter table comparison_results enable row level security;
alter table comparison_votes   enable row level security;
drop policy if exists "admin comparisons" on model_comparisons;
create policy "admin comparisons" on model_comparisons for select to authenticated using (public.is_admin());
drop policy if exists "admin comparison results" on comparison_results;
create policy "admin comparison results" on comparison_results for select to authenticated using (public.is_admin());
drop policy if exists "admin votes" on comparison_votes;
create policy "admin votes" on comparison_votes for all to authenticated
  using (public.is_admin()) with check (public.is_admin() and user_id = auth.uid());
revoke insert, update, delete on model_comparisons, comparison_results from anon, authenticated;

create or replace function public.request_model_comparison(p_agent text, p_models text[], p_jobs int default 3)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_token text;
  v_id    bigint;
  v_req   bigint;
begin
  if not public.is_admin() then
    raise exception 'Only @rajkumar.codes accounts can run comparisons';
  end if;
  if exists (select 1 from model_comparisons where status in ('queued', 'running') and created_at > now() - interval '30 minutes') then
    raise exception 'A comparison is already queued or running – wait for it to finish';
  end if;
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'gh_dispatch_token';
  if v_token is null then
    raise exception 'GitHub token not stored yet: run  select vault.create_secret(''<token>'', ''gh_dispatch_token'');';
  end if;
  insert into model_comparisons (agent, models, job_count) values (p_agent, p_models, p_jobs) returning id into v_id;
  select net.http_post(
    url     := 'https://api.github.com/repos/rajkumar-code29/JobFinder/actions/workflows/agents.yml/dispatches',
    body    := jsonb_build_object('ref', 'main', 'inputs',
                 jsonb_build_object('trigger', 'manual', 'all_sources', 'false', 'compare', v_id::text)),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_token, 'Accept', 'application/vnd.github+json',
                 'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'jobfinder-app', 'Content-Type', 'application/json')
  ) into v_req;
  update model_comparisons set request_id = v_req where id = v_id;
  return v_id;
end $$;
revoke all on function public.request_model_comparison(text, text[], int) from public, anon;
grant execute on function public.request_model_comparison(text, text[], int) to authenticated;

do $$ begin
  alter publication supabase_realtime add table model_comparisons, comparison_results;
exception when others then null; end $$;
