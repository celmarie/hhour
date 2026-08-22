-- Hard sell cap: a deal can never sell more vouchers than its allocation
-- (deals.slots_total). Enforced in the database so no purchase path can
-- bypass it; concurrent buyers serialize on the deal row. Deals with no
-- allocation (slots_total null/0) remain unlimited. Safe to run again.

create or replace function public.enforce_voucher_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total int;
  v_sold  int;
begin
  select slots_total into v_total from deals where id = NEW.deal_id for update;
  if v_total is null or v_total <= 0 then return NEW; end if;
  select coalesce(sum(qty), 0) into v_sold from voucher_purchases
   where deal_id = NEW.deal_id and status in ('active','used');
  if v_sold + coalesce(NEW.qty, 1) > v_total then
    raise exception 'SOLD_OUT: % of % vouchers already sold', v_sold, v_total;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_voucher_cap on public.voucher_purchases;
create trigger trg_voucher_cap
  before insert on public.voucher_purchases
  for each row execute function public.enforce_voucher_cap();
