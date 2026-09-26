# VoltWay

VoltWay is an iOS 26+ and CarPlay pilot for finding compatible Malaysian EV chargers from a Gentari partner feed and an Open Charge Map directory snapshot, saving favorites, and handing navigation to Apple Maps. Gentari may provide current availability and pricing; Open Charge Map locations do not. Its iPhone controls use native Liquid Glass while charger data remains on solid, readable surfaces.

## Run the app

Open `VoltWay.xcodeproj` in Xcode 27 and run the `VoltWay` scheme on an iPhone simulator. With no backend configuration, the app intentionally opens in clearly labeled demo mode using bundled Gentari and Open Charge Map examples. The default demo vehicle has no minimum-power filter, so every compatible network can be explored. Explore opens on a map without requesting location; switch between Map and List, search by station name, address, or operator, choose a network, and toggle Available now. Both views use the same filters. Open Charge Map stations never qualify as Available now because directory status is not live. Tap a map marker for status, price, Details, and Apple Maps navigation. In live mode, use Refresh chargers from either view; the last successful station-list fetch time remains visible if a refresh fails. This time does not change the separate status and price freshness rules. Source warnings and directory sync time are shown separately. Use the location button only when you want to recenter and sort by distance. The Trip tab lets you search for a destination, then explicitly allow/use your current location to calculate a recommended driving route and find compatible stations within 5 km of its geometry. Trip stops are listed in travel order with straight-line distance from the route; no road detour or automatic stop choice is estimated. Saved holds favorites; the profile button opens account and vehicle settings. Charger details include 10, 20, and 40 kWh cost estimates only when the reported MYR/kWh price is fresh, plus up to three other compatible chargers within 10 km straight-line distance of that charger. Demo values are not live partner data and do not show a last-fetched claim.

The added demo directory sites are real Open Charge Map contributor records: Shell Recharge [Pavilion KL](https://openchargemap.org/poi/details/279460) and [Temerloh](https://openchargemap.org/poi/details/479684); TNB Electron [Bagan Serai](https://openchargemap.org/poi/details/480555) and [Bayan Lepas](https://openchargemap.org/poi/details/480140); [JomCharge TTDI](https://openchargemap.org/poi/details/505071), [chargEV Gemas](https://openchargemap.org/poi/details/497573), and [ChargeSini Kuantan](https://openchargemap.org/poi/details/259727). They are a fixed example snapshot, not a promise that a site is open, available, or priced as shown elsewhere. Check the operator before travelling. Each station detail links back to its CC BY 4.0 directory record.

To connect Supabase, set these user-defined build settings on the app target (prefer an ignored `Config/Secrets.xcconfig`):

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

The anonymous key is public by design. Never put the Gentari token, Open Charge Map key, or sync token in the app.

## Supabase

Apply the migrations, then configure and deploy the functions:

```sh
supabase db push
supabase secrets set GENTARI_API_URL='https://partner.example/stations' GENTARI_API_TOKEN='replace-me'
supabase secrets set OPEN_CHARGE_MAP_API_KEY='your-ocm-key' OCM_SYNC_TOKEN='a-long-random-server-only-token'
supabase functions deploy stations
supabase functions deploy sync-ocm
```

The Gentari adapter accepts common field names but must be aligned with the written partner contract before release. It never forwards partner credentials. The Open Charge Map import uses `countrycode=MY` and only contributor-owned records (provider ID 1, CC BY 4.0); records from other data providers need an individual license review. Its API key is server-only. The directory is for locations/connectors, not real-time status or prices, so those fields are always unavailable. An unknown connector power does not satisfy a minimum-power filter. See [Open Charge Map API and attribution terms](https://openchargemap.org/develop) and [the contributor license note](https://community.openchargemap.org/t/announcing-our-new-simpler-data-license-for-ocm-data-cc-by-4-0-international/565).

To activate the daily import, enable Supabase `pg_cron` and `pg_net`, then add Vault secrets named `voltway_project_url`, `voltway_publishable_key`, and `voltway_ocm_sync_token` (the last must equal `OCM_SYNC_TOKEN`). Run `supabase/schedule_open_charge_map.sql` in the SQL editor after those secrets exist. The job calls `sync-ocm` at 18:00 UTC, or 02:00 Malaysia time. Trigger one authenticated sync manually before relying on the daily job, and inspect `public.charger_catalog.synced_at` and Cron job history. A failed or empty import never overwrites the last successful snapshot. The table has RLS enabled with no client policies; only Edge Functions use its service-role access. [Supabase scheduled-function setup](https://supabase.com/docs/guides/functions/schedule-functions).

The charger endpoint still requires a signed-in user. It returns whichever configured source succeeds and a partial-coverage warning if the other source is unavailable. A price needs its own update timestamp; missing or older-than-24-hour prices display as unavailable. Availability uses a five-minute freshness window. These are provisional pilot rules until the partner contract defines them.

Location is requested only when you choose Use my location or start trip planning. VoltWay uses it in memory to sort chargers/recenter the map or calculate a trip; it is never included in the Supabase station request or saved as history. Trip search and directions are processed by Apple MapKit, which receives the destination and current location for routing. Destination, route geometry, and results are not persisted. Available now requires a reported positive connector count and a status updated within five minutes; stale or missing status is excluded.

## CarPlay

CarPlay source and scene configuration are included, but the restricted entitlement is intentionally not enabled. After Apple grants the EV-charging capability:

1. Copy `CarPlay.entitlements.example` to `VoltWay/VoltWay.entitlements`.
2. Set the app target’s Code Signing Entitlements to `VoltWay/VoltWay.entitlements`.
3. Regenerate the provisioning profile with the granted capability.
4. Validate Nearby (with previously granted location access), Chargers (without it), Saved, station details, and Apple Maps handoff in CarPlay Simulator and a supported vehicle.

Signing out clears the locally cached CarPlay station snapshot. Without a snapshot, CarPlay shows an empty state rather than demo chargers. A demo snapshot is labeled as such in CarPlay lists and details.

## Verify

```sh
xcodebuild -project VoltWay.xcodeproj -scheme VoltWay -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
node --test supabase/functions/stations/*.test.mjs supabase/functions/sync-ocm/*.test.mjs
```

The Swift suite covers discovery, network filters, demo directory fixtures, freshness, estimates, route stops, alternatives, auth/session behavior, request privacy, favorite snapshots, unknown connector values, and partial-source metadata. The backend checks use Node.js 24+ for TypeScript support and cover Open Charge Map licensing, normalization, filtering, and source merging. Also inspect Explore map/list, station details, Trip, Saved, empty/error states, and demo labels in light/dark appearance and large text. Check Reduce Motion, Reduce Transparency, Increase Contrast, denied location, and Apple Maps handoff on a simulator. Live Supabase authentication/RLS and catalog sync need a configured project; live Gentari availability/pricing need the written partner agreement and feed. CarPlay interaction needs Apple's approved EV-charging entitlement. Charging activation, payments, reservations, vehicle telemetry, and custom navigation remain outside this pilot.
