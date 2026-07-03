-- Admin "merge duplicate match spots" — combines two match_screenings rows for the
-- same venue: union of their matches (deduped by label+kickoff), summed going/crowd
-- counters, then removes the duplicate row. Admin-only. Safe to run multiple times.

create or replace function public.admin_merge_watch_spots(p_keep bigint, p_remove bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_keep   match_screenings%rowtype;
  v_rm     match_screenings%rowtype;
  v_merged jsonb;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role in ('admin','super_admin')) then
    raise exception 'Admins only';
  end if;
  if p_keep = p_remove then raise exception 'Cannot merge a spot into itself'; end if;
  select * into v_keep from match_screenings where id = p_keep;
  if not found then raise exception 'Kept spot not found'; end if;
  select * into v_rm from match_screenings where id = p_remove;
  if not found then raise exception 'Duplicate spot not found'; end if;

  -- Union the two match lists, deduped by label + kickoff time.
  select coalesce(jsonb_agg(m), '[]'::jsonb) into v_merged
  from (
    select distinct on (t.m->>'label', t.m->>'kickoffUTC') t.m
    from jsonb_array_elements(coalesce(v_keep.matches,'[]'::jsonb) || coalesce(v_rm.matches,'[]'::jsonb)) as t(m)
    order by t.m->>'label', t.m->>'kickoffUTC'
  ) s;

  update match_screenings set
    matches     = v_merged,
    going       = coalesce(v_keep.going,0)       + coalesce(v_rm.going,0),
    crowd_busy  = coalesce(v_keep.crowd_busy,0)  + coalesce(v_rm.crowd_busy,0),
    crowd_ok    = coalesce(v_keep.crowd_ok,0)    + coalesce(v_rm.crowd_ok,0),
    crowd_chill = coalesce(v_keep.crowd_chill,0) + coalesce(v_rm.crowd_chill,0),
    image_url   = coalesce(nullif(v_keep.image_url,''), v_rm.image_url),
    notes       = coalesce(nullif(v_keep.notes,''),     v_rm.notes)
  where id = p_keep;

  delete from match_screenings where id = p_remove;

  return jsonb_build_object('kept', p_keep, 'removed', p_remove, 'matches', jsonb_array_length(v_merged));
end;
$$;

grant execute on function public.admin_merge_watch_spots(bigint, bigint) to authenticated;
