-- ============================================================================
-- Tighten venues read-exposure (run in Supabase → SQL Editor). Safe + verified.
--
-- WHY column-level (not a view): the customer deal feed reads venues through the
-- PostgREST embed deals(…,venues(name,category,dist_km)), which resolves against
-- the TABLE — so revoking anon's table access (or swapping in a view) would break
-- browsing. Column revokes keep the embed working while removing fields anon
-- never needs.
--
-- Verified against the client: anon only ever reads venues.id / name / category /
-- dist_km. owner_id is used ONLY in signed-in contexts (a merchant finding their
-- own venue, the redemption check, the admin list); stripe_account_id is only
-- WRITTEN during onboarding, never read by the client.
-- ============================================================================

-- stripe_account_id: not a secret, but never read by the client → remove from
-- the read surface for everyone (writes/onboarding are unaffected).
revoke select (stripe_account_id) on public.venues from anon, authenticated;

-- owner_id: a user UUID linking venue → owner. Anon never needs it; signed-in
-- merchants/admins do, so keep it for `authenticated` and revoke only for anon.
revoke select (owner_id) on public.venues from anon;

-- Left readable by anon (display/filter fields used by the deal feed, and venue
-- location which is inherently public): id, name, category, dist_km, address,
-- city, lat, lng, emoji, image_url, website, verified, active, status, created_at.
-- Revoking lat/lng/address would risk breaking the map for little gain, so they
-- stay. RLS still limits anon to active venues only.

-- Verify (as anon these should now error with "permission denied for column"):
--   select stripe_account_id from venues limit 1;
--   select owner_id          from venues limit 1;
