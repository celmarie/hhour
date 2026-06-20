-- ============================================================================
-- Stop anon reading submitter_ip / submitter_location (PII) from the public
-- community tables. Run in Supabase → SQL Editor.
--
-- match_screenings and community_events both store the submitter's IP + coarse
-- location for abuse review. The public feeds read these tables, so anon could
-- read those PII columns. Revoke them from `anon` only — `authenticated` keeps
-- full access so ADMINS still see IP/location for moderation (they read via the
-- authenticated role). service_role is unaffected.
--
-- Pattern: a bare column REVOKE can't override Supabase's table-level grant, so
-- we revoke the whole-table SELECT for anon and re-grant every column EXCEPT the
-- two PII fields. (The app's public feeds were updated to select explicit
-- columns, so they keep working; a bare anon select=* now errors, which is fine.)
--
-- MAINTENANCE: explicit allow-list — if you add a column to either table, add it
-- here too or anon won't be able to read it.
-- ============================================================================

-- ── match_screenings ────────────────────────────────────────────────────────
revoke select on public.match_screenings from anon;
grant select (
  id, user_id, host_name, venue_name, location, match_label, match_date,
  kickoff_time, reservation_needed, reservation_info, notes, emoji, image_url,
  going, status, created_at, timezone, matches, crowd_busy, crowd_ok,
  crowd_chill, lat, lng, slug
) on public.match_screenings to anon;

-- ── community_events ────────────────────────────────────────────────────────
revoke select on public.community_events from anon;
grant select (
  id, user_id, host_name, title, description, event_date, event_time, location,
  capacity, going, price, ticket_type, category, emoji, image_url, status,
  created_at, currency
) on public.community_events to anon;

-- Verify (as anon: first two error "permission denied for column"; third works):
--   select submitter_ip from match_screenings limit 1;     -- ❌
--   select submitter_ip from community_events limit 1;      -- ❌
--   select id,host_name,going from match_screenings limit 1; -- ✅
