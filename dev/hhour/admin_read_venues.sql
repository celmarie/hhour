-- Let admins & super_admins read EVERY venue, so the admin "Merchants" list shows
-- approved/created venues. The list queries the venues table directly, which is
-- subject to row-level security — if there's no admin read policy, admins see 0
-- merchants even though the venues exist.
--
-- Additive: this policy is OR'd with any existing policies, so it only GRANTS
-- admin read access; it doesn't remove anything. Safe to run more than once.
--
-- Run in: Supabase → SQL Editor.

drop policy if exists "Admins can read all venues" on public.venues;
create policy "Admins can read all venues"
  on public.venues for select
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role in ('admin','super_admin')
    )
  );

-- Optional sanity check (run while signed in as an admin via the app, not here):
-- select count(*) from public.venues;
