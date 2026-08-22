-- Store the venue's type (Bar/Restaurant/Hotel/… — from the admin Content categories)
-- on the venues table. The app creates venues with a venue_type; without this column
-- the insert errored ("Could not find the 'venue_type' column"). The app is resilient
-- (it drops the field if the column is missing), but adding it lets the type be saved
-- and shown in the admin merchant list. Safe to run more than once.
--
-- Run in: Supabase → SQL Editor.

alter table if exists public.venues
  add column if not exists venue_type text;
