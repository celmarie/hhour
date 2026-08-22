-- ════════════════════════════════════════════════════════════════════
-- Find & fix "orphan" merchants: accounts with role = 'merchant' that own
-- NO venue (no row in public.venues whose owner_id = the account's id).
--
-- Every merchant login is supposed to be tied to a venue; an orphan merchant
-- logs in but lands on an empty dashboard because loadMerchantData() finds no
-- venue for them.
--
-- Run in Supabase → SQL Editor. The app's anon key can't read auth.users,
-- which is why the linking can't be done from the app. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────
-- STEP A — List every merchant account and the venue(s) it owns.
--          Rows showing "— OWNS NO VENUE —" are the orphans to fix.
-- ─────────────────────────────────────────────────────────────────────
select
  u.id                                as auth_id,
  u.email,
  (u.email_confirmed_at is not null)  as confirmed,
  p.role                              as profile_role,
  coalesce(
    (select string_agg(v.name, ', ') from public.venues v where v.owner_id = u.id),
    '— OWNS NO VENUE —'
  )                                   as owns_venues
from public.profiles p
join auth.users u on u.id = p.id
where p.role = 'merchant'
order by owns_venues, u.email;

-- ─────────────────────────────────────────────────────────────────────
-- STEP B — List all venues and who currently owns them. Use this to pick
--          which venue an orphan merchant should be linked to, and to spot
--          venues whose owner_id is NULL or points at the wrong account.
-- ─────────────────────────────────────────────────────────────────────
select
  v.id            as venue_id,
  v.name          as venue_name,
  v.city,
  v.status,
  v.owner_id,
  u.email         as owner_email,
  p.role          as owner_role
from public.venues v
left join auth.users u    on u.id = v.owner_id
left join public.profiles p on p.id = v.owner_id
order by v.name;

-- ─────────────────────────────────────────────────────────────────────
-- STEP C — LINK an orphan merchant to a venue.
--          Fill in the email and ONE of the two WHERE targets below, then
--          uncomment and run. (Pick the venue from STEP B output.)
-- ─────────────────────────────────────────────────────────────────────

-- Option 1: link by venue id (most precise — copy venue_id from STEP B):
-- update public.venues
--   set owner_id = (select id from auth.users where lower(email) = 'accounting@appiehour.com')
-- where id = 'PASTE-VENUE-ID-HERE';

-- Option 2: link by venue name (use if the name is unique in STEP B):
-- update public.venues
--   set owner_id = (select id from auth.users where lower(email) = 'accounting@appiehour.com')
-- where lower(name) = lower('PASTE VENUE NAME HERE');

-- Make sure the account is actually a merchant (so it routes to the portal):
-- update public.profiles
--   set role = 'merchant'
-- where id = (select id from auth.users where lower(email) = 'accounting@appiehour.com');

-- ─────────────────────────────────────────────────────────────────────
-- STEP D — Re-run STEP A to confirm no "— OWNS NO VENUE —" rows remain
--          for the accounts you linked.
-- ─────────────────────────────────────────────────────────────────────
