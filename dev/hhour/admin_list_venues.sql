-- Bulletproof admin venue read.
-- 13 venues exist but the browser can't read them (RLS), even for a super_admin.
-- This SECURITY DEFINER function runs as the function owner, bypassing row-level
-- security entirely, and returns ALL venues (with owner name/email) — but only if
-- the caller is an admin/super_admin. The admin Merchants list calls this.
-- Safe to run more than once.
--
-- Run in: Supabase → SQL Editor.

create or replace function public.admin_list_venues()
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Only admins/super_admins get data; everyone else gets an empty list.
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin','super_admin')
  ) then
    return '[]'::json;
  end if;

  return (
    select coalesce(json_agg(row_to_json(t)), '[]'::json)
    from (
      select v.*, p.name as owner_name, p.email as owner_email
      from public.venues v
      left join public.profiles p on p.id = v.owner_id
      order by v.created_at desc
    ) t
  );
end;
$$;

grant execute on function public.admin_list_venues() to authenticated;
