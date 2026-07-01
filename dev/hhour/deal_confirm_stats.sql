-- Public "last confirmed active" stats for a deal (for the customer deal detail).
-- ---------------------------------------------------------------------------
-- Customers should see "👍 Last confirmed active <date> · N confirmations" on a
-- community deal, but they must NOT be able to read raw deal_reports rows (those
-- carry reporter names). This SECURITY DEFINER function returns ONLY the aggregate
-- (latest confirmation time + count) — no names, no per-row data — so it's safe to
-- expose to everyone, including guests (anon).
--
-- Safe to run multiple times.

create or replace function public.deal_confirm_stats(p_deal_id bigint, p_deal_kind text default 'community')
returns table(last_at timestamptz, cnt integer)
language sql
security definer
set search_path = public
as $$
  select max(reported_at) as last_at, count(*)::int as cnt
  from public.deal_reports
  where deal_id = p_deal_id
    and status = 'info'
    and (p_deal_kind is null or deal_kind = p_deal_kind);
$$;

grant execute on function public.deal_confirm_stats(bigint, text) to anon, authenticated;
