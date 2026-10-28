# Plan 005: Make new-vehicle retries idempotent after a partial save

> **Executor instructions**: Read the current code after plans 001 and 004, then follow the steps and gates. Update `plans/README.md`. Do not add a new Supabase RPC as an unreviewed shortcut.
>
> **Drift check (run first)**: `git diff --stat e169084..HEAD -- VoltWay/AppStore.swift VoltWay/Views.swift VoltWayTests/VoltWayTests.swift && git status --short`
> Earlier plans may touch these files. Compare the current `saveProfile` and form implementation to the excerpts below; stop on a semantic mismatch.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — account state after a partially successful pair of writes must reflect the server.
- **Depends on**: `plans/001-working-ci.md`; execute after `plans/004-serialize-favorite-toggles.md` to reduce overlapping AppStore edits
- **Category**: correctness
- **Planned at**: refreshed against commit `e169084`, 2026-10-28

## Why this matters

Creating a vehicle performs two separate Supabase writes: save the profile and select it as active. If the first succeeds and the second fails, the server has a vehicle that the current local state does not show. Pressing Save again currently generates a new UUID and can create duplicates. Give the form a stable ID across retries and reconcile account state after a partial save, without needing a new backend request type.

## Current state

- `VoltWay/AppStore.swift:343-373` builds `updated` with `id: previous?.id ?? UUID()`; for `createsNew`, `previous` is always nil. It calls `backend.saveProfile` then `backend.setActiveVehicle`, and only updates `vehicles` after both succeed. Its catch path only shows an error. There is no account-revision check between those writes.
- `VoltWay/Services.swift:206-226` upserts a vehicle by `id` and separately upserts `user_preferences` by `user_id`; these are not one database transaction from the app.
- `VoltWay/Views.swift:2471-2485` keeps the form open on failure but passes `vehicle?.id` (nil for a new vehicle) on every Save tap. An edit sheet can retain an ID after that vehicle is removed from the local list.
- `VoltWay/AppStore.swift:524-528` treats `profiles.first` as active even when the server preference is nil or names an absent profile. The migration permits a null preference; this fallback must not turn a failed selection into a confirmed one after restart.
- `VoltWayTests/VoltWayTests.swift:1817-1851` checks rollback when the **first** write fails; `:1017-1055` checks switching existing vehicles. Follow their `MockURLProtocol.bodyData(for:)` and Swift Testing pattern.
- `supabase/migrations/202609280002_multiple_vehicles.sql:9-27` keeps the active ID in a separate owner-scoped preference row. No schema change is required for idempotent retries.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Swift suite | `xcodebuild -project VoltWay.xcodeproj -scheme VoltWay -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO test` | exit 0, zero failures |
| Backend suite | `node --test supabase/functions/stations/*.test.mjs supabase/functions/sync-ocm/*.test.mjs supabase/functions/sync-mevnet/*.test.mjs` | exit 0, zero failures |
| Diff check | `git diff --check` | exit 0 |

## Scope

**In scope**: `VoltWay/AppStore.swift`, `VoltWay/Views.swift`, `VoltWayTests/VoltWayTests.swift`, `plans/README.md` status row.

**Out of scope**: SQL migrations, Supabase Edge Functions, station fetch, favorites, CarPlay template design, vehicle telemetry. Do not duplicate a failed first write by silently creating a second vehicle.

## Git workflow

- Use `codex/005-reconcile-vehicle-creation` if asked to branch; match existing conventional commit style.
- Do not push/PR without operator authorization.

## Steps

### Step 1: Add a failing partial-save test

Mock a successful profile POST, a failing active-preference POST, and successful profile/preference GETs. Assert the first call reports failure but the server-created vehicle becomes visible after reconciliation, without falsely changing active selection. Include the **first-vehicle case** where preference GET returns nil: `activeVehicleID` must remain nil, not fall back to the new profile. Retry `saveProfile` with the same form-owned ID and assert the second profile POST uses that UUID and the server has only one vehicle. Add a case where the first POST response is lost after commit: retry must still reuse that UUID. Preserve the existing first-write-failure rollback test. Unit tests can prove store idempotency; the form's repeated use of its `@State` ID needs code inspection because this repo has no UI-test target.

Also cover a stale edit ID (it must not create a different vehicle) and an account switch while the profile POST is blocked (it must not proceed to a preference POST for the old account). Use the existing account-revision test pattern rather than relying on sleeps.

**Verify**: Swift test command → new partial-save/retry cases fail before implementation; existing first-write rollback remains green.

### Step 2: Keep one ID for the lifetime of a new-vehicle form

In the add-vehicle form, allocate a `@State` UUID once and pass it as `vehicleID` for every Save attempt. In `VoltWayStore.saveProfile`, use that provided ID for `createsNew` instead of generating a new UUID on every call. Existing edits must keep their current profile ID. Do not persist the pending ID separately.

If an edit supplies an ID that is no longer in the current account's `vehicles`, reject it with a refresh/retry message instead of allocating a new ID. Check the captured account revision and user after the profile POST, before sending the active-preference POST.

**Verify**: Swift test command → retry UUID assertion passes; existing edit tests pass. `rg -n 'pending.*ID|vehicleID:' VoltWay/Views.swift` → the same form-owned ID is passed at every Save attempt.

### Step 3: Reconcile a successful first write followed by a failed second write

Track whether the profile upsert completed. If active-preference saving then fails for the same account revision, reload profiles and preference using `BackendClient.loadProfiles` / `loadActiveVehicleID`, update local `vehicles`, `activeVehicleID`, and `profile` to match the server, and rebuild compatible stations/CarPlay snapshot. **Do not reuse `loadAccountData`'s current `profiles.first` fallback (`AppStore.swift:510-512`)** for this case: nil preference means no confirmed active selection. Update that bootstrap fallback too, or explicitly represent its first profile as local/provisional rather than persisted, so a restart cannot falsely claim the failed selection succeeded. Keep the form open and present a precise message that the vehicle was saved but active selection was not confirmed. If reconciliation itself fails, set `accountDataNeedsRetry` and do not claim local and server state agree. Guard every post-await update by the existing account revision/user checks. Do not reload the nationwide charger catalog.

**Verify**: new partial-save tests, existing `profileRollback`, and the full Swift suite pass. The backend test command exits 0.

## Test plan

- First write fails: local previous profile remains, as before.
- First succeeds/second fails: one remote row; local state reconciles to server; active vehicle not falsely switched, including a first vehicle with nil preference.
- Retry after second-write failure: same UUID, no duplicate profile.
- First write commits but response is lost: retry remains idempotent.
- Account switches during reconciliation: stale result cannot repopulate the new account.
- Account switches before the second write: no obsolete active-preference POST is sent.
- A stale edit ID never becomes a newly generated vehicle row.

## Done criteria

- [ ] A new-vehicle form uses one UUID for all retries.
- [ ] Partial success is reconciled or explicitly marked as needing account-data retry; no silent orphan/duplicate.
- [ ] Active selection is never claimed when its write was not confirmed, including after restart with nil preference.
- [ ] A stale edit does not create a different vehicle; a stale account does not send the second write.
- [ ] Full Swift and Node suites plus `git diff --check` pass.
- [ ] No files outside scope changed.

## STOP conditions

- The remote profile/preference APIs have changed or a server transaction has already replaced the two writes.
- Reconciliation would require reading another user's data or changing RLS.
- A test needs live credentials; use existing mock fixture patterns and report the live-project gate separately.

## Maintenance notes

The same stable-ID/reconciliation pattern should be considered for private-site creation, which also allocates a UUID before a network write. Do not call two independent writes “atomic”; the correctness property here is idempotent retry plus honest reconciliation.
