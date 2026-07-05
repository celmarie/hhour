-- Strip old placeholder match entries ("Winner Match 76", "Group F winners",
-- "Third place (A/B/…)", "Loser Semi-final 1" …) from all watch spots.
-- These were snapshots of the pre-bracket fixture names saved inside each
-- spot's matches list; updating WC fixtures can't reach them. Real matches —
-- including new-style labels like "QF1 winner" or "Colombia / Ghana winner" —
-- are kept. Safe to run more than once.
update public.match_screenings
set matches = coalesce((
  select jsonb_agg(t.m)
  from jsonb_array_elements(matches) as t(m)
  where lower(t.m->>'label') !~ '(winner match [0-9]+|winner group [a-l]|runner-up group [a-l]|group [a-l] (winners?|runners?-up)|third place \(|loser semi-final|winner semi-final)'
), '[]'::jsonb)
where matches is not null
  and exists (
    select 1 from jsonb_array_elements(matches) as t2(m)
    where lower(t2.m->>'label') ~ '(winner match [0-9]+|winner group [a-l]|runner-up group [a-l]|group [a-l] (winners?|runners?-up)|third place \(|loser semi-final|winner semi-final)'
  );
