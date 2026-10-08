-- Hub share links + seller view. Safe to re-run.
-- Apply in Supabase SQL Editor after 20261006_add_marketplace.sql and 20261006_hub_triage.sql.

-- Share: one unguessable read-only token per report (NULL = not shared / revoked).
alter table reports add column if not exists share_token text;
alter table reports add column if not exists shared_at timestamptz;

create unique index if not exists reports_share_token_key
  on reports (share_token)
  where share_token is not null;

-- Seller identity captured by the extension (NULL on older rows).
alter table reports add column if not exists seller_username text;
alter table reports add column if not exists seller_url text;

create index if not exists reports_user_marketplace_seller
  on reports (user_id, marketplace, seller_username);

-- NOTE: no anon/public RLS policy is added. The public share endpoint reads via
-- the backend's service-role client and returns a sanitized projection only.
