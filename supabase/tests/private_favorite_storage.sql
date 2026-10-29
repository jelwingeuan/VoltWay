begin;

-- These accounts and coordinates are synthetic. The transaction is rolled back by pgTAP.
select plan(50);

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

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","email":"private-owner@example.invalid","role":"authenticated"}', true);
select set_config(
  'voltway.test_private_station',
  '{"name":"Owner charger","address":"1 Test Road","operatorName":"Private owner","coordinate":{"latitude":3.139,"longitude":101.6869},"connectors":[{"kind":"ccs2","powerKW":50,"count":2}],"chargePointCount":2,"id":"spoofed","source":"gentari","sourceAttribution":"spoofed","access":"public","availability":{"state":"available"},"price":{"amount":1},"unexpected":"discard me"}',
  true
);

select throws_ok(
  $$select public.create_private_charger_site(null::uuid, current_setting('voltway.test_private_station')::jsonb, true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects a missing site ID'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), '[]'::jsonb, true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects a non-object station'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), current_setting('voltway.test_private_station')::jsonb - 'coordinate', true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects missing coordinates'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{coordinate,latitude}', '8'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects latitude outside Malaysia'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{coordinate,longitude}', '121'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects longitude outside Malaysia'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{coordinate,latitude}', '"3.139"'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects string latitude'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{coordinate,longitude}', '"101.6869"'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects string longitude'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{name}', '"   "'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects a blank name'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{name}', to_jsonb(repeat('N', 101))), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects a name over 100 characters'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{address}', '"  "'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects a blank address'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{address}', to_jsonb(repeat('A', 241))), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects an address over 240 characters'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{operatorName}', '""'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects a blank operator'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{operatorName}', to_jsonb(repeat('O', 101))), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects an operator over 100 characters'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{connectors}', '[]'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects an empty connector list'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{connectors,0,kind}', '"nacs"'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects an unsupported connector'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{connectors}', (select jsonb_agg(jsonb_build_object('kind', 'ccs2')) from generate_series(1, 21))), true)$$,
  '22023', 'Private charger details are invalid', 'RPC caps connector objects at 20'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{connectors,0,powerKW}', '0'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects zero connector power'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{connectors,0,powerKW}', '1001'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects excessive connector power'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{connectors,0,powerKW}', '"fast"'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects nonnumeric connector power'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{connectors,0,count}', '0'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects zero connector count'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{connectors,0,count}', '1.5'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects fractional connector count'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{connectors,0,count}', '1001'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects excessive connector count'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{chargePointCount}', '0'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects zero charge-point count'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{chargePointCount}', '1.5'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects fractional charge-point count'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), jsonb_set(current_setting('voltway.test_private_station')::jsonb, '{chargePointCount}', '"two"'::jsonb), true)$$,
  '22023', 'Private charger details are invalid', 'RPC rejects string charge-point count'
);
select throws_ok(
  $$select public.create_private_charger_site(gen_random_uuid(), current_setting('voltway.test_private_station')::jsonb, true, repeat('a', 255) || '@example.invalid')$$,
  '22023', 'Invitation email is invalid', 'RPC caps invitation email length at 254'
);
select ok(
  (select count(*) = 0 from public.private_charger_sites
   where owner_id = auth.uid() and id <> '44444444-4444-4444-8444-444444444444'),
  'invalid RPC submissions created no private sites'
);
select ok(
  (select count(*) = 0 from public.private_charger_site_invites
   where owner_id = auth.uid()),
  'invalid RPC submissions created no invitations'
);

select is(
  public.create_private_charger_site(
    '66666666-6666-4666-8666-666666666666',
    current_setting('voltway.test_private_station')::jsonb,
    true,
    ' INVITED@EXAMPLE.INVALID '
  ),
  '66666666-6666-4666-8666-666666666666'::uuid,
  'valid owner submission returns its UUID'
);
select ok(
  (select count(*) = 1 from public.private_charger_sites
   where id = '66666666-6666-4666-8666-666666666666'),
  'owner sees the saved site'
);
select is(
  (select station from public.private_charger_sites where id = '66666666-6666-4666-8666-666666666666'),
  '{"id":"private:66666666-6666-4666-8666-666666666666","name":"Owner charger","address":"1 Test Road","operatorName":"Private owner","coordinate":{"latitude":3.139,"longitude":101.6869},"connectors":[{"kind":"ccs2","powerKW":50,"count":2}],"chargePointCount":2,"source":"ownerProvided","sourceAttribution":"Owner supplied · shared by invitation","access":"private","availability":{"state":"unknown","availableConnectors":null,"totalConnectors":null,"lastUpdated":null},"price":null}'::jsonb,
  'RPC stores only canonical site fields and server-controlled facts'
);
select is(
  (select invited_email from public.private_charger_site_invites where site_id = '66666666-6666-4666-8666-666666666666'),
  'invited@example.invalid',
  'valid invitation is normalized and retained'
);

reset role;
select ok(
  not has_schema_privilege('anon', 'voltway_private', 'USAGE'),
  'anonymous callers cannot use the internal invitation schema'
);
select ok(
  not has_function_privilege('anon', 'voltway_private.current_confirmed_email()', 'EXECUTE'),
  'anonymous callers cannot execute the account-email lookup'
);

-- Simulate an email change after the token was issued. The old invitation is
-- still present, but access must follow auth.users rather than the stale JWT.
insert into public.private_charger_site_invites (site_id, owner_id, invited_email, invited_by)
values (
  '44444444-4444-4444-8444-444444444444',
  '11111111-1111-4111-8111-111111111111',
  'former-invitee@example.invalid',
  '11111111-1111-4111-8111-111111111111'
);
update auth.users set email = 'invited@example.invalid'
where id = '22222222-2222-4222-8222-222222222222';

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
select set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","email":"former-invitee@example.invalid","role":"authenticated"}', true);

select is(
  (select count(*)::integer from public.private_charger_sites where id = '44444444-4444-4444-8444-444444444444'),
  0,
  'a stale JWT email cannot read a site after the account email changes'
);
select is(
  (select count(*)::integer from public.private_charger_site_invites where site_id = '44444444-4444-4444-8444-444444444444'),
  0,
  'a stale JWT email cannot read the old invitation'
);
select is(
  (select count(*)::integer from public.private_charger_sites where id = '66666666-6666-4666-8666-666666666666'),
  1,
  'a confirmed current email can read its site before JWT refresh'
);
select is(
  (select count(*)::integer from public.private_charger_site_invites where site_id = '66666666-6666-4666-8666-666666666666'),
  1,
  'a confirmed current email can read its invitation before JWT refresh'
);

reset role;
update auth.users set email_confirmed_at = null
where id = '22222222-2222-4222-8222-222222222222';
set local role authenticated;
select is(
  (select count(*)::integer from public.private_charger_sites where id = '66666666-6666-4666-8666-666666666666'),
  0,
  'an unconfirmed current email cannot read its invited site'
);
select is(
  (select count(*)::integer from public.private_charger_site_invites where site_id = '66666666-6666-4666-8666-666666666666'),
  0,
  'an unconfirmed current email cannot read its invitation'
);

select * from finish();
rollback;
