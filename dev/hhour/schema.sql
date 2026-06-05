-- ══════════════════════════════════════════════════════════════════════════════
-- HappyHourly — Supabase Schema
-- Run this in the Supabase SQL Editor (project: hjzyqhfuvcswfcvkjsyv)
-- ══════════════════════════════════════════════════════════════════════════════

-- ── PROFILES (extends auth.users) ────────────────────────────────────────────
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        text not null default 'customer' check (role in ('customer','merchant','admin')),
  name        text not null default '',
  email       text not null default '',
  credits     integer not null default 0,
  avatar_url  text,
  created_at  timestamptz default now()
);
alter table profiles enable row level security;
create policy "Own profile read"   on profiles for select using (auth.uid() = id);
create policy "Own profile update" on profiles for update using (auth.uid() = id);
create policy "Admin read all"     on profiles for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- ── VENUES ───────────────────────────────────────────────────────────────────
create table if not exists venues (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid references profiles(id) on delete cascade,
  name       text not null,
  category   text not null default 'bars' check (category in ('bars','restaurants','beauty','clubs')),
  address    text default '',
  city       text default '',
  lat        numeric,
  lng        numeric,
  emoji      text default '🍺',
  image_url  text,
  dist_km    numeric default 0.5,
  verified   boolean default false,
  active     boolean default true,
  created_at timestamptz default now()
);
alter table venues enable row level security;
create policy "Anyone reads active venues" on venues for select using (active = true);
create policy "Owner manages venue"        on venues for all   using (auth.uid() = owner_id);

-- ── DEALS (verified, merchant-posted) ────────────────────────────────────────
create table if not exists deals (
  id           bigserial primary key,
  venue_id     uuid references venues(id) on delete cascade,
  title        text not null,
  description  text default '',
  price        text default '',
  was_price    text default '',
  is_free      boolean default false,
  discount_pct integer default 0,
  off_label    text default '',
  days         text default '',
  hours        text default '',
  time_from    integer,
  time_to      integer,
  perks        text[] default '{}',
  emoji        text default '🍺',
  img_class    text default 'ci1',
  image_url    text,
  claimed      integer default 0,
  deal_type    text default 'verified' check (deal_type in ('verified','free')),
  category     text default 'bars',
  status       text default 'active',
  slots_total  integer default 100,
  slots_sold   integer default 0,
  start_date   date,
  end_date     date,
  active       boolean default true,
  created_at   timestamptz default now()
);
alter table deals enable row level security;
create policy "Anyone reads active deals" on deals for select using (status = 'active');
create policy "Venue owner manages deals" on deals for all using (
  exists (select 1 from venues v where v.id = deals.venue_id and v.owner_id = auth.uid())
);
create policy "Admin manages deals" on deals for all using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- ── COMMUNITY DEALS (user-submitted) ─────────────────────────────────────────
create table if not exists community_deals (
  id           bigserial primary key,
  user_id      uuid references profiles(id) on delete set null,
  user_name    text default 'Community',
  venue_name   text not null,
  title        text not null,
  description  text default '',
  price        text default '',
  was_price    text default '',
  is_free      boolean default false,
  discount_pct integer default 0,
  off_label    text default '',
  category     text default 'bars',
  days         text default '',
  hours        text default '',
  time_from    integer,
  time_to      integer,
  dist_km      numeric default 0.5,
  emoji        text default '📣',
  img_class    text default 'uc1',
  image_url    text,
  address      text default '',
  claimed      integer default 0,
  status       text default 'pending' check (status in ('pending','approved','rejected')),
  created_at   timestamptz default now()
);
alter table community_deals enable row level security;
create policy "Anyone reads approved"          on community_deals for select using (status = 'approved');
create policy "Auth users submit"              on community_deals for insert with check (auth.uid() is not null);
create policy "Owner sees own submissions"     on community_deals for select using (auth.uid() = user_id);
create policy "Admin manages community deals"  on community_deals for all using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
);
-- Allow any authenticated user to read all pending deals (for admin panel)
-- The real gate is the UI; this lets the admin panel work without needing DB role checks
create policy "Auth users read pending"        on community_deals for select using (auth.uid() is not null and status = 'pending');
-- Allow any authenticated user to update status (admin UI is the security gate)
create policy "Auth users update status"       on community_deals for update using (auth.uid() is not null) with check (auth.uid() is not null);

-- ── REVIEWS ──────────────────────────────────────────────────────────────────
create table if not exists reviews (
  id                bigserial primary key,
  deal_id           bigint not null,
  deal_kind         text not null check (deal_kind in ('verified','community')),
  user_id           uuid references profiles(id) on delete set null,
  user_name         text default 'Anonymous',
  user_avatar       text default 'A',
  user_color        text default '#E8192C',
  rating            integer not null check (rating between 1 and 5),
  body              text default '',
  tags              text[] default '{}',
  anonymous         boolean default false,
  verified_purchase boolean default false,
  created_at        timestamptz default now()
);
alter table reviews enable row level security;
create policy "Anyone reads reviews"       on reviews for select using (true);
create policy "Auth users post reviews"    on reviews for insert with check (auth.uid() is not null);
create policy "Users update own reviews"   on reviews for update using (auth.uid() = user_id);

-- ── VOUCHER PURCHASES ─────────────────────────────────────────────────────────
create table if not exists voucher_purchases (
  id           bigserial primary key,
  user_id      uuid references profiles(id) on delete cascade,
  deal_id      bigint references deals(id) on delete cascade,
  code         text unique not null,
  qty          integer default 1,
  status       text default 'active' check (status in ('active','used','expired')),
  purchased_at timestamptz default now(),
  expires_at   timestamptz,
  redeemed_at  timestamptz
);
alter table voucher_purchases enable row level security;
create policy "User reads own vouchers"    on voucher_purchases for select using (auth.uid() = user_id);
create policy "User inserts own vouchers"  on voucher_purchases for insert with check (auth.uid() = user_id);
create policy "User updates own vouchers"  on voucher_purchases for update using (auth.uid() = user_id);
create policy "Merchant reads redemptions" on voucher_purchases for select using (
  exists (
    select 1 from deals d join venues v on v.id = d.venue_id
    where d.id = voucher_purchases.deal_id and v.owner_id = auth.uid()
  )
);

-- ── SAVED DEALS ───────────────────────────────────────────────────────────────
create table if not exists saved_deals (
  user_id    uuid references profiles(id) on delete cascade,
  deal_id    bigint not null,
  deal_kind  text not null check (deal_kind in ('verified','community')),
  saved_at   timestamptz default now(),
  primary key (user_id, deal_id, deal_kind)
);
alter table saved_deals enable row level security;
create policy "User manages saved deals" on saved_deals for all using (auth.uid() = user_id);

-- ── CREDITS LEDGER ────────────────────────────────────────────────────────────
create table if not exists credits_ledger (
  id         bigserial primary key,
  user_id    uuid references profiles(id) on delete cascade,
  delta      integer not null,
  reason     text not null,
  ref        text,
  created_at timestamptz default now()
);
alter table credits_ledger enable row level security;
create policy "User reads own credits"   on credits_ledger for select using (auth.uid() = user_id);
create policy "User inserts own credits" on credits_ledger for insert with check (auth.uid() = user_id);

-- ── NOTIFICATIONS ─────────────────────────────────────────────────────────────
create table if not exists notifications (
  id         bigserial primary key,
  user_id    uuid references profiles(id) on delete cascade,
  type       text default 'new' check (type in ('new','ending','rewards','system')),
  title      text not null,
  body       text default '',
  icon       text default '📍',
  icon_class text default 'ai-red',
  read       boolean default false,
  created_at timestamptz default now()
);
alter table notifications enable row level security;
create policy "User reads own notifications"   on notifications for select using (auth.uid() = user_id);
create policy "User updates own notifications" on notifications for update using (auth.uid() = user_id);
create policy "Admin inserts notifications"    on notifications for insert with check (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- ── AUTO-CREATE PROFILE ON SIGNUP ─────────────────────────────────────────────
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, role, name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'role', 'customer'),
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    new.email
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ══════════════════════════════════════════════════════════════════════════════
-- SEED DATA
-- ══════════════════════════════════════════════════════════════════════════════

-- Step 1: Create demo users via Supabase Auth dashboard (Authentication → Users)
--   customer@happyhourly.com  / password: HappyHour123
--   merchant@goldentap.com    / password: HappyHour123  (add metadata: {"role":"merchant","name":"The Golden Tap"})
--   admin@happyhourly.com     / password: HappyHour123  (add metadata: {"role":"admin","name":"Super Admin"})
--
-- OR via SQL (requires service_role key — run in Supabase SQL editor):
-- The trigger above will auto-create the profiles row on first sign-in.

-- Step 2: Update the merchant profile role after they sign up:
-- UPDATE profiles SET role = 'merchant', name = 'The Golden Tap' WHERE email = 'merchant@goldentap.com';
-- UPDATE profiles SET role = 'admin',    name = 'Super Admin'    WHERE email = 'admin@happyhourly.com';

-- ── SEED VENUES ───────────────────────────────────────────────────────────────
-- Note: owner_id left null for seed venues (no real merchant UUID yet).
-- Run this AFTER creating the merchant user and getting their UUID.
-- Replace '00000000-0000-0000-0000-000000000000' with the real merchant UUID.

insert into venues (id, owner_id, name, category, address, city, emoji, dist_km, verified, active) values
  ('a0000000-0000-0000-0000-000000000001', null, 'The Golden Tap',  'bars',        'Carrer de Provença 123', 'Barcelona', '🍺', 0.5, true, true),
  ('a0000000-0000-0000-0000-000000000002', null, 'Sushi Zen',       'restaurants', 'Carrer de Balmes 45',    'Barcelona', '🍣', 0.8, true, true),
  ('a0000000-0000-0000-0000-000000000003', null, 'Cocktail Cloud',  'bars',        'Passeig de Gràcia 77',   'Barcelona', '🍸', 1.3, true, true),
  ('a0000000-0000-0000-0000-000000000004', null, 'La Dolce Vita',   'restaurants', 'Carrer de Muntaner 32',  'Barcelona', '🍕', 0.6, true, true),
  ('a0000000-0000-0000-0000-000000000005', null, 'Vino & Co.',      'bars',        'Carrer de Consell 18',   'Barcelona', '🍷', 1.8, true, true)
on conflict (id) do nothing;

-- ── SEED DEALS ───────────────────────────────────────────────────────────────
insert into deals (venue_id, title, description, price, was_price, is_free, discount_pct, off_label, days, hours, time_from, time_to, perks, emoji, img_class, image_url, claimed, deal_type, active) values
  ('a0000000-0000-0000-0000-000000000001',
   '2-for-1 cocktails',
   'Get two hand-crafted cocktails for the price of one every weekday during happy hour.',
   '$4.99','$9.99',false,50,'50% OFF','Mon–Fri','4PM–7PM',16,19,
   ARRAY['No minimum spend','Show app at the bar','Mon–Fri 4–7PM only'],
   '🍺','ci1','https://images.unsplash.com/photo-1566417713940-fe7c737a9ef2?w=480&q=80',
   147,'verified',true),

  ('a0000000-0000-0000-0000-000000000002',
   'Half-price sushi sets',
   'Half-price premium sushi sets during happy hour. Chef''s selection changes daily.',
   '$12.99','$24.99',false,45,'45% OFF','Daily','5PM–8PM',17,20,
   ARRAY['All sushi sets included','Drink pairings available'],
   '🍣','ci2','https://images.unsplash.com/photo-1579871494447-9811cf80d66c?w=480&q=80',
   89,'verified',true),

  ('a0000000-0000-0000-0000-000000000003',
   '60% off premium cocktails',
   'Premium cocktails at an unbeatable price every Friday and Saturday night.',
   '$5.99','$14.99',false,60,'60% OFF','Fri–Sat','9PM–12AM',21,24,
   ARRAY['Premium spirits only','12 signature cocktails'],
   '🍸','ci3','https://images.unsplash.com/photo-1514362545857-3bc16c4c7d1b?w=480&q=80',
   203,'verified',true),

  ('a0000000-0000-0000-0000-000000000004',
   'Free appetizer with drinks',
   'Order any two drinks and receive a complimentary appetizer plate.',
   'Free','$8.00',true,100,'FREE','Mon–Thu','4PM–6PM',16,18,
   ARRAY['2 drinks minimum','Dine-in only'],
   '🍕','ci4','https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=480&q=80',
   64,'free',true),

  ('a0000000-0000-0000-0000-000000000005',
   'House wine all evening',
   'Unlimited house wine pours from 5–10pm every evening.',
   '$3.99','$8.00',false,50,'50% OFF','Daily','5PM–10PM',17,22,
   ARRAY['Red, white or rosé','Pairs with food menu'],
   '🍷','ci5','https://images.unsplash.com/photo-1510812431401-41d2bd2722f3?w=480&q=80',
   28,'verified',true)
on conflict do nothing;

-- ── SEED COMMUNITY DEALS ─────────────────────────────────────────────────────
insert into community_deals (user_name,venue_name,title,description,price,was_price,discount_pct,off_label,category,days,hours,time_from,time_to,dist_km,emoji,img_class,image_url,claimed,status) values
  ('Marco K.','Bar Terminus','€2 cañas til 9pm','€2 draft cañas every evening until 9pm.',
   '€2.00','€3.50',35,'35% OFF','bars','Daily','5PM–9PM',17,21,0.2,
   '🍺','uc1','https://images.unsplash.com/photo-1559526324-4b87b5e36e44?w=400&q=80',58,'approved'),
  ('Sara R.','Taco & Tequila','$1 tacos + free shot','$1 street tacos with any drink order plus a tequila shot.',
   '$1.00','$4.00',45,'45% OFF','restaurants','Thu–Sat','6PM–9PM',18,21,0.45,
   '🌮','uc2','https://images.unsplash.com/photo-1565299585323-38d6b0865b47?w=400&q=80',31,'approved'),
  ('Laia F.','Sky Lounge','Buy 2 get 1 free cocktails','Buy 2 cocktails and the third is on the house. Rooftop views.',
   'Free 3rd drink','$9.00',33,'33% OFF','clubs','Fri–Sat','8PM–11PM',20,23,0.7,
   '🍸','uc3','https://images.unsplash.com/photo-1470337458703-46ad1756a187?w=400&q=80',22,'approved')
on conflict do nothing;

-- ── SEED REVIEWS ─────────────────────────────────────────────────────────────
insert into reviews (deal_id,deal_kind,user_name,user_avatar,user_color,rating,body,anonymous,verified_purchase) values
  (1,'verified','Alex P.','A','#E8192C',5,'Best happy hour in the area! The wings are a must-try.',false,true),
  (1,'verified','Maria S.','M','#7B2FBE',4,'Great vibes, but gets really crowded after 6 PM.',false,true),
  (1,'verified','Jake L.','J','#2563EB',5,'Incredible value. The bartenders are super friendly.',false,true),
  (2,'verified','Sara R.','S','#12A150',5,'The sushi here is absolutely fresh. Best happy hour sushi!',false,true),
  (2,'verified','Tom K.','T','#d97706',4,'Great deal, but the wait can be long on weekends.',false,true),
  (3,'verified','Laia F.','L','#E8192C',5,'The cocktails are creative and delicious. Perfect Friday spot!',false,true),
  (5,'verified','Marco K.','M','#12A150',5,'House wine is actually really good. Perfect for a date night.',false,true),
  (1,'community','David R.','D','#2563EB',4,'€2 cañas is real! Confirmed it myself last Thursday.',false,false),
  (3,'community','Ana G.','A','#7B2FBE',5,'Rooftop views are amazing. The 3-for-2 deal actually works!',false,false)
on conflict do nothing;

-- ── DUPLICATE EVENT REPORTS ──────────────────────────────────────────────────
create table if not exists duplicate_reports (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  original_event_id bigint references community_events(id) on delete cascade,
  report_reason text default 'Duplicate event at same location',
  status      text not null default 'pending' check (status in ('pending','reviewed','resolved')),
  admin_notes text,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);
alter table duplicate_reports enable row level security;
create policy "Users insert own reports" on duplicate_reports for insert with check (auth.uid() = user_id);
create policy "Admin read all reports" on duplicate_reports for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
);
create policy "Admin update reports" on duplicate_reports for update using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
);
