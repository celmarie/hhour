-- Definitive password set for a user — bypasses the admin endpoint and any
-- client-side quirks by writing the bcrypt hash directly (Supabase uses bcrypt
-- via the pgcrypto extension). Use when an admin "reset password" appears to
-- succeed but the user still can't sign in.
--
-- Run in: Supabase → SQL Editor. Change the email / password as needed.
-- The role/token are unaffected, so the user can sign in immediately afterward.

update auth.users
set encrypted_password = crypt('Aabcd#1234', gen_salt('bf')),
    updated_at = now()
where email = 'test@gmail.com';

-- If you get: ERROR  function crypt(...) does not exist
-- then pgcrypto lives in the "extensions" schema — use this form instead:
--
-- update auth.users
-- set encrypted_password = extensions.crypt('Aabcd#1234', extensions.gen_salt('bf')),
--     updated_at = now()
-- where email = 'test@gmail.com';

-- Verify it ran (1 row updated, updated_at = now):
-- select email, updated_at from auth.users where email = 'test@gmail.com';
