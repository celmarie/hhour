-- Transaction + approval notifications (in-app alerts; OS push flows automatically
-- via the existing notifications→push trigger). Safe to run multiple times.
--
-- 1) tx_notify(purchase_id, event): notifies BOTH the buyer and the venue owner
--    about a transaction. Called by the app after purchase and redemption.
--    SECURITY DEFINER because a customer can't insert a notification row for the
--    merchant (and vice versa) under normal RLS.

create or replace function public.tx_notify(p_purchase_id bigint, p_event text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_buyer  uuid;
  v_owner  uuid;
  v_code   text;
  v_qty    int;
  v_title  text;
  v_venue  text;
  v_buyer_name text;
begin
  select vp.user_id, vp.code, coalesce(vp.qty,1), d.title, v.owner_id, v.name
    into v_buyer, v_code, v_qty, v_title, v_owner, v_venue
  from voucher_purchases vp
  join deals d on d.id = vp.deal_id
  left join venues v on v.id = d.venue_id
  where vp.id = p_purchase_id;
  if v_buyer is null then return; end if;

  -- Only someone involved in the transaction may trigger its notifications.
  if auth.uid() is distinct from v_buyer and auth.uid() is distinct from v_owner then
    return;
  end if;

  select coalesce(name, 'A customer') into v_buyer_name from profiles where id = v_buyer;

  if p_event = 'purchased' then
    insert into notifications (user_id, type, icon, icon_class, read, title, body)
    values (v_buyer, 'system', '🎟️', 'ai-green', false,
            'Purchase confirmed!',
            v_title || coalesce(' at ' || v_venue, '') || ' — voucher ' || v_code || ' (x' || v_qty || ') is in My Vouchers.');
    if v_owner is not null and v_owner <> v_buyer then
      insert into notifications (user_id, type, icon, icon_class, read, title, body)
      values (v_owner, 'system', '💰', 'ai-green', false,
              'New sale!',
              v_buyer_name || ' bought ' || v_title || ' (x' || v_qty || '). Voucher ' || v_code || '.');
    end if;

  elsif p_event = 'redeemed' then
    insert into notifications (user_id, type, icon, icon_class, read, title, body)
    values (v_buyer, 'rewards', '✅', 'ai-green', false,
            'Voucher redeemed — enjoy! 🍹',
            v_title || coalesce(' at ' || v_venue, '') || ' (voucher ' || v_code || '). Credits added to your account.');
    if v_owner is not null and v_owner <> v_buyer then
      insert into notifications (user_id, type, icon, icon_class, read, title, body)
      values (v_owner, 'system', '🎟️', 'ai-green', false,
              'Voucher redeemed at your venue',
              v_buyer_name || ' redeemed ' || v_title || ' (voucher ' || v_code || ').');
    end if;
  end if;
end;
$$;

grant execute on function public.tx_notify(bigint, text) to authenticated;

-- 2) Deal-approved notification: fires for EVERY path that flips a community deal
--    to approved (single approve, approve-all, edit&post, admin tools…), so the
--    submitter always hears about it. Replaces the old single-path client insert.

create or replace function public.notify_deal_approved()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status = 'approved' and OLD.status is distinct from 'approved' and NEW.user_id is not null then
    insert into notifications (user_id, type, icon, icon_class, read, title, body, deal_ref)
    values (NEW.user_id, 'rewards', '🎉', 'ai-green', false,
            'Your deal is live! 🎉',
            coalesce(NEW.venue_name, 'Your deal') || ' — "' || coalesce(NEW.title,'your happy hour') || '" was approved and is now visible to everyone. Thanks for contributing!',
            'uc:' || NEW.id);
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_notify_deal_approved on public.community_deals;
create trigger trg_notify_deal_approved
  after update on public.community_deals
  for each row execute function public.notify_deal_approved();

-- 3) Event transactions: joining an event notifies the attendee (confirmation) and
--    the host (new attendee, with paid-ticket info when applicable); cancelling
--    notifies the host. Triggers on event_rsvps cover every join/cancel path.

create or replace function public.notify_event_rsvp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host   uuid;
  v_title  text;
  v_date   text;
  v_price  text;
  v_ticket text;
  v_name   text;
begin
  select e.user_id, e.title, coalesce(e.event_date,''), coalesce(e.price::text,''), coalesce(e.ticket_type,'free')
    into v_host, v_title, v_date, v_price, v_ticket
  from community_events e where e.id = NEW.event_id;
  if v_title is null then return NEW; end if;
  select coalesce(name,'Someone') into v_name from profiles where id = NEW.user_id;

  -- Attendee confirmation
  insert into notifications (user_id, type, icon, icon_class, read, title, body)
  values (NEW.user_id, 'system', '🎉', 'ai-green', false,
          'You''re going!',
          v_title || case when v_date <> '' then ' · ' || v_date else '' end
          || case when v_ticket <> 'free' and v_price <> '' then ' · ticket ' || v_price else '' end);

  -- Host alert
  if v_host is not null and v_host <> NEW.user_id then
    insert into notifications (user_id, type, icon, icon_class, read, title, body)
    values (v_host, 'system', '🎟️', 'ai-green', false,
            'New attendee for your event',
            v_name || ' joined "' || v_title || '"'
            || case when v_ticket <> 'free' and v_price <> '' then ' (paid ticket ' || v_price || ')' else '' end || '.');
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_notify_event_rsvp on public.event_rsvps;
create trigger trg_notify_event_rsvp
  after insert on public.event_rsvps
  for each row execute function public.notify_event_rsvp();

create or replace function public.notify_event_rsvp_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host  uuid;
  v_title text;
  v_name  text;
begin
  select e.user_id, e.title into v_host, v_title
  from community_events e where e.id = OLD.event_id;
  if v_title is null or v_host is null or v_host = OLD.user_id then return OLD; end if;
  select coalesce(name,'Someone') into v_name from profiles where id = OLD.user_id;
  insert into notifications (user_id, type, icon, icon_class, read, title, body)
  values (v_host, 'system', '↩️', 'ai-red', false,
          'Attendee cancelled',
          v_name || ' can no longer make it to "' || v_title || '".');
  return OLD;
end;
$$;

drop trigger if exists trg_notify_event_rsvp_cancel on public.event_rsvps;
create trigger trg_notify_event_rsvp_cancel
  after delete on public.event_rsvps
  for each row execute function public.notify_event_rsvp_cancel();
