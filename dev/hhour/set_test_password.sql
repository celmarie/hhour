-- Definitive, VERIFIABLE password reset for a Supabase user.
-- Login was failing with "Invalid login credentials", which means the stored
-- password never actually changed (a bare crypt()/gen_salt() errors out because
-- pgcrypto lives in the "extensions" schema on Supabase).
--
-- Run ALL of this in: Supabase → SQL Editor. The final RETURNING row PROVES it
-- applied — you should see 1 row, a hash_prefix like "$2a$" or "$2b$", and a
-- fresh updated_at. Then sign in with the password below. No re-login of other
-- sessions needed (role/token are untouched).

-- 1) Make sure pgcrypto is available (no-op if already installed).
create extension if not exists pgcrypto with schema extensions;

-- 2) Set the password using the fully-qualified functions, and SHOW the result.
update auth.users
set encrypted_password = extensions.crypt('Aabcd#1234', extensions.gen_salt('bf')),
    updated_at = now()
where email = 'test@gmail.com'
returning id, email, left(encrypted_password, 4) as hash_prefix, updated_at;

-- Expected: exactly 1 row, hash_prefix = '$2a$' (or '$2b$'), updated_at = now.
--   • 0 rows           → the email doesn't match (check for typos / trailing space).
--   • function error   → pgcrypto didn't install; check the extension step above.
-- After a successful row, log in with: test@gmail.com / Aabcd#1234
