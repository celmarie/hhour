-- ============================================================================
-- OPTIONAL hardening — stop the venues table exposing stripe_account_id.
-- Run in Supabase → SQL Editor. (Low severity: a Stripe Connect acct_… id is
-- not a secret/key, but the client never needs to READ it — it's only written
-- during onboarding — so there's no reason to expose it on every venue read.)
--
-- Safe: after trimming the admin venue query to explicit columns, no client
-- query does `venues select=*`, so nothing reads this column. Revoking column
-- SELECT only blocks a hand-crafted `venues?select=stripe_account_id` request.
-- INSERT/UPDATE privileges are unaffected (onboarding still writes it).
-- ============================================================================
revoke select (stripe_account_id) on public.venues from anon, authenticated;

-- Note: owner_id, lat/lng, status, deleted_at remain readable. owner_id is
-- needed by signed-in merchants to find their own venue; the rest are
-- non-sensitive operational fields. If you want venues fully minimized for the
-- public, the cleaner long-term move is a `venues_public` VIEW exposing only
-- name/category/city/address/emoji/website/dist_km and pointing anon reads at
-- it — ask and I'll wire that up.
