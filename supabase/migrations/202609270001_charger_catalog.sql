create table public.charger_catalog (
  source text primary key check (source = 'open_charge_map'),
  stations jsonb not null check (jsonb_typeof(stations) = 'array'),
  synced_at timestamptz not null
);

alter table public.charger_catalog enable row level security;
-- No anon/authenticated policies: only the service role used by Edge Functions can read or replace this snapshot.
