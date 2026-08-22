-- ============================================================================
-- SECURITY FIX — admin RPC authorization
-- Run in Supabase → SQL Editor.
--
-- AUDIT FINDING (verified live with the public anon key, no login):
--   public.admin_get_all_users(), admin_get_all_profiles(), admin_get_all_venues()
--   are SECURITY DEFINER (they bypass Row Level Security) and DO NOT check that
--   the caller is an admin. Because the anon key is embedded in the web app,
--   anyone on the internet could call them and dump every user, profile and
--   venue (names, emails, roles). This is a critical PII exposure.
--
--   (By contrast, admin_send_notification() already checks is_admin() — that's
--   the pattern the others were missing.)
-- ============================================================================


-- ── PART 1 — CRITICAL, APPLY NOW ────────────────────────────────────────────
-- Revoke API access to the three leaking read functions. Safe: the app already
-- falls back to direct table reads, which the existing RLS policies
-- ("Admin read all" on profiles, "Admin reads all venues" on venues) restrict
-- to admins — so admins keep seeing everything, while non-admins/anon get
-- nothing. The DO block handles any function signature.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('admin_get_all_users','admin_get_all_profiles','admin_get_all_venues')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    raise notice 'revoked execute on %', r.sig;
  end loop;
end $$;

-- Verify (optional): this should now fail with "permission denied for function".
-- select * from public.admin_get_all_users();


-- ── PART 1B — IMMEDIATE STOPGAP (safe, run now) ─────────────────────────────
-- Revoke anon/PUBLIC execute on the ADMIN-ONLY unguarded functions. This blocks
-- the unauthenticated (internet-wide) attack immediately and is 100% safe: every
-- legitimate caller is a logged-in admin, so they keep the `authenticated` grant.
-- It is NOT the full fix — a logged-in non-admin could still call these until
-- PART 4 adds the in-function is_admin() guard — but it removes the worst case.
-- (cancel_rsvp / increment_deal_slots_sold / watch_spot_set_going are
-- user-callable and possibly by guests, so they are deliberately left for the
-- proper ownership/bounds fix in PART 4 rather than an anon revoke.)
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'admin_adjust_credits','admin_approve_event','admin_block_user',
        'admin_deactivate_deal','admin_delete_review','admin_dismiss_report',
        'admin_get_all_events','admin_reject_event','admin_remove_community_deal',
        'admin_send_notification','admin_send_notification_to_users'
      )
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
    raise notice 'revoked anon/public execute on %', r.sig;
  end loop;
end $$;


-- ── PART 2 — AUDIT THE REMAINING PRIVILEGED FUNCTIONS ───────────────────────
-- The MUTATING admin_* / increment_* functions (e.g. admin_adjust_credits,
-- increment_profile_credits, admin_deactivate_deal, admin_delete_review,
-- admin_dismiss_report, admin_remove_community_deal,
-- admin_send_notification_to_users, increment_deal_slots_sold,
-- watch_spot_set_going) can't be locked with REVOKE — the app calls them when an
-- admin/user legitimately acts, and there's no RLS fallback for a mutation.
-- They must instead enforce authorization INSIDE the function, like
-- admin_send_notification does:
--
--     if not exists (select 1 from profiles
--                    where id = auth.uid() and role in ('admin','super_admin'))
--     then raise exception 'Not authorized: admin role required'; end if;
--
-- Run the query below and share the output. `has_caller_check = false` on a
-- SECURITY DEFINER function is a red flag — especially the credit functions
-- (a user could otherwise grant themselves unlimited credits). Paste the
-- definitions back and the missing guards can be added precisely.
select
  p.proname                                  as function,
  pg_get_function_identity_arguments(p.oid)  as args,
  p.prosecdef                                as security_definer,
  (pg_get_functiondef(p.oid) ilike '%is_admin%'
     or pg_get_functiondef(p.oid) ilike '%auth.uid()%') as has_caller_check,
  array(
    select grantee::text
    from information_schema.role_routine_grants g
    where g.specific_schema = 'public'
      and g.routine_name = p.proname
      and g.privilege_type = 'EXECUTE'
  )                                          as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (
    p.proname like 'admin\_%'
    or p.proname like 'increment\_%'
    or p.proname like '%\_arrival'
    or p.proname in ('watch_spot_set_going','cancel_rsvp')
  )
order by p.prosecdef desc, has_caller_check asc, p.proname;

-- To see the full body of a specific one:
-- select pg_get_functiondef('public.increment_profile_credits'::regproc);


-- ── PART 3 — DUMP THE UNGUARDED FUNCTION BODIES ─────────────────────────────
-- Run this and paste the full output. Each row is the complete CREATE statement
-- for a SECURITY DEFINER function that currently has NO caller check. With these
-- bodies, each can be re-issued with an is_admin() guard added (admin_* ones) or
-- an ownership check (cancel_rsvp → user_id = auth.uid(); the increment_*/
-- watch_spot_* ones bounded + authenticated-only).
select string_agg(pg_get_functiondef(p.oid), E'\n\n-- ====================\n\n' order by p.proname)
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_adjust_credits','admin_approve_event','admin_block_user',
    'admin_deactivate_deal','admin_delete_review','admin_dismiss_report',
    'admin_get_all_events','admin_reject_event','admin_remove_community_deal',
    'admin_send_notification_to_users','admin_send_notification',
    'cancel_rsvp','increment_deal_slots_sold','watch_spot_set_going'
  );


-- ── PART 4 — THE FULL FIX: add authorization guards ─────────────────────────
-- Re-issues each unguarded function with the proper check, preserving its exact
-- behaviour and return type. Admin-only functions require public.is_admin();
-- cancel_rsvp is scoped to the caller's own RSVP (fixes the IDOR);
-- increment_deal_slots_sold requires login + a bounded amount; watch_spot_set_going
-- clamps its delta. All set search_path=public (SECURITY DEFINER hardening).
-- Idempotent — safe to re-run. (The 6-arg admin_send_notification is already
-- guarded and is intentionally left untouched.)

-- credits (CRITICAL) ----------------------------------------------------------
create or replace function public.admin_adjust_credits(p_user_id uuid, p_delta integer, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  update profiles set credits = greatest(0, credits + p_delta) where id = p_user_id;
  insert into credits_ledger(user_id, delta, reason, ref) values (p_user_id, p_delta, p_reason, 'admin-adj');
end; $$;

-- user moderation -------------------------------------------------------------
create or replace function public.admin_block_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized: admin role required'; end if;
  update profiles set role = 'blocked' where id = p_user_id;
end; $$;

-- event moderation ------------------------------------------------------------
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

-- content moderation ----------------------------------------------------------
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

-- notifications: broadcast-by-role overload (the 5-arg one that lacked a guard)-
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

-- cancel_rsvp: FIX IDOR — only the caller's own RSVP (ignore passed user_id) ---
create or replace function public.cancel_rsvp(p_event_id bigint, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from event_rsvps where event_id = p_event_id and user_id = auth.uid();
  if found then
    update community_events set going = greatest(0, going - 1) where id = p_event_id;
  end if;
end; $$;

-- increment_deal_slots_sold: require login + bounded amount --------------------
-- NOTE: robust integrity would verify a matching paid voucher_purchase; this at
-- least blocks anon/negative/mass inflation. Tighten later if needed.
create or replace function public.increment_deal_slots_sold(p_deal_id bigint, p_amount integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 50 then raise exception 'Invalid amount'; end if;
  update deals set slots_sold = slots_sold + p_amount, claimed = claimed + p_amount where id = p_deal_id;
end; $$;

-- watch_spot_set_going: clamp delta to +/-1 (intentionally guest-callable) -----
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

-- Verify after running: every row should now show has_caller_check = true
-- (except watch_spot_set_going, which is bounded rather than auth-gated). Re-run
-- the PART 2 query to confirm.
