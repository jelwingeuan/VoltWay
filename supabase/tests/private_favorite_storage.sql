begin;

-- These accounts and coordinates are synthetic. The transaction is rolled back by pgTAP.
select plan(10);

insert into auth.users (id, email, aud, role, encrypted_password, email_confirmed_at)
values
  ('11111111-1111-4111-8111-111111111111', 'private-owner@example.invalid', 'authenticated', 'authenticated', '!', now()),
  ('22222222-2222-4222-8222-222222222222', 'former-invitee@example.invalid', 'authenticated', 'authenticated', '!', now()),
  ('33333333-3333-4333-8333-333333333333', 'other-user@example.invalid', 'authenticated', 'authenticated', '!', now());

insert into public.private_charger_sites (id, owner_id, station, owner_permission_granted_at)
values (
  '44444444-4444-4444-8444-444444444444',
  '11111111-1111-4111-8111-111111111111',
  '{"name":"Synthetic private charger","coordinate":{"latitude":0,"longitude":0},"connectors":[]}'::jsonb,
  now()
);

insert into public.private_charger_site_invites (site_id, owner_id, invited_email, invited_by)
values (
  '44444444-4444-4444-8444-444444444444',
  '11111111-1111-4111-8111-111111111111',
  'former-invitee@example.invalid',
  '11111111-1111-4111-8111-111111111111'
);

insert into public.favorite_stations (user_id, station_id, station_snapshot)
values
  ('22222222-2222-4222-8222-222222222222', 'private:44444444-4444-4444-8444-444444444444', null),
  ('22222222-2222-4222-8222-222222222222', 'ocm:public-control', '{"source":"openChargeMap","coordinate":{"latitude":1,"longitude":1}}'::jsonb);

select ok(
  (select is_nullable = 'YES' from information_schema.columns
   where table_schema = 'public' and table_name = 'favorite_stations' and column_name = 'station_snapshot'),
  'private favorites can be stored without a snapshot'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
select set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","email":"former-invitee@example.invalid","role":"authenticated"}', true);

select ok(
  (select count(*) = 1 from public.private_charger_sites where id = '44444444-4444-4444-8444-444444444444'),
  'invited user sees the private site before revocation'
);
select ok(
  (select station_snapshot is null from public.favorite_stations
   where station_id = 'private:44444444-4444-4444-8444-444444444444'),
  'invited user can bookmark only the private site ID'
);
select throws_ok(
  $$insert into public.favorite_stations (user_id, station_id, station_snapshot)
    values ('22222222-2222-4222-8222-222222222222', 'private:55555555-5555-4555-8555-555555555555', '{"source":"ownerProvided","coordinate":{"latitude":0,"longitude":0}}'::jsonb)$$,
  '23514', null, 'authenticated insert cannot retain a private snapshot'
);
select throws_ok(
  $$insert into public.favorite_stations (user_id, station_id, station_snapshot)
    values ('22222222-2222-4222-8222-222222222222', 'private:44444444-4444-4444-8444-444444444444', '{"source":"ownerProvided"}'::jsonb)
    on conflict (user_id, station_id) do update set station_snapshot = excluded.station_snapshot$$,
  '23514', null, 'authenticated upsert cannot restore a private snapshot'
);
select throws_ok(
  $$insert into public.favorite_stations (user_id, station_id, station_snapshot)
    values ('22222222-2222-4222-8222-222222222222', 'synthetic-alias', '{"source":"ownerProvided"}'::jsonb)$$,
  '23514', null, 'owner-provided source cannot be saved under a public-looking ID'
);

reset role;
delete from public.private_charger_site_invites
where site_id = '44444444-4444-4444-8444-444444444444'
  and invited_email = 'former-invitee@example.invalid';

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
select set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","email":"former-invitee@example.invalid","role":"authenticated"}', true);

select ok(
  (select count(*) = 0 from public.private_charger_sites where id = '44444444-4444-4444-8444-444444444444'),
  'revoked user no longer sees the private site'
);
select ok(
  (select count(*) = 1 and bool_and(station_snapshot is null)
   from public.favorite_stations where station_id = 'private:44444444-4444-4444-8444-444444444444'),
  'revoked user can read only an ID-only bookmark'
);
select ok(
  (select station_snapshot = '{"source":"openChargeMap","coordinate":{"latitude":1,"longitude":1}}'::jsonb
   from public.favorite_stations where station_id = 'ocm:public-control'),
  'public favorite snapshots are unchanged'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333333', true);
select set_config('request.jwt.claims', '{"sub":"33333333-3333-4333-8333-333333333333","email":"other-user@example.invalid","role":"authenticated"}', true);
select ok(
  (select count(*) = 0 from public.favorite_stations
   where station_id = 'private:44444444-4444-4444-8444-444444444444'),
  'a different account cannot read the private bookmark'
);

select * from finish();
rollback;
