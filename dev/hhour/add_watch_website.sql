-- Watch spots: Instagram / website of the venue (mandatory on new submissions;
-- the app works without this column but can't store the link until it exists).
-- Safe to run more than once.
alter table public.match_screenings add column if not exists website text;
