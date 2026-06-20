-- ============================================================================
-- RUN THIS WHOLE FILE — Supabase → SQL Editor → paste all → Run.
-- One shot, top to bottom. Safe to re-run. No diagnostics, just the fix.
--
-- Closes the admin-RPC authorization holes from the security audit:
--   • locks the functions that leaked all users/profiles/venues to anyone
--   • adds an admin check to every admin action (credits, block, delete, etc.)
--   • fixes the cancel_rsvp IDOR and bounds the slot/going counters
-- ============================================================================

-- 1) Lock the read functions that dumped all users/profiles/venues -----------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('admin_get_all_users','admin_get_all_profiles','admin_get_all_venues')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- 2) Add authorization guards to every unguarded function --------------------

create or replace function public.admin_adjust_credits(p_user_id uuid, p_delta integer, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  update profiles set credits = greatest(0, credits + p_delta) where id = p_user_id;
  insert into credits_ledger(user_id, delta, reason, ref) values (p_user_id, p_delta, p_reason, 'admin-adj');
end; $$;

create or replace function public.admin_block_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  update profiles set role = 'blocked' where id = p_user_id;
end; $$;

create or replace function public.admin_approve_event(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  update community_events set status = 'approved' where id = p_id;
end; $$;

create or replace function public.admin_reject_event(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  update community_events set status = 'rejected' where id = p_id;
end; $$;

create or replace function public.admin_get_all_events()
returns setof community_events language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  return query select * from community_events order by created_at desc;
end; $$;

create or replace function public.admin_deactivate_deal(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  update deals set status = 'inactive' where id = p_id;
end; $$;

create or replace function public.admin_remove_community_deal(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  update community_deals set status = 'rejected' where id = p_id;
end; $$;

create or replace function public.admin_delete_review(p_review_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  delete from reviews where id = p_review_id;
end; $$;

create or replace function public.admin_dismiss_report(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  delete from deal_reports where id = p_id;
end; $$;

create or replace function public.admin_send_notification(p_title text, p_body text, p_type text default 'system', p_icon text default '📣', p_role text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  insert into notifications (user_id, type, title, body, icon)
  select id, p_type, p_title, p_body, p_icon from profiles
  where p_role is null or role = p_role;
  get diagnostics v_count = row_count;
  return v_count;
end; $$;

create or replace function public.admin_send_notification_to_users(p_user_ids uuid[], p_title text, p_body text, p_type text default 'system', p_icon text default '📣')
returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  insert into notifications (user_id, type, title, body, icon)
  select unnest(p_user_ids), p_type, p_title, p_body, p_icon;
  get diagnostics v_count = row_count;
  return v_count;
end; $$;

create or replace function public.cancel_rsvp(p_event_id bigint, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from event_rsvps where event_id = p_event_id and user_id = auth.uid();
  if found then
    update community_events set going = greatest(0, going - 1) where id = p_event_id;
  end if;
end; $$;

create or replace function public.increment_deal_slots_sold(p_deal_id bigint, p_amount integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 50 then raise exception 'Invalid amount'; end if;
  update deals set slots_sold = slots_sold + p_amount, claimed = claimed + p_amount where id = p_deal_id;
end; $$;

create or replace function public.watch_spot_set_going(p_id bigint, p_delta integer)
returns integer language plpgsql security definer set search_path = public as $$
declare v integer;
begin
  update public.match_screenings
     set going = greatest(0, coalesce(going,0) + sign(coalesce(p_delta,0))::int)
   where id = p_id
  returning going into v;
  return v;
end; $$;

-- Done. Everything above is idempotent — re-running it is harmless.
