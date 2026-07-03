-- Community deals: start/end date columns.
-- The submit form and the admin editor already have these date fields, but the
-- table had nowhere to store them — every date entered was silently dropped,
-- so no community deal could ever "expire". Nullable: no end date = runs forever.
-- Safe to run more than once.

alter table public.community_deals add column if not exists start_date date;
alter table public.community_deals add column if not exists end_date   date;
