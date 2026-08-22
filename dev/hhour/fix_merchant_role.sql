-- Fix: a venue owner can't sign into /merchant ("Invalid email or password")
-- even with the right password.
--
-- Why: the merchant login gate checks the ROLE in the auth token
-- (raw_app_meta_data.role), which is synced FROM profiles.role by the
-- sync_role_to_auth trigger (see sync_roles_to_token.sql). The admin user list
-- *displays* venue owners as "merchant" for convenience, but their stored
-- profiles.role can still be 'customer' — so the token says 'customer' and the
-- merchant login rejects them.
--
-- Run in: Supabase → SQL Editor. Change the email below as needed.
-- IMPORTANT: requires sync_roles_to_token.sql to have been applied once, and the
-- user must SIGN IN AGAIN afterwards (the token role only refreshes on login).

-- 1) Diagnose — compare the stored role vs the role baked into the token:
select u.email,
       p.role                          as profile_role,
       u.raw_app_meta_data->>'role'    as token_role,
       (select count(*) from public.venues v where v.owner_id = u.id) as venues_owned
from auth.users u
join public.profiles p on p.id = u.id
where u.email = 'test@gmail.com';

-- 2) Fix — promote to merchant. The trigger copies this into the token; the
--    user must log in again for the new token to take effect.
update public.profiles
set role = 'merchant'
where email = 'test@gmail.com'
  and role <> 'merchant';

-- 3) Verify the token now carries the merchant role (after the update):
-- select u.email, p.role, u.raw_app_meta_data->>'role' as token_role
-- from auth.users u join public.profiles p on p.id = u.id
-- where u.email = 'test@gmail.com';
