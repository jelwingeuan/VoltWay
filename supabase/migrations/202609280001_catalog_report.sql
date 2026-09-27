alter table public.charger_catalog
  add column import_report jsonb not null default '{}'::jsonb;
