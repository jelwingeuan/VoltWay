# VoltWay

VoltWay is an iOS 17+ and CarPlay pilot for finding compatible Gentari EV chargers in Malaysia, viewing normalized availability and pricing, saving favorites, and handing navigation to Apple Maps.

## Run the app

Open `VoltWay.xcodeproj` in Xcode 27 and run the `VoltWay` scheme on an iPhone simulator. With no backend configuration, the app intentionally opens in clearly labeled demo mode using bundled station fixtures.

To connect Supabase, set these user-defined build settings on the app target (prefer an ignored `Config/Secrets.xcconfig`):

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

The anonymous key is public by design. Never put `GENTARI_API_TOKEN` in the app.

## Supabase

Apply the migration, then configure and deploy the function:

```sh
supabase db push
supabase secrets set GENTARI_API_URL='https://partner.example/stations' GENTARI_API_TOKEN='replace-me'
supabase functions deploy stations
```

The partner adapter accepts common field names but must be aligned with the written Gentari feed contract before release. It emits only the normalized station fields used by the app and never forwards the partner credential. A price needs its own update timestamp; missing or older-than-24-hour prices display as unavailable. Availability uses a five-minute freshness window. These are provisional pilot rules until the partner contract defines them.

Location is used in memory on the device to sort chargers. It is not included in the Supabase station request or saved as history.

## CarPlay

CarPlay source and scene configuration are included, but the restricted entitlement is intentionally not enabled. After Apple grants the EV-charging capability:

1. Copy `CarPlay.entitlements.example` to `VoltWay/VoltWay.entitlements`.
2. Set the app target’s Code Signing Entitlements to `VoltWay/VoltWay.entitlements`.
3. Regenerate the provisioning profile with the granted capability.
4. Validate Nearby (with previously granted location access), Chargers (without it), Saved, station details, and Apple Maps handoff in CarPlay Simulator and a supported vehicle.

Signing out clears the locally cached CarPlay station snapshot. Without a snapshot, CarPlay shows an empty state rather than demo chargers.

## Verify

```sh
xcodebuild -project VoltWay.xcodeproj -scheme VoltWay -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

The simulator suite covers model freshness, token refresh, request privacy, profile rollback, and snapshot clearing with mocked responses. Live Supabase authentication and row-level isolation require a configured project; live availability/pricing require the written partner agreement and feed. CarPlay scene behavior requires Apple’s approved EV-charging entitlement and a matching provisioning profile. None of those external integrations are validated by the mocked suite. Charging activation, payments, reservations, vehicle telemetry, custom navigation, and multi-network aggregation are outside this pilot.
