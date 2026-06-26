-- Make the admin "Live Community Deals" list sort by most-recently approved/edited.
--
-- The app already sorts that list by updated_at (newest activity first), but nothing
-- was refreshing community_deals.updated_at when a deal is approved / edited / paused
-- — so it stayed equal to created_at and the list sorted by submission date.
--
-- This adds the column (if missing) and a trigger that bumps updated_at on EVERY
-- update (approve, edit, pause, resume). Safe to run more than once.
--
-- Run in: Supabase → SQL Editor.

alter table if exists public.community_deals
  add column if not exists updated_at timestamptz default now();

create or replace function public.set_community_deals_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

drop trigger if exists trg_community_deals_updated_at on public.community_deals;
create trigger trg_community_deals_updated_at
  before update on public.community_deals
  for each row execute function public.set_community_deals_updated_at();

-- After running: approving/editing a deal moves it to the top of the admin
-- Live Community Deals list. (Existing deals keep their submission date until the
-- next time they're touched, since there's no historical approve/edit timestamp.)
