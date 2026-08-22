-- "View Deal" opens the RIGHT deal: notifications get a deal_ref column
-- ("uc:<community deal id>" / "v:<verified deal id>") and the deal-approved
-- trigger stamps it. The app reads deal_ref and deep-links to that exact deal;
-- notifications without it keep the old behaviour (open the deals screen).
-- Safe to run more than once.

alter table public.notifications add column if not exists deal_ref text;

create or replace function public.notify_deal_approved()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status = 'approved' and OLD.status is distinct from 'approved' and NEW.user_id is not null then
    insert into notifications (user_id, type, icon, icon_class, read, title, body, deal_ref)
    values (NEW.user_id, 'rewards', '🎉', 'ai-green', false,
            'Your deal is live! 🎉',
            coalesce(NEW.venue_name, 'Your deal') || ' — "' || coalesce(NEW.title,'your happy hour') || '" was approved and is now visible to everyone. Thanks for contributing!',
            'uc:' || NEW.id);
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_notify_deal_approved on public.community_deals;
create trigger trg_notify_deal_approved
  after update on public.community_deals
  for each row execute function public.notify_deal_approved();
