-- Postings that were already rated, so they aren't rated again.

create table if not exists seen_postings (
  user_id      uuid not null references auth.users(id) on delete cascade,
  source       text not null,
  external_id  text not null,
  fingerprint  text not null,          -- normalised company|title, catches the same job on another site
  context      text not null,          -- hash of resume + roles + locations: a change means "rate again"
  relevance    int  not null,
  reason       text not null default 'NA',
  seen_at      timestamptz not null default now(),
  primary key (user_id, source, external_id)
);
create index if not exists seen_postings_fp_idx   on seen_postings(user_id, fingerprint);
create index if not exists seen_postings_seen_idx on seen_postings(seen_at);

-- pipeline only
alter table seen_postings enable row level security;
revoke all on seen_postings from anon, authenticated;
