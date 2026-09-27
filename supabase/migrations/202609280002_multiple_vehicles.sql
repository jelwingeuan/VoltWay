alter table public.vehicle_profiles
  add column id uuid not null default gen_random_uuid(),
  add column name text not null default 'My EV' check (char_length(trim(name)) between 1 and 60);

alter table public.vehicle_profiles drop constraint vehicle_profiles_pkey;
alter table public.vehicle_profiles add primary key (id);
create index vehicle_profiles_user_id_idx on public.vehicle_profiles (user_id);

create table public.user_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  active_vehicle_id uuid references public.vehicle_profiles(id) on delete set null
);

alter table public.user_preferences enable row level security;

create policy "read own preferences" on public.user_preferences for select to authenticated
using ((select auth.uid()) = user_id);

create policy "insert own preferences" on public.user_preferences for insert to authenticated
with check ((select auth.uid()) = user_id and (active_vehicle_id is null or exists (
  select 1 from public.vehicle_profiles where id = active_vehicle_id and vehicle_profiles.user_id = (select auth.uid())
)));

create policy "update own preferences" on public.user_preferences for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id and (active_vehicle_id is null or exists (
  select 1 from public.vehicle_profiles where id = active_vehicle_id and vehicle_profiles.user_id = (select auth.uid())
)));

insert into public.user_preferences (user_id, active_vehicle_id)
select user_id, id from public.vehicle_profiles;
