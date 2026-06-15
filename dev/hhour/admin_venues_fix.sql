-- ════════════════════════════════════════════════════════════════════
-- HappyHourly — Admin venues fix
-- Run once in the Supabase SQL Editor. Safe to run twice (idempotent).
--
-- Fixes:
--   1) Adds missing columns (status, deleted_at) the app code expects
--   2) Adds admin RLS policy so admins can read ALL venues (not just active)
--   3) Adds admin RLS policy so admins can update/delete any venue
-- ════════════════════════════════════════════════════════════════════

-- ── 1) Missing columns ────────────────────────────────────────────────
alter table public.venues add column if not exists status     text default 'pending';
alter table public.venues add column if not exists deleted_at timestamptz;
alter table public.venues add column if not exists postcode   text default '';
alter table public.venues add column if not exists website    text default '';
alter table public.venues add column if not exists stripe_account_id text;

-- Back-fill status from active flag for existing rows
update public.venues set status = case
  when active = true  then 'active'
  when active = false then 'suspended'
  else 'pending'
end
where status = 'pending' or status is null;

-- ── 2) Admin RLS — read ALL venues ───────────────────────────────────
drop policy if exists "Admin reads all venues" on public.venues;
create policy "Admin reads all venues" on public.venues
  for select to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid()
        and p.role in ('admin', 'super_admin')
    )
  );

-- ── 3) Admin RLS — update / delete any venue ─────────────────────────
drop policy if exists "Admin manages all venues" on public.venues;
create policy "Admin manages all venues" on public.venues
  for all to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid()
        and p.role in ('admin', 'super_admin')
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid()
        and p.role in ('admin', 'super_admin')
    )
  );
