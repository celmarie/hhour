-- Acknowledge "Still-active" confirmations (👍 from the deal-detail button)
-- ---------------------------------------------------------------------------
-- Customers tapping "👍 Still active" create a deal_reports row with status='info'.
-- Admins review these in the "Still-Active Confirmations" queue and tap "✓ OK" to
-- acknowledge them. Acknowledging does NOT delete the row (the confirmation stays
-- on the deal's record as "last confirmed active …") — it just sets acknowledged_at
-- so the item drops out of the admin queue until a NEW confirmation arrives.
--
-- Safe to run multiple times.

alter table public.deal_reports add column if not exists acknowledged_at timestamptz;
alter table public.deal_reports add column if not exists acknowledged_by uuid;

create index if not exists deal_reports_info_ack_idx
  on public.deal_reports (deal_id) where status = 'info' and acknowledged_at is null;

-- Admins acknowledge (UPDATE) info rows. There was previously no UPDATE policy on
-- deal_reports (reports were only ever inserted, selected, or admin-deleted).
drop policy if exists "deal_reports admin update" on public.deal_reports;
create policy "deal_reports admin update" on public.deal_reports
  for update to authenticated
  using      (public.is_admin())
  with check (public.is_admin());

-- Defensive: guarantee admins can read every report (incl. the new columns). This is
-- additive — if a broader SELECT policy already exists, RLS OResses them, so nothing
-- that reads today stops working.
drop policy if exists "deal_reports admin select" on public.deal_reports;
create policy "deal_reports admin select" on public.deal_reports
  for select to authenticated
  using (public.is_admin());
