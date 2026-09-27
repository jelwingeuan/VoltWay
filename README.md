# VoltWay

VoltWay is an iOS 26+ and CarPlay pilot for finding Malaysian EV charging sites from a Gentari partner feed, a licensed Open Charge Map directory snapshot, and (after reuse approval) a PLANMalaysia MEVnet planning snapshot. Gentari may provide current availability and pricing; directory and planning records do not. Its iPhone controls use native Liquid Glass while charger data remains on solid, readable surfaces.

## Run the app

Open `VoltWay.xcodeproj` in Xcode 27 and run the `VoltWay` scheme on an iPhone simulator. With no backend configuration, demo mode shows nine real, attributed Open Charge Map locations as examples, not a nationwide catalog. Demo status and price are unavailable. Explore opens on a clustered map without requesting location. Switch between Compatible (the active vehicle) and All sites (including listings with unknown connectors), then use the shared Map/List search, network, Available now, AC/DC, listed-power, and access filters. Proposed MEVnet planning sites are hidden by default and can be shown in advanced filters. Directory records never qualify as Available now because their status is not live. Tap a map marker for status, price, Details, and Apple Maps navigation. In live mode, Refresh chargers keeps the prior list and successful fetch time if it fails; source timestamps remain separate. Use the location button only when you want to recenter and sort by distance. The Trip tab uses Apple MapKit to find compatible stops within 5 km of a driving route after you choose a destination and explicitly request location. Saved keeps account-wide favorite IDs, but a directory snapshot cannot surface a site that is absent from the current public catalog. The Profile tab lists sites and source-reported charge-point counts, last imports and exclusions, and missing operator feeds. It also lets you manage vehicles and add a private charger: sharing requires owner permission, and only the owner and invited email can see the location. Charger details include energy estimates only when a reported MYR/kWh price is fresh.

The demo locations are a fixed CC BY 4.0 Open Charge Map snapshot: DC Handal [IOI Mall Damansara](https://openchargemap.org/poi/details/505443), EVPower [168 Park Mall Selayang](https://openchargemap.org/poi/details/470421), Shell Recharge [Pavilion KL](https://openchargemap.org/poi/details/279460) and [Temerloh](https://openchargemap.org/poi/details/479684), TNB Electron [Bagan Serai](https://openchargemap.org/poi/details/480555) and [Bayan Lepas](https://openchargemap.org/poi/details/480140), [JomCharge TTDI](https://openchargemap.org/poi/details/505071), [chargEV Gemas](https://openchargemap.org/poi/details/497573), and [ChargeSini Kuantan](https://openchargemap.org/poi/details/259727). They are real location records, not a promise that the sites are currently open, available, or priced as shown elsewhere. Check the operator before travelling. Each station detail links to its source record.

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
# Only after PLANMalaysia confirms redistribution permission:
supabase secrets set MEVNET_SYNC_TOKEN='a-separate-long-random-token' MEVNET_REUSE_APPROVED='true'
supabase functions deploy sync-mevnet
```

The Gentari adapter accepts common field names but must be aligned with the written partner contract before release. It never forwards partner credentials. The Open Charge Map import pages through *all* records returned for `countrycode=MY`, without an upstream open-data filter, and requires an empty final page before replacing the catalog. It includes records whose provider metadata carries reviewed CC0 or CC BY 4.0 redistribution terms, with provider-specific attribution; unfamiliar or ambiguous licenses remain excluded for review. OCM-marked private sites are excluded because their owners have not granted VoltWay permission. The atomic `import_report` records fetched/included/excluded counts, per-provider totals, excluded OCM IDs by reason, and providers whose records need license review. The Profile coverage view reports sites separately from charge points when OCM supplies a point count. The OCM API key is server-only. Directory status and price are always unavailable, and unknown power does not satisfy a minimum-power filter. See [Open Charge Map API terms](https://www.openchargemap.org/develop/api), [OCM's export and license notes](https://github.com/openchargemap/ocm-export), and [its provider reference data](https://github.com/openchargemap/ocm-export/blob/main/data/referencedata.json).

To activate the daily OCM import, enable Supabase `pg_cron` and `pg_net`, then add Vault secrets named `voltway_project_url`, `voltway_publishable_key`, and `voltway_ocm_sync_token` (the last must equal `OCM_SYNC_TOKEN`). Run `supabase/schedule_open_charge_map.sql` in the SQL editor after those secrets exist. The job calls `sync-ocm` at 18:00 UTC, or 02:00 Malaysia time. Trigger one authenticated sync manually before relying on the daily job, and inspect `public.charger_catalog.synced_at`, `import_report`, and Cron job history. Reconcile `fetched = included + private + invalid + license`, review every excluded ID and unreviewed provider ID, and compare `duplicateIDs` in an authenticated stations response with Gentari sites. A failed or empty import never overwrites the last successful snapshot. The catalog has RLS enabled with no client policies; only Edge Functions use its service-role access. The new `vehicle_profiles` migration preserves each prior profile, gives it an ID/name, and creates an active-vehicle preference with owner-only RLS. Validate those policies in a configured project before launch. [Supabase scheduled-function setup](https://supabase.com/docs/guides/functions/schedule-functions).

The MEVnet adapter is prepared but disabled unless `MEVNET_REUSE_APPROVED=true` is set after documented PLANMalaysia permission. A publicly queryable service with no copyright notice does not itself grant redistribution rights. Once approved, run `supabase/schedule_mevnet.sql` after storing `voltway_mevnet_sync_token` in Vault. Its job runs at 02:30 MYT. The importer checks the source count, pages deterministically through the entire layer, reconciles each source ID as included, explicitly private, access-unverified, or invalid, and atomically replaces only a complete snapshot. Residential, strata, office, and university planning records are held out of public discovery until their access is verified; an independently licensed public operator or OCM record can still appear. The Profile coverage view separates MEVnet existing and proposed records and reports counts by state. Proposed sites are hidden from Explore by default; the advanced filter can show them as planning records in All sites. MEVnet AC/DC counts never become exact connectors or live status. No MEVnet snapshot is bundled into demo mode.

A read-only MEVnet download on 28 September 2026 fetched 4,477 source records and reconciled them as 4,017 candidates, 457 access-unverified sites held out, and three invalid records; no snapshot was published. Of the candidates, 917 were marked existing and 3,100 proposed. These are source records, not a count of operating Malaysian chargers or a merged Gentari/OCM catalog. Re-run the download and compare its import report before any approved deployment, because source counts can change.

The charger endpoint still requires a signed-in user. It returns whichever of Gentari, OCM, and MEVnet succeeds and warns when coverage is partial. It reads owner-shared private sites using the caller's JWT so database RLS returns only sites owned by or invited to that account. Private site creation runs through an authenticated RPC; owner consent is required, and invitations are matched to the invited account's email. Status and price are stripped from owner submissions. Apply `202609280003_private_charger_sharing.sql` to enable the private site flow. No direct operator feed beyond Gentari is connected. The prototype's coverage view lists missing direct feeds and does not claim nationwide completeness. A price needs its own update timestamp; missing or older-than-24-hour prices display as unavailable. Availability uses a five-minute freshness window. These are provisional pilot rules until the partner contract defines them.

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
node --test supabase/functions/stations/*.test.mjs supabase/functions/sync-ocm/*.test.mjs supabase/functions/sync-mevnet/*.test.mjs
```

The Swift suite covers discovery, network filters, demo directory fixtures, coverage counts, freshness, estimates, route stops, alternatives, auth/session behavior, request privacy, favorite snapshots, unknown connector values, and partial-source metadata. The backend checks use Node.js 24+ for TypeScript support and cover Open Charge Map licensing, private-site normalization, RLS-scoped reads, filtering, and source merging. Also inspect Explore map/list, station details, Trip, Saved, private-site sharing, empty/error states, and demo labels in light/dark appearance and large text. Check Reduce Motion, Reduce Transparency, Increase Contrast, denied location, and Apple Maps handoff on a simulator. Live Supabase authentication/RLS and catalog sync need a configured project; live Gentari availability/pricing need the written partner agreement and feed. CarPlay interaction needs Apple's approved EV-charging entitlement. Charging activation, payments, reservations, vehicle telemetry, and custom navigation remain outside this pilot.
