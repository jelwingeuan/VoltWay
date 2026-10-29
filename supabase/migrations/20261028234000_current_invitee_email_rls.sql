-- Invitation access must follow the account's current confirmed email, not a
-- potentially stale email claim in an otherwise valid access token.
create schema voltway_private;
revoke all on schema voltway_private from public, anon, authenticated;
grant usage on schema voltway_private to authenticated;

-- Keep the auth.users lookup outside the exposed Data API schemas. The only
-- identity accepted is the caller's signed JWT subject; no user ID is supplied.
create function voltway_private.current_confirmed_email()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select lower(btrim(users.email))
  from auth.users as users
  where users.id = (select auth.uid())
    and users.email_confirmed_at is not null
$$;

revoke all on function voltway_private.current_confirmed_email() from public, anon, authenticated;
grant execute on function voltway_private.current_confirmed_email() to authenticated;

drop policy "owners and invited users read private sites" on public.private_charger_sites;
create policy "owners and invited users read private sites" on public.private_charger_sites
for select to authenticated using (
  owner_id = (select auth.uid())
  or exists (
    select 1 from public.private_charger_site_invites invite
    where invite.site_id = private_charger_sites.id
      and invite.invited_email = (select voltway_private.current_confirmed_email())
  )
);

drop policy "owners and invitees read private site invitations" on public.private_charger_site_invites;
create policy "owners and invitees read private site invitations" on public.private_charger_site_invites
for select to authenticated using (
  invited_by = (select auth.uid())
  or invited_email = (select voltway_private.current_confirmed_email())
);
