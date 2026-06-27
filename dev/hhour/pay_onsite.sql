-- Pay-at-venue (onsite) vouchers
-- ---------------------------------------------------------------------------
-- Lets customers reserve a voucher without paying online and settle with the
-- venue in person. Certified (verified) merchants can declare which payment
-- methods they accept onsite.
--
-- Safe to run multiple times (IF NOT EXISTS guards).

-- 1. How a voucher was paid for.
--    'online' = prepaid by card via Stripe (existing behaviour, default)
--    'onsite' = reserved in-app, customer pays the venue on arrival
alter table public.voucher_purchases
  add column if not exists payment_method text not null default 'online';

-- When the onsite payment was actually collected (set at redemption).
-- Stays null for unpaid onsite reservations; online vouchers may leave it null
-- since the Stripe payment intent already proves payment.
alter table public.voucher_purchases
  add column if not exists paid_at timestamptz;

-- Constrain to known values (drop first so re-runs don't error).
alter table public.voucher_purchases
  drop constraint if exists voucher_purchases_payment_method_chk;
alter table public.voucher_purchases
  add constraint voucher_purchases_payment_method_chk
  check (payment_method in ('online', 'onsite'));

-- 2. Venue-level: which payment methods the venue accepts onsite.
--    null  = not set (don't show anything to the customer)
--    'cash' | 'card' | 'either'
alter table public.venues
  add column if not exists accepted_payment text;

alter table public.venues
  drop constraint if exists venues_accepted_payment_chk;
alter table public.venues
  add constraint venues_accepted_payment_chk
  check (accepted_payment is null or accepted_payment in ('cash', 'card', 'either'));
