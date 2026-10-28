-- Keep direct RPC callers from storing sites that the stations normalizer cannot show.
-- Historical rows and table/RLS constraints are intentionally unchanged.
create or replace function public.create_private_charger_site(
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
  normalized_email text := lower(btrim(coalesce(p_invited_email, '')));
  site_name text;
  site_address text;
  operator_name text;
  coordinates jsonb;
  latitude numeric;
  longitude numeric;
  supplied_connectors jsonb;
  connector jsonb;
  connector_kind text;
  connector_power numeric;
  connector_count numeric;
  normalized_connector jsonb;
  normalized_connectors jsonb := '[]'::jsonb;
  charge_point_count numeric;
  normalized_station jsonb;
begin
  if authenticated_user is null then
    raise exception 'Authentication required';
  end if;
  if p_owner_consent is distinct from true then
    raise exception 'Owner permission is required';
  end if;
  if char_length(normalized_email) > 254
     or (normalized_email <> '' and normalized_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception 'Invitation email is invalid' using errcode = '22023';
  end if;

  if p_id is null or jsonb_typeof(p_station) is distinct from 'object'
     or jsonb_typeof(p_station->'name') is distinct from 'string'
     or jsonb_typeof(p_station->'address') is distinct from 'string'
     or jsonb_typeof(p_station->'operatorName') is distinct from 'string' then
    raise exception 'Private charger details are invalid' using errcode = '22023';
  end if;
  site_name := btrim(p_station->>'name', E' \t\n\r\f\v');
  site_address := btrim(p_station->>'address', E' \t\n\r\f\v');
  operator_name := btrim(p_station->>'operatorName', E' \t\n\r\f\v');
  if char_length(site_name) not between 1 and 100
     or char_length(site_address) not between 1 and 240
     or char_length(operator_name) not between 1 and 100 then
    raise exception 'Private charger details are invalid' using errcode = '22023';
  end if;

  coordinates := p_station->'coordinate';
  if jsonb_typeof(coordinates) is distinct from 'object'
     or jsonb_typeof(coordinates->'latitude') is distinct from 'number'
     or jsonb_typeof(coordinates->'longitude') is distinct from 'number' then
    raise exception 'Private charger details are invalid' using errcode = '22023';
  end if;
  latitude := (coordinates->>'latitude')::numeric;
  longitude := (coordinates->>'longitude')::numeric;
  if latitude < 0.8 or latitude > 7.5 or longitude < 99 or longitude > 120.5 then
    raise exception 'Private charger details are invalid' using errcode = '22023';
  end if;

  supplied_connectors := p_station->'connectors';
  if jsonb_typeof(supplied_connectors) is distinct from 'array' then
    raise exception 'Private charger details are invalid' using errcode = '22023';
  end if;
  if jsonb_array_length(supplied_connectors) not between 1 and 20 then
    raise exception 'Private charger details are invalid' using errcode = '22023';
  end if;
  for connector in select value from jsonb_array_elements(supplied_connectors) as entries(value) loop
    if jsonb_typeof(connector) is distinct from 'object'
       or jsonb_typeof(connector->'kind') is distinct from 'string' then
      raise exception 'Private charger details are invalid' using errcode = '22023';
    end if;
    connector_kind := connector->>'kind';
    if connector_kind not in ('type2', 'ccs2', 'chademo') then
      raise exception 'Private charger details are invalid' using errcode = '22023';
    end if;
    normalized_connector := jsonb_build_object('kind', connector_kind);
    if connector ? 'powerKW' then
      if jsonb_typeof(connector->'powerKW') is distinct from 'number' then
        raise exception 'Private charger details are invalid' using errcode = '22023';
      end if;
      connector_power := (connector->>'powerKW')::numeric;
      if connector_power <= 0 or connector_power > 1000 then
        raise exception 'Private charger details are invalid' using errcode = '22023';
      end if;
      normalized_connector := normalized_connector || jsonb_build_object('powerKW', connector_power);
    end if;
    if connector ? 'count' then
      if jsonb_typeof(connector->'count') is distinct from 'number' then
        raise exception 'Private charger details are invalid' using errcode = '22023';
      end if;
      connector_count := (connector->>'count')::numeric;
      if connector_count < 1 or connector_count > 1000 or connector_count <> trunc(connector_count) then
        raise exception 'Private charger details are invalid' using errcode = '22023';
      end if;
      normalized_connector := normalized_connector || jsonb_build_object('count', connector_count::integer);
    end if;
    normalized_connectors := normalized_connectors || jsonb_build_array(normalized_connector);
  end loop;

  if p_station ? 'chargePointCount' then
    if jsonb_typeof(p_station->'chargePointCount') is distinct from 'number' then
      raise exception 'Private charger details are invalid' using errcode = '22023';
    end if;
    charge_point_count := (p_station->>'chargePointCount')::numeric;
    if charge_point_count < 1 or charge_point_count > 1000 or charge_point_count <> trunc(charge_point_count) then
      raise exception 'Private charger details are invalid' using errcode = '22023';
    end if;
  end if;

  normalized_station := jsonb_build_object(
    'id', 'private:' || p_id::text,
    'name', site_name,
    'address', site_address,
    'operatorName', operator_name,
    'coordinate', jsonb_build_object('latitude', latitude, 'longitude', longitude),
    'connectors', normalized_connectors,
    'source', 'ownerProvided',
    'sourceAttribution', 'Owner supplied · shared by invitation',
    'access', 'private',
    'availability', jsonb_build_object(
      'state', 'unknown',
      'availableConnectors', null,
      'totalConnectors', null,
      'lastUpdated', null
    ),
    'price', null
  );
  if charge_point_count is not null then
    normalized_station := normalized_station || jsonb_build_object('chargePointCount', charge_point_count::integer);
  end if;

  insert into public.private_charger_sites (id, owner_id, station, owner_permission_granted_at)
  values (p_id, authenticated_user, normalized_station, now());

  if normalized_email <> '' then
    insert into public.private_charger_site_invites (site_id, owner_id, invited_email, invited_by)
    values (p_id, authenticated_user, normalized_email, authenticated_user);
  end if;
  return p_id;
end;
$$;

revoke all on function public.create_private_charger_site(uuid, jsonb, boolean, text) from public;
grant execute on function public.create_private_charger_site(uuid, jsonb, boolean, text) to authenticated;
