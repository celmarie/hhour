-- ============================================================================
-- Lookup indexes + PostGIS geo columns
--
-- Records SQL that was already applied LIVE via the Supabase SQL Editor so it
-- lives in the repo. Everything uses IF NOT EXISTS, so re-running is a no-op and
-- it's safe to apply to a fresh database. (Do not need to re-run against prod —
-- this just captures the existing state.)
-- ============================================================================

-- ── community_deals ─────────────────────────────────────────────────────────
-- deleted_at backs the partial index below (added with the admin permanent-delete
-- feature); guard it so this migration is self-contained on a fresh DB.
alter table public.community_deals
  add column if not exists deleted_at timestamptz;

-- Public feed read: active, non-deleted, newest first.
create index if not exists idx_community_deals_status_created
  on public.community_deals (status, created_at desc)
  where deleted_at is null;

create index if not exists idx_community_deals_slug
  on public.community_deals (slug);

create index if not exists idx_community_deals_user_id
  on public.community_deals (user_id);

create index if not exists idx_community_deals_category
  on public.community_deals (category);

-- ── deals (merchant/verified) ───────────────────────────────────────────────
create index if not exists idx_deals_venue_id
  on public.deals (venue_id);

-- ── community_events ────────────────────────────────────────────────────────
create index if not exists idx_community_events_status_created
  on public.community_events (status, created_at desc);

create index if not exists idx_community_events_user_id
  on public.community_events (user_id);

-- ── credits_ledger ──────────────────────────────────────────────────────────
create index if not exists idx_credits_ledger_user_created
  on public.credits_ledger (user_id, created_at desc);

-- ── deal_arrival_times ──────────────────────────────────────────────────────
create index if not exists idx_deal_arrival_times_deal_id
  on public.deal_arrival_times (deal_id);

-- ── deal_mistake_reports ────────────────────────────────────────────────────
create index if not exists idx_deal_mistake_reports_deal_id
  on public.deal_mistake_reports (deal_id);

create index if not exists idx_deal_mistake_reports_status
  on public.deal_mistake_reports (status);

-- ── deal_reports ────────────────────────────────────────────────────────────
create index if not exists idx_deal_reports_deal_id
  on public.deal_reports (deal_id);

create index if not exists idx_deal_reports_status
  on public.deal_reports (status);

-- ============================================================================
-- PostGIS: geography columns for fast radius / nearest-venue queries.
-- ============================================================================
create extension if not exists postgis;

-- venues.geo — derived from lat/lng (ST_MakePoint takes lng, lat order).
-- STORED generated column so the GIST index can use it; immutable expression.
alter table public.venues
  add column if not exists geo geography(Point, 4326)
  generated always as (
    case
      when lat is not null and lng is not null
        then st_setsrid(st_makepoint(lng, lat), 4326)::geography
      else null
    end
  ) stored;

create index if not exists idx_venues_geo
  on public.venues using gist (geo);

-- match_screenings.geo — same derivation.
alter table public.match_screenings
  add column if not exists geo geography(Point, 4326)
  generated always as (
    case
      when lat is not null and lng is not null
        then st_setsrid(st_makepoint(lng, lat), 4326)::geography
      else null
    end
  ) stored;

create index if not exists idx_match_screenings_geo
  on public.match_screenings using gist (geo);
