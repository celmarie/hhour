-- "Merchant's Email" on Share a Deal — stored OFF the public deals table.
--
-- Why a separate table: community_deals is publicly readable (it IS the feed),
-- and RLS hides rows, not columns — an email column there would be visible to
-- anyone with the anon key. This table holds one contact per deal and only
-- admins (plus the submitter, for their own deal) can read it.
--
-- Run in: Supabase → SQL Editor. The app already writes/reads this table and
-- degrades gracefully until it exists (submissions still work, email is dropped).

create table if not exists public.community_deal_contacts (
  deal_id        bigint primary key references public.community_deals(id) on delete cascade,
  merchant_email text not null,
  user_id        uuid references auth.users(id) on delete set null,  -- who provided it
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

alter table public.community_deal_contacts enable row level security;

-- Admins: full access (uses the same is_admin() as the rest of the hardened RLS).
drop policy if exists "deal contacts admin all" on public.community_deal_contacts;
create policy "deal contacts admin all" on public.community_deal_contacts
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Submitter: may attach a contact ONLY to their own deal, and read/update only
-- what they provided (lets the Edit form prefill). No anon/public access at all.
drop policy if exists "deal contacts owner insert" on public.community_deal_contacts;
create policy "deal contacts owner insert" on public.community_deal_contacts
  for insert to authenticated
  with check (
    auth.uid() = user_id
    and exists (select 1 from public.community_deals cd
                where cd.id = deal_id and cd.user_id = auth.uid())
  );

drop policy if exists "deal contacts owner select" on public.community_deal_contacts;
create policy "deal contacts owner select" on public.community_deal_contacts
  for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "deal contacts owner update" on public.community_deal_contacts;
create policy "deal contacts owner update" on public.community_deal_contacts
  for update to authenticated
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (select 1 from public.community_deals cd
                where cd.id = deal_id and cd.user_id = auth.uid())
  );

-- Keep updated_at fresh on every change.
create or replace function public.touch_community_deal_contacts()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists trg_touch_community_deal_contacts on public.community_deal_contacts;
create trigger trg_touch_community_deal_contacts
  before update on public.community_deal_contacts
  for each row execute function public.touch_community_deal_contacts();

-- ── Verify (should return the 4 policies just created) ───────────────────────
select policyname, cmd from pg_policies
where schemaname = 'public' and tablename = 'community_deal_contacts';
