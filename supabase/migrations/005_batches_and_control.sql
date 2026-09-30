-- JobFinder: batches, admin kill switch, job deletion.
-- Run once in the Supabase SQL editor after 004_admin_tools.sql.

-- ---------------------------------------------------------------------------
-- Kill switch (admin only). While paused, runs stop at the next step and scheduled runs skip.
-- ---------------------------------------------------------------------------
create table if not exists agent_control (
  id         int primary key default 1 check (id = 1),
  paused     boolean not null default false,
  reason     text,
  changed_by text,
  changed_at timestamptz not null default now()
);
insert into agent_control (id) values (1) on conflict do nothing;
alter table agent_control enable row level security;
drop policy if exists "signed in can see agent control" on agent_control;
create policy "signed in can see agent control" on agent_control for select to authenticated using (true);
revoke insert, update, delete on agent_control from anon, authenticated;

create or replace function public.set_agents_paused(p_paused boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Only @rajkumar.codes accounts can pause or resume the agents';
  end if;
  update agent_control
     set paused = p_paused, reason = p_reason, changed_by = auth.jwt() ->> 'email', changed_at = now()
   where id = 1;
end $$;
revoke all on function public.set_agents_paused(boolean, text) from public, anon;
grant execute on function public.set_agents_paused(boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Batches: the Scout collects up to `batch_size` relevant jobs into Batch #N; they are salary-checked,
-- scored and ranked together, then tailored / coached / written one by one in score order.
-- ---------------------------------------------------------------------------
create table if not exists batches (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  number      int  not null,
  status      text not null default 'processing' check (status in ('processing', 'done')),
  stage       text not null default 'salary' check (stage in ('salary', 'scoring', 'tailoring', 'done')),
  job_count   int  not null default 0,
  created_at  timestamptz not null default now(),
  finished_at timestamptz,
  unique (user_id, number)
);
create index if not exists batches_user_idx on batches(user_id, number desc);
alter table batches enable row level security;
drop policy if exists "own batches read" on batches;
create policy "own batches read" on batches for select to authenticated using (user_id = auth.uid());

alter table jobs add column if not exists batch_id   uuid references batches(id) on delete set null;
alter table jobs add column if not exists batch_rank int;   -- 1 = highest ATS score in the batch
create index if not exists jobs_batch_idx on jobs(batch_id, batch_rank);

alter table settings add column if not exists batch_size int not null default 20;

do $$ begin
  alter publication supabase_realtime add table batches, agent_control;
exception when others then null; end $$;

-- ---------------------------------------------------------------------------
-- Delete a job: the row goes, a tiny "deleted" marker stays so the Scout never brings it back.
-- (The app deletes the job's files from storage first, through the storage API.)
-- ---------------------------------------------------------------------------
drop policy if exists "own job files delete" on storage.objects;
create policy "own job files delete" on storage.objects for delete to authenticated
  using (bucket_id = 'jobs' and (storage.foldername(name))[1] = auth.uid()::text);

create or replace function public.delete_job(p_job_id text) returns void
language plpgsql security definer set search_path = public as $$
declare
  j jobs;
  norm_company text;
  norm_title   text;
begin
  select * into j from jobs where job_id = p_job_id and user_id = auth.uid();
  if not found then
    raise exception 'Job % not found', p_job_id;
  end if;
  -- same normalisation as db.fingerprint() in the pipeline
  norm_company := trim(regexp_replace(lower(j.company), '[^[:alnum:]]+', ' ', 'g'));
  norm_title   := trim(regexp_replace(lower(j.title),   '[^[:alnum:]]+', ' ', 'g'));
  insert into seen_postings (user_id, source, external_id, fingerprint, context, relevance, reason)
  values (j.user_id, j.source, j.external_id, norm_company || '|' || norm_title, '*', -1, 'deleted by user')
  on conflict (user_id, source, external_id)
  do update set context = '*', relevance = -1, reason = 'deleted by user', seen_at = now();
  delete from jobs where id = j.id;
  if j.batch_id is not null then
    update batches set job_count = greatest(job_count - 1, 0) where id = j.batch_id;
  end if;
end $$;
revoke all on function public.delete_job(text) from public, anon;
grant execute on function public.delete_job(text) to authenticated;
