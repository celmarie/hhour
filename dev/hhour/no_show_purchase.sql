-- No-show reporting for voucher PURCHASES
-- ---------------------------------------------------------------------------
-- Lets a merchant flag a customer who BOUGHT/RESERVED a voucher but never showed
-- up to redeem it — works for any purchase, not just booking-required deals.
-- Builds on no_show.sql (profiles.no_show_count, public.no_shows table). The
-- voucher itself is left untouched (status stays 'active'); the flag lives in
-- no_shows, so redemption / the customer's voucher list are unaffected and the
-- merchant can still redeem it later (after Undo) if the guest turns up.
--
-- Safe to run multiple times.

-- 1. Let merchants READ the no-shows tied to their own venues' deals, so the
--    portal can show which purchases are already flagged. (Customers see their
--    own; admins see all — from no_show.sql.)
drop policy if exists no_shows_select_merchant on public.no_shows;
create policy no_shows_select_merchant on public.no_shows
  for select using (
    exists (
      select 1 from public.deals d
      join public.venues v on v.id = d.venue_id
      where d.id = no_shows.deal_id and v.owner_id = auth.uid()
    )
  );

-- 2. One no-show per purchase (idempotency for purchase-based rows; booking rows
--    are guarded separately by no_shows_booking_uq).
create unique index if not exists no_shows_purchase_uq
  on public.no_shows(purchase_id) where purchase_id is not null and booking_id is null;

-- 3. Report a no-show for a PURCHASE. SECURITY DEFINER so a merchant may bump
--    another user's counter — but only after we verify they own the venue/deal.
--    Refuses if the voucher was already redeemed. Idempotent. Returns new count.
create or replace function public.report_no_show_purchase(p_purchase_id bigint)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller     uuid := auth.uid();
  v_role       text := coalesce((auth.jwt() -> 'app_metadata' ->> 'role'), '');
  v_user_id    uuid;
  v_deal_id    bigint;
  v_venue_id   uuid;
  v_owner_id   uuid;
  v_venue_name text;
  v_deal_title text;
  v_status     text;
  v_already    boolean;
  v_new        int;
begin
  if v_caller is null then raise exception 'Not authenticated'; end if;

  select vp.user_id, vp.deal_id, vp.status, d.title, d.venue_id, v.owner_id, v.name
    into v_user_id, v_deal_id, v_status, v_deal_title, v_venue_id, v_owner_id, v_venue_name
  from public.voucher_purchases vp
  left join public.deals  d on d.id = vp.deal_id
  left join public.venues v on v.id = d.venue_id
  where vp.id = p_purchase_id;

  if v_user_id is null then raise exception 'Purchase not found'; end if;

  if v_role not in ('admin','super_admin')
     and (v_owner_id is null or v_owner_id <> v_caller) then
    raise exception 'Not authorized to report this purchase';
  end if;

  if v_status = 'used' then
    raise exception 'Voucher already redeemed — cannot mark as no-show';
  end if;

  select exists(select 1 from public.no_shows where purchase_id = p_purchase_id)
    into v_already;

  if not v_already then
    insert into public.no_shows(
      user_id, purchase_id, deal_id, venue_id, venue_name, deal_title, reported_by)
    values (
      v_user_id, p_purchase_id, v_deal_id, v_venue_id, v_venue_name, v_deal_title, v_caller);

    update public.profiles
       set no_show_count = coalesce(no_show_count,0) + 1
     where id = v_user_id;
  end if;

  select coalesce(no_show_count,0) into v_new from public.profiles where id = v_user_id;
  return v_new;
end;
$$;

grant execute on function public.report_no_show_purchase(bigint) to authenticated;

-- 4. Undo a purchase no-show (same ownership check). Returns the new counter.
create or replace function public.undo_no_show_purchase(p_purchase_id bigint)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller   uuid := auth.uid();
  v_role     text := coalesce((auth.jwt() -> 'app_metadata' ->> 'role'), '');
  v_user_id  uuid;
  v_owner_id uuid;
  v_new      int;
begin
  if v_caller is null then raise exception 'Not authenticated'; end if;

  -- Resolve owner + customer from the PURCHASE and authorize FIRST — before returning
  -- any data. (Previously the no-row branch returned the customer's counter with no
  -- ownership check, leaking it to any authenticated caller.)
  select v.owner_id, vp.user_id
    into v_owner_id, v_user_id
    from public.voucher_purchases vp
    left join public.deals  d on d.id = vp.deal_id
    left join public.venues v on v.id = d.venue_id
   where vp.id = p_purchase_id;

  if v_user_id is null then raise exception 'Purchase not found'; end if;
  if v_role not in ('admin','super_admin')
     and (v_owner_id is null or v_owner_id <> v_caller) then
    raise exception 'Not authorized';
  end if;

  -- Reverse only a PURCHASE-originated no-show (booking_id null). A no-show created
  -- from the bookings screen is undone there (undo_no_show), keyed on booking_id.
  if exists(select 1 from public.no_shows where purchase_id = p_purchase_id and booking_id is null) then
    delete from public.no_shows where purchase_id = p_purchase_id and booking_id is null;
    update public.profiles
       set no_show_count = greatest(0, coalesce(no_show_count,0) - 1)
     where id = v_user_id;
  end if;

  select coalesce(no_show_count,0) into v_new from public.profiles where id = v_user_id;
  return v_new;
end;
$$;

grant execute on function public.undo_no_show_purchase(bigint) to authenticated;
