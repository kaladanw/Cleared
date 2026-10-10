-- Seller's listing description sent to POST /check-listing (top-level
-- `description`, ≤5000 chars). Private: used for recheck prompts only. Never
-- selected by the public share endpoint (/api/shared) or the hub list.
-- Safe to re-run. Apply after 20261008_ios_account_parity.sql.
alter table reports add column if not exists listing_description text;
