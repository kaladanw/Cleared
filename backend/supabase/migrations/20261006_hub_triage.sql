-- Hub triage: status, notes, tags, and image_urls for recheck-from-hub.
-- Safe to re-run. Apply in Supabase SQL Editor after marketplace migration.

alter table reports
  add column if not exists hub_status text;

alter table reports
  add column if not exists notes text not null default '';

alter table reports
  add column if not exists tags text[] not null default '{}';

alter table reports
  add column if not exists image_urls jsonb not null default '[]'::jsonb;

-- Optional sanity check: allow only known statuses (null = unset).
alter table reports drop constraint if exists reports_hub_status_check;
alter table reports
  add constraint reports_hub_status_check
  check (
    hub_status is null
    or hub_status in ('watching', 'bought', 'skipped', 'sold_out')
  );

create index if not exists reports_user_status_checked
  on reports (user_id, hub_status, checked_at desc);

create index if not exists reports_user_verdict_checked
  on reports (user_id, verdict, checked_at desc);
