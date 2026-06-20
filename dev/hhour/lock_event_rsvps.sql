-- ============================================================================
-- RLS fix: event_rsvps was readable by anon — exposing every attendee's user_id
-- and check-in status (attendance enumeration). Restrict reads to the attendee
-- themselves, the event's organizer, and admins. Run in Supabase → SQL Editor.
--
-- The public "going" count is denormalized on community_events.going, so the
-- app never needs anon to read this table. Verified app access patterns:
--   • a user reads/inserts/deletes their OWN rsvp
--   • the organizer reads attendees + toggles check-in for THEIR event
--   • admins manage everything
-- ============================================================================

alter table public.event_rsvps enable row level security;

-- Drop ALL existing policies (one of them currently allows anon to read).
do $$
declare p record;
begin
  for p in select policyname from pg_policies
           where schemaname = 'public' and tablename = 'event_rsvps'
  loop
    execute format('drop policy %I on public.event_rsvps', p.policyname);
  end loop;
end $$;

-- READ: own rsvp, OR the organizer of that event, OR an admin.
create policy "rsvp_read_own_org_admin" on public.event_rsvps
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (select 1 from public.community_events e
               where e.id = event_rsvps.event_id and e.user_id = auth.uid())
    or public.is_admin()
  );

-- INSERT: a user may RSVP only as themselves.
create policy "rsvp_insert_self" on public.event_rsvps
  for insert to authenticated
  with check (user_id = auth.uid());

-- DELETE: a user may cancel only their own rsvp (admins too).
create policy "rsvp_delete_own_admin" on public.event_rsvps
  for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- UPDATE: the organizer (check-in) or an admin.
create policy "rsvp_update_org_admin" on public.event_rsvps
  for update to authenticated
  using (
    exists (select 1 from public.community_events e
            where e.id = event_rsvps.event_id and e.user_id = auth.uid())
    or public.is_admin()
  )
  with check (true);

-- Verify (as anon, should return 0 rows / be blocked):
--   select * from event_rsvps limit 1;
