-- Booking notifications: merchant gets an alert when an arrival booking is made,
-- rescheduled or cancelled; customers get a reminder on the morning of their
-- booking. Counts are the voucher QUANTITY purchased (there is no separate
-- guest count in the flow). Rides the existing notifications table + push
-- trigger, so OS push works automatically. Safe to run more than once.

-- 1) Merchant alerts ---------------------------------------------------------
create or replace function public.notify_booking_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
  v_deal  text;
  v_name  text;
  v_qty   int;
  v_lbl   text;
begin
  select v.owner_id, d.title into v_owner, v_deal
  from deals d join venues v on v.id = d.venue_id
  where d.id = NEW.deal_id;
  if v_owner is null then return NEW; end if;
  select coalesce(name, 'A customer') into v_name from profiles where id = NEW.user_id;
  select qty into v_qty from voucher_purchases where id = NEW.purchase_id;
  v_qty := coalesce(v_qty, NEW.guests, 1);
  v_lbl := v_qty || ' voucher' || case when v_qty > 1 then 's' else '' end;

  if TG_OP = 'INSERT' and NEW.status = 'confirmed' then
    insert into notifications (user_id, type, icon, icon_class, read, title, body, deal_ref)
    values (v_owner, 'system', '📅', 'ai-green', false,
            'New arrival booking',
            v_name || ' booked an arrival for ' || to_char(NEW.booking_date, 'DD Mon') || ' at ' || NEW.arrival_time
            || ' (' || v_lbl || ') — "' || coalesce(v_deal, 'your deal') || '".',
            'v:' || NEW.deal_id);
  elsif TG_OP = 'UPDATE' and NEW.status = 'cancelled' and OLD.status = 'confirmed' then
    insert into notifications (user_id, type, icon, icon_class, read, title, body, deal_ref)
    values (v_owner, 'system', '🗓️', 'ai-red', false,
            'Booking cancelled',
            v_name || ' cancelled their ' || to_char(NEW.booking_date, 'DD Mon') || ' ' || NEW.arrival_time
            || ' booking (' || v_lbl || ') — "' || coalesce(v_deal, 'your deal') || '".',
            'v:' || NEW.deal_id);
  elsif TG_OP = 'UPDATE' and NEW.status = 'confirmed' and OLD.status = 'confirmed'
        and (NEW.booking_date <> OLD.booking_date or NEW.arrival_time <> OLD.arrival_time) then
    insert into notifications (user_id, type, icon, icon_class, read, title, body, deal_ref)
    values (v_owner, 'system', '📅', 'ai-purple', false,
            'Booking rescheduled',
            v_name || ' moved their booking to ' || to_char(NEW.booking_date, 'DD Mon') || ' at ' || NEW.arrival_time
            || ' (' || v_lbl || ') — "' || coalesce(v_deal, 'your deal') || '".',
            'v:' || NEW.deal_id);
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_notify_booking on public.voucher_bookings;
create trigger trg_notify_booking
  after insert or update on public.voucher_bookings
  for each row execute function public.notify_booking_change();

-- 2) Customer day-of reminders (07:00 UTC ≈ 9am CEST, every morning) ---------
create extension if not exists pg_cron;

select cron.schedule('booking-reminders-daily', '0 7 * * *', $CRON$
  insert into public.notifications (user_id, type, icon, icon_class, read, title, body, deal_ref)
  select b.user_id, 'system', '⏰', 'ai-red', false,
         'Booking today! ⏰',
         'Your arrival is booked for ' || b.arrival_time || ' today — "' || coalesce(d.title, 'your deal')
         || '"' || coalesce(' at ' || v.name, '') || '. Show your voucher QR when you arrive.',
         'v:' || b.deal_id
  from public.voucher_bookings b
  join public.deals d on d.id = b.deal_id
  left join public.venues v on v.id = d.venue_id
  where b.booking_date = current_date
    and b.status = 'confirmed'
    and b.user_id is not null;
$CRON$);
