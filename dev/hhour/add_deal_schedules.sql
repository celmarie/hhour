-- Multiple day+time schedules per deal / voucher.
--
-- A deal can now run several weekly windows in one validity date range, e.g.
-- Mon–Thu 4–6pm AND Fri–Sun 2–5pm. They're stored as a JSON array of
-- {days, from, to} objects (from/to are 24-hour float hours, e.g. 16.5 = 4:30pm)
-- in a new `schedules` column on both deal tables.
--
-- Backward-compatible: the existing days / hours / time_from / time_to columns
-- keep mirroring the FIRST block, so old app versions and every existing
-- display + "available in" countdown keep working. The app also runs fine BEFORE
-- this is applied — it just falls back to the single day+time window until then.
--
-- Run in: Supabase → SQL Editor.

alter table public.deals           add column if not exists schedules jsonb;
alter table public.community_deals  add column if not exists schedules jsonb;

-- ── Verify (should list both tables) ────────────────────────────────────────
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and column_name = 'schedules'
  and table_name in ('deals', 'community_deals')
order by table_name;
