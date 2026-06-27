-- Why does test@gmail.com get "Invalid email or password" with the right password?
-- The role is fine (merchant/merchant), so the block is at sign-in itself.
-- Supabase returns HTTP 400 for BOTH "invalid login credentials" AND
-- "email not confirmed", and the app shows the same generic message for both.
-- This query tells them apart. Run in: Supabase → SQL Editor.

select id,
       email,
       email_confirmed_at,                         -- NULL  → email not confirmed → login blocked
       banned_until,                               -- set   → account banned → login blocked
       last_sign_in_at,
       updated_at,                                 -- should be ~when you reset the password
       created_at,
       (raw_app_meta_data->>'provider')  as provider,    -- 'email' vs 'google'
       (raw_app_meta_data->>'providers') as providers,
       (encrypted_password is not null)  as has_password  -- false → no password set (e.g. Google-only)
from auth.users
where email = 'test@gmail.com';

-- ── FIXES (run only the one that matches the finding above) ──────────────────

-- A) email_confirmed_at is NULL  → confirm it so password sign-in is allowed:
-- update auth.users set email_confirmed_at = now()
-- where email = 'test@gmail.com' and email_confirmed_at is null;

-- B) banned_until is set  → lift the ban:
-- update auth.users set banned_until = null where email = 'test@gmail.com';

-- C) updated_at is NOT around when you reset, or has_password = false  → the
--    admin reset never landed on this row. Re-run the admin "Set Password"
--    (now with a policy-valid password like Aabcd#1234) and watch for an error
--    toast; if it errors, the endpoint is missing SUPABASE_SERVICE_ROLE_KEY.
