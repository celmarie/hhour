-- Photo safety: keep an archive of removed photo URLs so an accidental removal is
-- always reversible. The original files are never deleted from Storage (the app has
-- no storage.remove() for edits), so re-linking an archived URL fully restores it.
--
-- Safe to run multiple times.

alter table public.community_deals add column if not exists removed_images jsonb not null default '[]'::jsonb;
alter table public.deals           add column if not exists removed_images jsonb not null default '[]'::jsonb;
