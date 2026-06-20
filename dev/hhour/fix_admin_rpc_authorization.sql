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
