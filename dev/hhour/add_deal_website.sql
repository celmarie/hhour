-- Deal "Website / Social (optional)" field
-- ---------------------------------------------------------------------------
-- The deal Review & Edit screen has a "Website / Social (optional)" input, but
-- there was no column to store it (and the save path never collected it), so the
-- value silently vanished on save. Add the column to both deal tables.
--
-- Safe to run multiple times.

alter table public.deals           add column if not exists website text;
alter table public.community_deals add column if not exists website text;
