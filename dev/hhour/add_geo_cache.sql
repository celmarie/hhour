-- Shared geocode cache — makes the map fast and keeps Google costs near $0.
--
-- Problem: the map turned each venue's address into map coordinates LIVE, once
-- per visitor's device. Every new device re-did ~170 Google lookups. This table
-- caches each address→coordinates ONCE, globally: the first signed-in viewer's
-- lookups are saved here and every future visitor (including guests) reads them —
-- so Google is only ever hit once per address, ever. Coordinates aren't sensitive,
-- so the table is world-readable.
--
-- Run in: Supabase → SQL Editor.

create table if not exists public.geo_cache (
  addr       text primary key,                 -- lowercased address (the cache key)
  lat        double precision not null,
  lng        double precision not null,
  created_at timestamptz not null default now()
);

alter table public.geo_cache enable row level security;

-- Anyone (incl. guests) can READ cached coordinates.
drop policy if exists "geo_cache public read" on public.geo_cache;
create policy "geo_cache public read" on public.geo_cache for select using (true);

-- Any signed-in user can ADD / refresh a geocode result (address→coords only).
drop policy if exists "geo_cache auth insert" on public.geo_cache;
create policy "geo_cache auth insert" on public.geo_cache
  for insert to authenticated with check (true);
drop policy if exists "geo_cache auth update" on public.geo_cache;
create policy "geo_cache auth update" on public.geo_cache
  for update to authenticated using (true) with check (true);

-- ── Verify (should return 3 policies) ───────────────────────────────────────
select policyname, cmd from pg_policies
where schemaname='public' and tablename='geo_cache';
