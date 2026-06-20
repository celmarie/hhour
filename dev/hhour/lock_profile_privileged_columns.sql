-- ============================================================================
-- SECURITY FIX — lock privileged profile columns (run in Supabase SQL Editor)
--
-- AUDIT FINDING: the "Own profile update" RLS policy lets a user update ANY
-- column of their own profiles row, with no guard on role/status/credits/
-- wallet_balance. From the browser console a logged-in user could:
--   • update({ role: 'super_admin' })      → become admin (role syncs to JWT) 🔴🔴
--   • update({ status: 'active' })          → un-ban themselves 🔴
--   • update({ credits: 9999999,
--              wallet_balance: 9999999 })   → mint credits + HappyCash 🔴
--
-- FIX: a BEFORE UPDATE trigger blocks changes to these columns from a direct
-- client call (role = anon/authenticated) unless the caller is an admin. Legit
-- user balance changes go through the SECURITY DEFINER RPCs below (which run as
-- the function owner — NOT anon/authenticated — so the trigger allows them).
--
-- ROLLOUT ORDER (avoids any broken window):
--   STEP 1 — run the "STEP 1" section below now (just adds the RPCs; harmless).
--   STEP 2 — deploy the new app build that calls those RPCs (already wired in
--            happyhourly-complete.html).
--   STEP 3 — run the "STEP 3" section below (adds the guard trigger). Do this
--            only AFTER the new build is live, so the old build's direct
--            credit/wallet writes aren't blocked mid-transition.
-- ============================================================================


-- ████████████████  STEP 1 — RUN NOW (safe; just adds functions)  ████████████

-- ── RPCs the client uses for its own balance changes ────────────────────────
-- Earn credits (purchase/review/redeem/event). Amount is capped server-side and
-- de-duplicated by (user, reason, ref) so the same action can't be farmed.
create or replace function public.award_credits(p_amount integer, p_reason text, p_ref text)
returns integer language plpgsql security definer set search_path = public as $$
declare v_new integer; v_amt integer;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  v_amt := least(greatest(coalesce(p_amount, 0), 0), 200);  -- legit earns are <= ~88
  if p_ref is not null and exists (
    select 1 from credits_ledger where user_id = auth.uid() and reason = p_reason and ref = p_ref
  ) then
    select credits into v_new from profiles where id = auth.uid();
    return v_new;  -- already credited for this action — no double award
  end if;
  insert into credits_ledger(user_id, delta, reason, ref) values (auth.uid(), v_amt, p_reason, p_ref);
  update profiles set credits = greatest(0, coalesce(credits,0) + v_amt) where id = auth.uid()
    returning credits into v_new;
  return v_new;
end; $$;
grant execute on function public.award_credits(integer, text, text) to authenticated;

-- Spend HappyCash. Decrement-only and never below zero — safe for the client.
create or replace function public.spend_wallet(p_amount numeric, p_ref text)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_new numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Invalid amount'; end if;
  update profiles set wallet_balance = wallet_balance - p_amount
    where id = auth.uid() and wallet_balance >= p_amount
    returning wallet_balance into v_new;
  if v_new is null then raise exception 'Insufficient balance'; end if;
  insert into wallet_ledger(user_id, kind, euros, ref) values (auth.uid(), 'spend', -p_amount, p_ref);
  return v_new;
end; $$;
grant execute on function public.spend_wallet(numeric, text) to authenticated;

-- Convert the user's OWN earned credits to HappyCash at the server rate.
-- Rate default = 100 credits / €1 (matches _ccGet('conversion',100)); change
-- v_rate here if your configured rate differs. Server computes euros so the
-- client can't dictate the payout.
create or replace function public.convert_credits_to_wallet(p_credits integer)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_rate integer := 100; v_euros numeric; v_have integer;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_credits is null or p_credits < v_rate then raise exception 'Minimum % credits', v_rate; end if;
  p_credits := (p_credits / v_rate) * v_rate;             -- whole-euro chunks
  v_euros := round((p_credits::numeric / v_rate), 2);
  select credits into v_have from profiles where id = auth.uid();
  if coalesce(v_have,0) < p_credits then raise exception 'Insufficient credits'; end if;
  update profiles set credits = credits - p_credits, wallet_balance = wallet_balance + v_euros
    where id = auth.uid();
  insert into credits_ledger(user_id, delta, reason, ref) values (auth.uid(), -p_credits, 'Converted to HappyCash', null);
  insert into wallet_ledger(user_id, kind, credits, euros, ref) values (auth.uid(), 'convert_in', p_credits, v_euros, 'credit conversion');
  return v_euros;
end; $$;
grant execute on function public.convert_credits_to_wallet(integer) to authenticated;

-- ████████  STEP 3 — RUN ONLY AFTER the new app build is deployed  ████████████
-- ── The guard trigger ───────────────────────────────────────────────────────
-- NOTE: deliberately SECURITY INVOKER (the default) so current_user reflects the
-- real executor: 'authenticated'/'anon' for a direct client write, but the
-- function-owner role (e.g. 'postgres') when called from a SECURITY DEFINER RPC.
create or replace function public.guard_profile_privileged_cols()
returns trigger language plpgsql as $$
begin
  if (new.role           is distinct from old.role
   or new.status         is distinct from old.status
   or new.credits        is distinct from old.credits
   or new.wallet_balance is distinct from old.wallet_balance)
  and current_user in ('anon', 'authenticated')   -- a direct PostgREST client write
  and not public.is_admin()                         -- admins may still manage these
  then
    raise exception 'Not allowed: role/status/credits/wallet_balance can only be changed by an admin or a server function';
  end if;
  return new;
end; $$;

drop trigger if exists trg_guard_profile_priv on public.profiles;
create trigger trg_guard_profile_priv
  before update on public.profiles
  for each row execute function public.guard_profile_privileged_cols();

-- Verify (as a normal logged-in user, these should now FAIL):
--   update profiles set role='super_admin'  where id = auth.uid();
--   update profiles set credits = 9999999   where id = auth.uid();
-- And these should still work for that user: award_credits(), spend_wallet(),
-- convert_credits_to_wallet(); admins can still edit users normally.
