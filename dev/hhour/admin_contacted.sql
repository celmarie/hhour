-- Admin-only "messaged" checklist for merchants
-- ---------------------------------------------------------------------------
-- Lets an admin tick off which merchants they've already contacted. Visible and
-- editable ONLY by admins (RLS) — customers/merchants can't see or change it.
-- Keyed by venue id (text) or 'email:<owner-email>' for pre-venue applications.
--
-- Safe to run multiple times.

create table if not exists public.admin_contacted (
  key           text primary key,
  contacted     boolean     not null default true,
  note          text,
  contacted_by  uuid,
  contacted_at  timestamptz not null default now()
);

alter table public.admin_contacted enable row level security;

-- Admins (and super_admins) only — full read/write. No other role can see it.
drop policy if exists admin_contacted_admin_all on public.admin_contacted;
create policy admin_contacted_admin_all on public.admin_contacted
  for all
  using      (coalesce((auth.jwt() -> 'app_metadata' ->> 'role'), '') in ('admin','super_admin'))
  with check (coalesce((auth.jwt() -> 'app_metadata' ->> 'role'), '') in ('admin','super_admin'));

grant select, insert, update, delete on public.admin_contacted to authenticated;
