-- Hotel date-booking: store the customer's check-in / check-out on the purchase.
-- Hotel deals are priced per night; the app records nights as `qty`, so
-- total paid = qty (nights) × the deal's per-night price. These two columns add
-- the actual stay dates. Safe to run more than once.
--
-- Run in: Supabase → SQL Editor.

alter table if exists public.voucher_purchases
  add column if not exists check_in  date,
  add column if not exists check_out date;

-- (Optional) quick sanity check:
-- select id, deal_id, qty, check_in, check_out
-- from public.voucher_purchases
-- where check_in is not null
-- order by created_at desc
-- limit 20;
