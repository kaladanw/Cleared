-- Cleared — Supabase schema
-- Paste this into the Supabase SQL Editor (project → SQL Editor → New query).
-- Run it once after creating the project. Re-running is safe (IF NOT EXISTS guards).

-- reports: one row per listing check, owned by a user.
-- auth.users is managed by Supabase Auth; do not create it manually.
create table if not exists reports (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete cascade not null,
  listing_url text not null,
  listing_name text,
  verdict     text,
  report_json jsonb not null,
  checked_at  timestamptz default now()
);

-- Index for the common query: all reports for a user, newest first.
create index if not exists reports_user_checked
  on reports (user_id, checked_at desc);

-- Index for the cached-revisit lookup: reports for a user + URL.
create index if not exists reports_user_url
  on reports (user_id, listing_url);

-- Row-level security: each user sees only their own reports.
alter table reports enable row level security;

-- Drop and recreate so this script is idempotent.
drop policy if exists "users see own reports" on reports;
create policy "users see own reports" on reports
  for all using (auth.uid() = user_id);
