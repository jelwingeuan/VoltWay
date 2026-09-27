alter table public.charger_catalog drop constraint if exists charger_catalog_source_check;
alter table public.charger_catalog add constraint charger_catalog_source_check
  check (source in ('open_charge_map', 'mevnet'));
