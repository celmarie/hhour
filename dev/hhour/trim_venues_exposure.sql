-- ============================================================================
-- Tighten venues read-exposure (run in Supabase → SQL Editor).
--
-- NOTE: a column-level `REVOKE SELECT (col)` does NOT work on its own, because
-- Supabase grants TABLE-level SELECT to anon/authenticated and a column revoke
-- can't override a whole-table grant. The correct pattern is: revoke the table
-- grant, then GRANT SELECT only on the allowed columns.
--
-- Goal:
--   anon          → everything EXCEPT owner_id and stripe_account_id
--   authenticated → everything EXCEPT stripe_account_id (keeps owner_id; signed-in
--                   merchants/admins need it). service_role keeps full access.
--
-- Embed-safe: the deal feed embed deals(…,venues(name,category,dist_km)) only
-- needs id/name/category/dist_km, all granted below.
--
-- MAINTENANCE: this is an explicit allow-list. If you ADD a column to venues
-- later, add it here too (and re-run) or anon/authenticated won't be able to
-- read it.
-- ============================================================================

-- anon: all display/location columns, but NOT owner_id / stripe_account_id
revoke select on public.venues from anon;
grant select (
  id, name, category, address, city, lat, lng, emoji, image_url, dist_km,
  verified, active, status, deleted_at, postcode, website, created_at
) on public.venues to anon;

-- authenticated: same set PLUS owner_id (needed to find own venue / redeem /
-- admin), but still NOT stripe_account_id.
revoke select on public.venues from authenticated;
grant select (
  id, owner_id, name, category, address, city, lat, lng, emoji, image_url,
  dist_km, verified, active, status, deleted_at, postcode, website, created_at
) on public.venues to authenticated;

-- Verify (as anon, the first two should now error "permission denied for column";
-- the third should still return rows):
--   select owner_id          from venues limit 1;   -- ❌ denied
--   select stripe_account_id from venues limit 1;   -- ❌ denied
--   select id,name,category,dist_km from venues limit 1;  -- ✅ ok
