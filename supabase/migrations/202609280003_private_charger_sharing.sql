create table public.private_charger_sites (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  station jsonb not null check (
    jsonb_typeof(station) = 'object'
    and jsonb_typeof(station->'coordinate') = 'object'
    and jsonb_typeof(station->'connectors') = 'array'
    and nullif(trim(station->>'name'), '') is not null
  ),
  owner_permission_granted_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (id, owner_id)
);

create table public.private_charger_site_invites (
  site_id uuid not null,
  owner_id uuid not null,
  invited_email text not null check (invited_email = lower(trim(invited_email)) and invited_email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  invited_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (site_id, invited_email),
  foreign key (site_id, owner_id) references public.private_charger_sites(id, owner_id) on delete cascade
);

alter table public.private_charger_sites enable row level security;
alter table public.private_charger_site_invites enable row level security;

grant select, delete on public.private_charger_sites to authenticated;
grant select, delete on public.private_charger_site_invites to authenticated;

create policy "owners and invited users read private sites" on public.private_charger_sites
for select to authenticated using (
  owner_id = (select auth.uid())
  or exists (
    select 1 from public.private_charger_site_invites invite
    where invite.site_id = private_charger_sites.id
      and invite.invited_email = lower(coalesce((select auth.jwt())->>'email', ''))
  )
);

create policy "owners delete private sites" on public.private_charger_sites
for delete to authenticated using (owner_id = (select auth.uid()));

create policy "owners and invitees read private site invitations" on public.private_charger_site_invites
for select to authenticated using (
  invited_by = (select auth.uid())
  or invited_email = lower(coalesce((select auth.jwt())->>'email', ''))
);

create policy "owners revoke private site invitations" on public.private_charger_site_invites
for delete to authenticated using (
  invited_by = (select auth.uid()) and owner_id = (select auth.uid())
);

create function public.create_private_charger_site(
  p_id uuid,
  p_station jsonb,
  p_owner_consent boolean,
  p_invited_email text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  authenticated_user uuid := auth.uid();
  normalized_email text := lower(trim(coalesce(p_invited_email, '')));
begin
  if authenticated_user is null then
    raise exception 'Authentication required';
  end if;
  if p_owner_consent is distinct from true then
    raise exception 'Owner permission is required';
  end if;
  if normalized_email <> '' and normalized_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Invitation email is invalid';
  end if;

  insert into public.private_charger_sites (id, owner_id, station, owner_permission_granted_at)
  values (
    p_id,
    authenticated_user,
    p_station || jsonb_build_object(
      'id', 'private:' || p_id::text,
      'source', 'ownerProvided',
      'sourceAttribution', 'Owner supplied · shared by invitation',
      'access', 'private',
      'availability', jsonb_build_object('state', 'unknown', 'availableConnectors', null, 'totalConnectors', null, 'lastUpdated', null),
      'price', null
    ),
    now()
  );

  if normalized_email <> '' then
    insert into public.private_charger_site_invites (site_id, owner_id, invited_email, invited_by)
    values (p_id, authenticated_user, normalized_email, authenticated_user);
  end if;
  return p_id;
end;
$$;

revoke all on function public.create_private_charger_site(uuid, jsonb, boolean, text) from public;
grant execute on function public.create_private_charger_site(uuid, jsonb, boolean, text) to authenticated;
