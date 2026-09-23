create table public.vehicle_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  connectors text[] not null check (cardinality(connectors) > 0),
  minimum_power_kw numeric check (minimum_power_kw is null or minimum_power_kw > 0),
  updated_at timestamptz not null default now()
);

create table public.favorite_stations (
  user_id uuid not null references auth.users(id) on delete cascade,
  station_id text not null,
  station_snapshot jsonb not null,
  created_at timestamptz not null default now(),
  primary key (user_id, station_id)
);

alter table public.vehicle_profiles enable row level security;
alter table public.favorite_stations enable row level security;

create policy "read own vehicle profile"
on public.vehicle_profiles for select to authenticated
using ((select auth.uid()) = user_id);

create policy "insert own vehicle profile"
on public.vehicle_profiles for insert to authenticated
with check ((select auth.uid()) = user_id);

create policy "update own vehicle profile"
on public.vehicle_profiles for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy "delete own vehicle profile"
on public.vehicle_profiles for delete to authenticated
using ((select auth.uid()) = user_id);

create policy "read own favorites"
on public.favorite_stations for select to authenticated
using ((select auth.uid()) = user_id);

create policy "insert own favorites"
on public.favorite_stations for insert to authenticated
with check ((select auth.uid()) = user_id);

create policy "update own favorites"
on public.favorite_stations for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy "delete own favorites"
on public.favorite_stations for delete to authenticated
using ((select auth.uid()) = user_id);
