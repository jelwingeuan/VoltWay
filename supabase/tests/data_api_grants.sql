begin;

select plan(4);

select ok(
  (select count(*) = 6 and bool_and(c.relrowsecurity)
   from pg_class c
   where c.oid in (
     'public.vehicle_profiles'::regclass,
     'public.favorite_stations'::regclass,
     'public.user_preferences'::regclass,
     'public.private_charger_sites'::regclass,
     'public.private_charger_site_invites'::regclass,
     'public.charger_catalog'::regclass
   )),
  'all six public tables have row-level security enabled'
);

select ok(
  (select bool_and(not has_table_privilege('anon', t.table_name, p.privilege))
   from (values
     ('public.vehicle_profiles'), ('public.favorite_stations'),
     ('public.user_preferences'), ('public.private_charger_sites'),
     ('public.private_charger_site_invites'), ('public.charger_catalog')
   ) as t(table_name)
   cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)),
  'anonymous callers have no direct Data API table privileges'
);

select ok(
  (select bool_and(
    has_table_privilege('authenticated', e.table_name, 'SELECT') = e.can_select and
    has_table_privilege('authenticated', e.table_name, 'INSERT') = e.can_insert and
    has_table_privilege('authenticated', e.table_name, 'UPDATE') = e.can_update and
    has_table_privilege('authenticated', e.table_name, 'DELETE') = e.can_delete
   ) from (values
     ('public.vehicle_profiles', true, true, true, true),
     ('public.favorite_stations', true, true, true, true),
     ('public.user_preferences', true, true, true, false),
     ('public.private_charger_sites', true, false, false, true),
     ('public.private_charger_site_invites', true, false, false, true),
     ('public.charger_catalog', false, false, false, false)
   ) as e(table_name, can_select, can_insert, can_update, can_delete)),
  'signed-in callers have only the app operations protected by RLS'
);

select ok(
  has_table_privilege('service_role', 'public.charger_catalog', 'SELECT') and
  has_table_privilege('service_role', 'public.charger_catalog', 'INSERT') and
  has_table_privilege('service_role', 'public.charger_catalog', 'UPDATE') and
  not has_table_privilege('service_role', 'public.charger_catalog', 'DELETE'),
  'server-side catalog sync can read and upsert without delete access'
);

select * from finish();
rollback;
