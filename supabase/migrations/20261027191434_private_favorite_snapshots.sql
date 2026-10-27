-- Private bookmarks remain ID-only. Their full station data is obtained from the
-- current, invitation-filtered private charger catalog, never from favorites.
alter table public.favorite_stations
  alter column station_snapshot drop not null;

-- Remove coordinates retained by previous app versions before enforcing the
-- invariant. Public/partner favorite snapshots are intentionally untouched.
update public.favorite_stations
set station_snapshot = null
where station_snapshot is not null
  and (
    station_id like 'private:%'
    or station_snapshot->>'source' = 'ownerProvided'
  );

alter table public.favorite_stations
  add constraint private_favorite_snapshots_are_null
  check (
    station_snapshot is null
    or (
      station_id not like 'private:%'
      and coalesce(station_snapshot->>'source', '') <> 'ownerProvided'
    )
  );

-- Explicitly expose this RLS-protected table to signed-in Data API clients on
-- projects created without Supabase's former automatic public-table grants.
grant select, insert, update, delete on public.favorite_stations to authenticated;
