-- Synthetic pre-migration rows for exercising the snapshot backfill locally.
-- Run only against a disposable local database stopped at migration 202609280004.
insert into auth.users (id, email, aud, role, encrypted_password, email_confirmed_at)
values ('66666666-6666-4666-8666-666666666666', 'legacy-test@example.invalid', 'authenticated', 'authenticated', '!', now());

insert into public.favorite_stations (user_id, station_id, station_snapshot)
values
  (
    '66666666-6666-4666-8666-666666666666',
    'private:77777777-7777-4777-8777-777777777777',
    '{"source":"ownerProvided","coordinate":{"latitude":0,"longitude":0}}'::jsonb
  ),
  (
    '66666666-6666-4666-8666-666666666666',
    'synthetic-owner-source',
    '{"source":"ownerProvided","coordinate":{"latitude":0,"longitude":0}}'::jsonb
  ),
  (
    '66666666-6666-4666-8666-666666666666',
    'ocm:public-control',
    '{"source":"openChargeMap","coordinate":{"latitude":1,"longitude":1}}'::jsonb
  );
