-- Reservation-style booking setup: arrival slots defined PER DATE, each with
-- its own voucher allocation. If a date has specific slots, those are used;
-- otherwise the deal's weekly arrival times (deal_arrival_times) apply.
-- Safe to run more than once.

-- 1) Per-date slots ----------------------------------------------------------
create table if not exists public.deal_date_slots (
  id          bigserial primary key,
  deal_id     bigint not null references public.deals(id) on delete cascade,
  on_date     date   not null,
  time_label  text   not null check (time_label ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  capacity    int    not null check (capacity > 0),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (deal_id, on_date, time_label)
);

alter table public.deal_date_slots enable row level security;

drop policy if exists "date_slots public read" on public.deal_date_slots;
create policy "date_slots public read"
  on public.deal_date_slots for select using (true);

drop policy if exists "date_slots owner write" on public.deal_date_slots;
create policy "date_slots owner write"
  on public.deal_date_slots for all
  using (exists (
    select 1 from public.deals d join public.venues v on v.id = d.venue_id
    where d.id = deal_date_slots.deal_id and v.owner_id = auth.uid()))
  with check (exists (
    select 1 from public.deals d join public.venues v on v.id = d.venue_id
    where d.id = deal_date_slots.deal_id and v.owner_id = auth.uid()));

-- 2) Availability: date-specific slots win, weekly times are the fallback ----
create or replace function public.get_arrival_availability(p_deal_id bigint, p_date date)
returns table (time_label text, capacity int, booked bigint)
language sql security definer set search_path = public as $$
  with slots as (
    select s.time_label, s.capacity
    from deal_date_slots s
    where s.deal_id = p_deal_id and s.on_date = p_date and s.active
    union all
    select t.time_label, t.capacity
    from deal_arrival_times t
    where t.deal_id = p_deal_id and t.active
      and not exists (select 1 from deal_date_slots s2
                      where s2.deal_id = p_deal_id and s2.on_date = p_date and s2.active)
  )
  select sl.time_label, sl.capacity,
         coalesce((select sum(b.guests) from voucher_bookings b
                   where b.deal_id = p_deal_id
                     and b.booking_date = p_date
                     and b.arrival_time = sl.time_label
                     and b.status = 'confirmed'), 0) as booked
  from slots sl
  order by sl.time_label;
$$;
grant execute on function public.get_arrival_availability(bigint, date) to anon, authenticated;

-- 3) Shared capacity lookup used by booking + reschedule ---------------------
create or replace function public._slot_capacity(p_deal_id bigint, p_date date, p_time text)
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_cap int;
  v_has_date boolean;
begin
  select exists(select 1 from deal_date_slots
                where deal_id = p_deal_id and on_date = p_date and active) into v_has_date;
  if v_has_date then
    select capacity into v_cap from deal_date_slots
     where deal_id = p_deal_id and on_date = p_date and time_label = p_time and active
     for update;
  else
    select capacity into v_cap from deal_arrival_times
     where deal_id = p_deal_id and time_label = p_time and active
     for update;
  end if;
  return v_cap;  -- null = invalid time for that date
end; $$;

-- 4) Book: respect per-date slots --------------------------------------------
create or replace function public.book_arrival(
  p_purchase_id bigint,
  p_deal_id     bigint,
  p_date        date,
  p_time        text,
  p_guests      int
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_deal   record;
  v_cap    int;
  v_booked bigint;
  v_bk_id  bigint;
begin
  if v_uid is null then raise exception 'NOT_ALLOWED'; end if;
  if p_guests is null or p_guests < 1 then raise exception 'INVALID_GUESTS'; end if;

  perform 1 from voucher_purchases
   where id = p_purchase_id and user_id = v_uid
     and deal_id = p_deal_id and status = 'active';
  if not found then raise exception 'NOT_ALLOWED'; end if;

  select * into v_deal from deals where id = p_deal_id;
  if not found then raise exception 'INVALID_DEAL'; end if;

  if p_date < current_date then raise exception 'INVALID_DATE'; end if;
  if v_deal.start_date is not null and p_date < v_deal.start_date then raise exception 'INVALID_DATE'; end if;
  if v_deal.end_date   is not null and p_date > v_deal.end_date   then raise exception 'INVALID_DATE'; end if;
  if v_deal.days is not null and v_deal.days !~* 'daily'
     and position(lower(to_char(p_date,'Dy')) in lower(v_deal.days)) = 0
     and not exists (select 1 from deal_date_slots
                     where deal_id = p_deal_id and on_date = p_date and active) then
    raise exception 'INVALID_DATE';
  end if;

  perform 1 from voucher_bookings where purchase_id = p_purchase_id and status = 'confirmed';
  if found then raise exception 'ALREADY_BOOKED'; end if;

  v_cap := _slot_capacity(p_deal_id, p_date, p_time);
  if v_cap is null then raise exception 'INVALID_TIME'; end if;

  select coalesce(sum(guests),0) into v_booked from voucher_bookings
   where deal_id = p_deal_id and booking_date = p_date
     and arrival_time = p_time and status = 'confirmed';

  if v_booked + p_guests > v_cap then
    raise exception 'FULL:%', greatest(v_cap - v_booked, 0);
  end if;

  update voucher_bookings
     set booking_date = p_date, arrival_time = p_time, guests = p_guests,
         status = 'confirmed', updated_at = now()
   where purchase_id = p_purchase_id and status = 'cancelled'
   returning id into v_bk_id;

  if v_bk_id is null then
    insert into voucher_bookings (purchase_id, deal_id, user_id, booking_date, arrival_time, guests)
    values (p_purchase_id, p_deal_id, v_uid, p_date, p_time, p_guests)
    returning id into v_bk_id;
  end if;

  update voucher_purchases
     set expires_at = (p_date + interval '1 day')
   where id = p_purchase_id;

  return jsonb_build_object('booking_id', v_bk_id, 'remaining', v_cap - v_booked - p_guests);
end; $$;
grant execute on function public.book_arrival(bigint, bigint, date, text, int) to authenticated;

-- 5) Reschedule: respect per-date slots ---------------------------------------
create or replace function public.reschedule_arrival(
  p_booking_id bigint,
  p_new_date   date,
  p_new_time   text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_bk     record;
  v_deal   record;
  v_cap    int;
  v_booked bigint;
begin
  if v_uid is null then raise exception 'NOT_ALLOWED'; end if;

  select * into v_bk from voucher_bookings
   where id = p_booking_id and user_id = v_uid and status = 'confirmed';
  if not found then raise exception 'NOT_ALLOWED'; end if;

  select * into v_deal from deals where id = v_bk.deal_id;
  if not found or v_deal.booking_changeable is distinct from true then
    raise exception 'NOT_CHANGEABLE';
  end if;

  perform 1 from voucher_purchases where id = v_bk.purchase_id and status = 'active';
  if not found then raise exception 'NOT_ALLOWED'; end if;

  if p_new_date < current_date then raise exception 'INVALID_DATE'; end if;
  if v_deal.start_date is not null and p_new_date < v_deal.start_date then raise exception 'INVALID_DATE'; end if;
  if v_deal.end_date   is not null and p_new_date > v_deal.end_date   then raise exception 'INVALID_DATE'; end if;
  if v_deal.days is not null and v_deal.days !~* 'daily'
     and position(lower(to_char(p_new_date,'Dy')) in lower(v_deal.days)) = 0
     and not exists (select 1 from deal_date_slots
                     where deal_id = v_bk.deal_id and on_date = p_new_date and active) then
    raise exception 'INVALID_DATE';
  end if;

  v_cap := _slot_capacity(v_bk.deal_id, p_new_date, p_new_time);
  if v_cap is null then raise exception 'INVALID_TIME'; end if;

  select coalesce(sum(guests),0) into v_booked from voucher_bookings
   where deal_id = v_bk.deal_id and booking_date = p_new_date
     and arrival_time = p_new_time and status = 'confirmed'
     and id <> p_booking_id;

  if v_booked + v_bk.guests > v_cap then
    raise exception 'FULL:%', greatest(v_cap - v_booked, 0);
  end if;

  update voucher_bookings
     set booking_date = p_new_date, arrival_time = p_new_time, updated_at = now()
   where id = p_booking_id;

  update voucher_purchases
     set expires_at = (p_new_date + interval '1 day')
   where id = v_bk.purchase_id;

  return jsonb_build_object('booking_id', p_booking_id, 'remaining', v_cap - v_booked - v_bk.guests);
end; $$;
grant execute on function public.reschedule_arrival(bigint, date, text) to authenticated;
