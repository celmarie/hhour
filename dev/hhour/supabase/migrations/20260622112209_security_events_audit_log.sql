-- ============================================================================
-- Security audit log — run in Supabase SQL Editor (or `supabase db push`).
--
-- Append-only event log for important/suspicious activity. Readable ONLY by
-- super-admins; writable ONLY through the sanitizing log_security_event() RPC
-- (no direct client INSERT/UPDATE/DELETE), so it can't be tampered with or spammed
-- into arbitrary shapes.
--
-- NEVER stores passwords, tokens, API keys, or obvious PII: the RPC strips any
-- meta key matching a secrets/PII pattern before insert, and pulls the IP/UA from
-- the trusted request context rather than client input.
-- ============================================================================

create table if not exists public.security_events (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  event_type  text not null,                 -- e.g. failed_login, admin_delete, permission_denied, rate_limit
  severity    text not null default 'info',  -- info | warn | critical
  actor_id    uuid,                           -- who did it (auth.uid()), null for anon
  target_id   uuid,                           -- who/what it affected, if any
  ip          text,
  user_agent  text,
  meta        jsonb not null default '{}'::jsonb
);

create index if not exists idx_security_events_created  on public.security_events (created_at desc);
create index if not exists idx_security_events_type      on public.security_events (event_type);
create index if not exists idx_security_events_severity  on public.security_events (severity);
create index if not exists idx_security_events_ip        on public.security_events (ip);

-- Helper: is the caller a super_admin?
create or replace function public.is_super_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'super_admin');
$$;

-- RLS: super-admins can READ; nobody can write directly (only the RPC, which is
-- SECURITY DEFINER and bypasses RLS).
alter table public.security_events enable row level security;
drop policy if exists sec_read_superadmin on public.security_events;
create policy sec_read_superadmin on public.security_events
  for select to authenticated using (public.is_super_admin());
revoke insert, update, delete on public.security_events from anon, authenticated;

-- Sanitizing writer. Clients pass only type/severity/target/meta; IP + UA come
-- from the request context. Secret/PII-looking meta keys are dropped.
create or replace function public.log_security_event(
  p_type     text,
  p_severity text default 'info',
  p_target   uuid default null,
  p_meta     jsonb default '{}'::jsonb
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_meta jsonb;
  v_hdrs json;
  v_ip   text;
  v_ua   text;
begin
  -- Drop any meta key that looks like a secret or sensitive PII.
  select coalesce(jsonb_object_agg(k, val), '{}'::jsonb) into v_meta
  from jsonb_each(coalesce(p_meta, '{}'::jsonb)) as e(k, val)
  where k !~* '(password|passwd|pwd|secret|token|jwt|api[_-]?key|authorization|bearer|otp|cvv|card|ssn|access[_-]?token|refresh[_-]?token|private[_-]?key)';
  if length(v_meta::text) > 4000 then
    v_meta := jsonb_build_object('_truncated', true);
  end if;

  -- Trusted IP / user-agent from the request context (not client-supplied).
  begin v_hdrs := current_setting('request.headers', true)::json; exception when others then v_hdrs := null; end;
  if v_hdrs is not null then
    v_ip := split_part(coalesce(v_hdrs ->> 'x-forwarded-for', ''), ',', 1);
    v_ua := left(coalesce(v_hdrs ->> 'user-agent', ''), 300);
  end if;

  insert into public.security_events (event_type, severity, actor_id, target_id, ip, user_agent, meta)
  values (
    left(p_type, 80),
    case when p_severity in ('info','warn','critical') then p_severity else 'info' end,
    auth.uid(),
    p_target,
    nullif(v_ip, ''),
    nullif(v_ua, ''),
    v_meta
  );
end;
$$;

-- anon too: failed logins happen before a session exists.
grant execute on function public.log_security_event(text, text, uuid, jsonb) to anon, authenticated;
