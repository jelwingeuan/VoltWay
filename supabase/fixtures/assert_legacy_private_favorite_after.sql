-- The real migration must redact both canonical and aliased private rows,
-- preserve the public row, and install the constraint for future writes.
do $$
begin
  if (
    select count(*)
    from public.favorite_stations
    where user_id = '66666666-6666-4666-8666-666666666666'
      and station_snapshot is null
      and station_id in (
        'private:77777777-7777-4777-8777-777777777777',
        'synthetic-owner-source'
      )
  ) <> 2 then
    raise exception 'Private favorite snapshots survived the backfill';
  end if;

  if (
    select station_snapshot
    from public.favorite_stations
    where user_id = '66666666-6666-4666-8666-666666666666'
      and station_id = 'ocm:public-control'
  ) is distinct from '{"source":"openChargeMap","coordinate":{"latitude":1,"longitude":1}}'::jsonb then
    raise exception 'Public favorite snapshot changed during backfill';
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.favorite_stations'::regclass
      and conname = 'private_favorite_snapshots_are_null'
      and contype = 'c'
  ) then
    raise exception 'Private favorite snapshot constraint is missing';
  end if;
end;
$$;
