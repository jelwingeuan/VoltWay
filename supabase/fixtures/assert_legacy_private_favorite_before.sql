-- Fail if the disposable pre-migration fixture did not actually seed legacy
-- private coordinates. This guards against a false green backfill test.
do $$
begin
  if (
    select count(*)
    from public.favorite_stations
    where user_id = '66666666-6666-4666-8666-666666666666'
      and station_snapshot->'coordinate' is not null
      and (
        station_id = 'private:77777777-7777-4777-8777-777777777777'
        or station_id = 'synthetic-owner-source'
      )
  ) <> 2 then
    raise exception 'Legacy private-coordinate fixture was not seeded';
  end if;

  if (
    select count(*)
    from public.favorite_stations
    where user_id = '66666666-6666-4666-8666-666666666666'
  ) <> 3 then
    raise exception 'Legacy favorite fixture row count is wrong';
  end if;
end;
$$;
