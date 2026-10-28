-- Supabase no longer grants Data API privileges to new public tables by default.
-- Reset older projects' automatic client grants to this app's explicit API surface.
revoke all on table
  public.vehicle_profiles,
  public.favorite_stations,
  public.user_preferences,
  public.private_charger_sites,
  public.private_charger_site_invites,
  public.charger_catalog
from anon, authenticated;

-- The signed-in app stores vehicles, active selection, and favorites.
-- Row-level policies on each table still restrict rows to their owners.
grant select, insert, update, delete on table public.vehicle_profiles to authenticated;
grant select, insert, update, delete on table public.favorite_stations to authenticated;
grant select, insert, update on table public.user_preferences to authenticated;

-- Owners and invitees can read shared sites; owners can revoke sites and invites.
-- Creation remains available only through create_private_charger_site().
grant select, delete on table public.private_charger_sites to authenticated;
grant select, delete on table public.private_charger_site_invites to authenticated;

-- Edge Functions read and upsert the catalog with a server-side service key.
-- No client role can access its rows directly.
revoke all on table public.charger_catalog from service_role;
grant select, insert, update on table public.charger_catalog to service_role;
