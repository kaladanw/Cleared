-- Cleared — Supabase schema
-- Paste this into the Supabase SQL Editor (project → SQL Editor → New query).
-- Run it once after creating the project. Re-running is safe (IF NOT EXISTS guards).
-- Existing projects: also run files under migrations/.

-- reports: one row per listing check, owned by a user.
-- auth.users is managed by Supabase Auth; do not create it manually.
create table if not exists reports (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete cascade not null,
  listing_url text not null,
  listing_name text,
  marketplace text not null default 'depop',
  verdict     text,
  report_json jsonb not null,
  hub_status  text,
  notes       text not null default '',
  tags        text[] not null default '{}',
  image_urls  jsonb not null default '[]'::jsonb,
  share_token text,
  shared_at   timestamptz,
  seller_username text,
  seller_url  text,
  checked_at  timestamptz default now(),
  constraint reports_hub_status_check check (
    hub_status is null
    or hub_status in ('watching', 'bought', 'skipped', 'sold_out')
  )
);

-- Index for the common query: all reports for a user, newest first.
create index if not exists reports_user_checked
  on reports (user_id, checked_at desc);

-- Index for the cached-revisit lookup: reports for a user + URL.
create index if not exists reports_user_url
  on reports (user_id, listing_url);

-- Index for marketplace-filtered history (hub: All / Depop / Vinted later).
create index if not exists reports_user_marketplace_checked
  on reports (user_id, marketplace, checked_at desc);

create index if not exists reports_user_status_checked
  on reports (user_id, hub_status, checked_at desc);

create index if not exists reports_user_verdict_checked
  on reports (user_id, verdict, checked_at desc);

-- Share links: unguessable token, unique when set (NULL = not shared / revoked).
create unique index if not exists reports_share_token_key
  on reports (share_token)
  where share_token is not null;

-- Seller view: all checks against one seller on one marketplace.
create index if not exists reports_user_marketplace_seller
  on reports (user_id, marketplace, seller_username);

-- Row-level security: each user sees only their own reports.
-- Public share reads go through the backend's service-role client (sanitized),
-- so no anon policy is needed or wanted here.
alter table reports enable row level security;

-- Drop and recreate so this script is idempotent.
drop policy if exists "users see own reports" on reports;
create policy "users see own reports" on reports
  for all using (auth.uid() = user_id);
