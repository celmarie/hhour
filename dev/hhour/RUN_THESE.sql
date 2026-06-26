-- ============================================================================
-- Appie Hour — pending DB migrations. Run this whole file once in:
--   Supabase dashboard → SQL Editor → New query → paste → Run.
-- Everything here is idempotent (safe to run more than once).
-- ============================================================================

-- 1) CRITICAL — let admins & super_admins READ every venue.
--    Without this, approved merchants are created but never appear in the admin
--    Merchants list (they vanish on refresh), because the list reads the venues
--    table directly and RLS blocks admin reads.
drop policy if exists "Admins can read all venues" on public.venues;
create policy "Admins can read all venues"
  on public.venues for select
  using (
    exists (select 1 from public.profiles p
            where p.id = auth.uid() and p.role in ('admin','super_admin'))
  );

-- (Belt & suspenders) let admins INSERT/UPDATE venues too, so approving a
-- merchant can create/activate the venue regardless of other policies.
drop policy if exists "Admins can write venues" on public.venues;
create policy "Admins can write venues"
  on public.venues for all
  using (
    exists (select 1 from public.profiles p
            where p.id = auth.uid() and p.role in ('admin','super_admin'))
  )
  with check (
    exists (select 1 from public.profiles p
            where p.id = auth.uid() and p.role in ('admin','super_admin'))
  );

-- 2) Store the venue's type (Bar/Restaurant/Hotel/… from Content categories).
alter table if exists public.venues
  add column if not exists venue_type text;

-- 3) Track last approve/edit time so the admin "Live Community Deals" list can
--    sort by most-recent activity across reloads.
alter table if exists public.community_deals
  add column if not exists updated_at timestamptz default now();

create or replace function public.set_community_deals_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_community_deals_updated_at on public.community_deals;
create trigger trg_community_deals_updated_at
  before update on public.community_deals
  for each row execute function public.set_community_deals_updated_at();

-- 4) Hotel date booking (check-in / check-out on the purchase).
--    (You already ran this — harmless to run again.)
alter table if exists public.voucher_purchases
  add column if not exists check_in  date,
  add column if not exists check_out date;
