-- ============================================================================
-- RULE: one review per customer per deal (anonymous still counts).
-- Run in Supabase → SQL Editor. Safe to re-run.
--
-- Anonymous reviews still store user_id (only the displayed name is hidden), so
-- a unique constraint on (user_id, deal_id, deal_kind) prevents a customer from
-- reviewing the same deal twice — anonymously or not. The app also pre-checks
-- and handles the unique-violation gracefully, but THIS is the real guard.
-- ============================================================================

-- 1) Remove existing duplicates first (keep each customer's most recent review
--    per deal) — otherwise the unique index can't be created.
delete from public.reviews a
using public.reviews b
where a.user_id is not null
  and a.user_id  = b.user_id
  and a.deal_id  = b.deal_id
  and coalesce(a.deal_kind,'') = coalesce(b.deal_kind,'')
  and a.id < b.id;            -- keep the highest id (latest) in each group

-- 2) Enforce one-per-customer-per-deal going forward.
create unique index if not exists reviews_one_per_user_deal
  on public.reviews (user_id, deal_id, deal_kind)
  where user_id is not null;  -- partial: ignores any legacy rows with no user

-- Verify: a second insert for the same (user_id, deal_id, deal_kind) now fails
-- with SQLSTATE 23505 (unique_violation), which the app shows as
-- "You've already reviewed this deal".
