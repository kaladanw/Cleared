-- Marketplace hub: tag each report with the source marketplace (depop now, vinted later).
-- Safe to re-run. Apply in Supabase SQL Editor on production after deploy.

alter table reports
  add column if not exists marketplace text not null default 'depop';

create index if not exists reports_user_marketplace_checked
  on reports (user_id, marketplace, checked_at desc);
