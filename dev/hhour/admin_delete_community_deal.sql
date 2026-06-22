-- ============================================================================
-- Permanent-delete (with 30-day grace) for community deal submissions.
-- Run in Supabase SQL Editor.
--
-- The admin "Rejected" list has a "🗑️ Delete permanently" action. It does NOT
-- hard-delete instantly — it FLAGS the deal (sets deleted_at = now() and hides it
-- by setting status='removed'). The daily purge cron (api/purge-deleted.js) then
-- erases any community_deals whose deleted_at is older than 30 days — removing the
-- ROW and its PHOTOS from storage.
--
-- This 30-day grace mirrors the account-deletion policy and gives a recovery
-- window: clearing deleted_at within 30 days fully restores the deal.
--
-- This is the one place we intentionally delete contributor photos — but only for
-- deals an admin explicitly flagged for permanent deletion, and only after 30 days.
-- (Account-deletion still RETAINS photos; that policy is unchanged.)
-- ============================================================================

-- 30-day grace marker for admin permanent-deletes.
alter table public.community_deals
  add column if not exists deleted_at timestamptz;

-- Flag a deal for permanent deletion (admins only). Hidden immediately; the cron
-- erases row + photos after the 30-day grace.
create or replace function public.admin_delete_community_deal(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not allowed: admins only';
  end if;
  update public.community_deals
     set deleted_at = now(),
         status     = 'removed'
   where id = p_id;
end;
$$;

grant execute on function public.admin_delete_community_deal(bigint) to authenticated;

-- Restore a deal flagged for deletion, within the 30-day window (admins only).
create or replace function public.admin_restore_deleted_community_deal(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not allowed: admins only';
  end if;
  update public.community_deals
     set deleted_at = null,
         status     = 'rejected'
   where id = p_id;
end;
$$;

grant execute on function public.admin_restore_deleted_community_deal(bigint) to authenticated;

-- Verify (as admin): flagging sets deleted_at; restoring clears it.
--   select public.admin_delete_community_deal(<id>);
--   select id, status, deleted_at from community_deals where id = <id>;
--   select public.admin_restore_deleted_community_deal(<id>);
