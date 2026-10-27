# Plan 004: Prevent overlapping favorite mutations for one charger

> **Executor instructions**: Follow the drift check and tests; update `plans/README.md` after verification. Do not silently discard a server error or assume request completion order.
>
> **Drift check (run first)**: `git diff --stat 093cd1d -- VoltWay/AppStore.swift VoltWay/Views.swift VoltWayTests/VoltWayTests.swift && git status --short`
> Plan 002 intentionally touches AppStore and tests. Re-read the current favorite code before editing; stop if its mutation semantics no longer match the Current state section.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: LOW–MED — only the favorite mutation path changes, but account switching needs care.
- **Depends on**: `plans/001-working-ci.md`, `plans/002-private-favorite-privacy.md`
- **Category**: correctness
- **Planned at**: commit `093cd1d`, 2026-10-27

## Why this matters

Two rapid taps on the same heart can start overlapping POST and DELETE requests. The optimistic local state changes immediately, but the server may commit the requests in the opposite order, leaving Saved and the account's persisted favorites inconsistent. Make each station's mutation a single-flight operation and show that the heart is temporarily busy.

## Current state

- `VoltWay/AppStore.swift:4-6` is a `@MainActor @Observable` store.
- `AppStore.swift:414-468` computes `matchingIDs`, updates `favorites` optimistically, then awaits one or more backend writes. There is no per-station in-flight guard. The catch path reconciles partial alias deletion by reloading favorites; preserve that behavior.
- `VoltWay/Views.swift:1249-1257` starts `Task { await store.toggleFavorite(station) }` for every tap and never disables the button.
- `AppStore.swift:163-190` clears account state on sign-out; `accountRevision` protects stale responses. A stale operation must not clear a new account's busy state.
- `VoltWayTests/VoltWayTests.swift:1099-1255` contains favorite alias and partial-delete tests using `MockURLProtocol`. Match its Swift Testing style and do not relax those tests.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Swift suite | `xcodebuild -project VoltWay.xcodeproj -scheme VoltWay -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO test` | exit 0, zero failures |
| Backend suite | `node --test supabase/functions/stations/*.test.mjs supabase/functions/sync-ocm/*.test.mjs supabase/functions/sync-mevnet/*.test.mjs` | exit 0, zero failures |
| Diff check | `git diff --check` | exit 0 |

## Scope

**In scope**: `VoltWay/AppStore.swift`, `VoltWay/Views.swift`, `VoltWayTests/VoltWayTests.swift`, `plans/README.md` status row.

**Out of scope**: backend favorite schema/API, station merge behavior, design of Saved, CarPlay templates, auth/session refresh. Do not replace the existing partial-delete reconciliation with a blind rollback.

## Git workflow

- Use `codex/004-serialize-favorite-toggles` if asked for a branch; follow the repo's conventional commit titles.
- No push/PR without authorization.

## Steps

### Step 1: Characterize overlapping calls with a controllable test

Add a test that delays the first favorite POST or DELETE, calls `toggleFavorite` again for the same station, then releases the first request. Assert only one mutation request is in flight, the stored state and local state agree, and alias-delete reconciliation still works. Add a separate account-switch/sign-out case: the old operation must not clear a new account's busy marker.

**Verify**: Swift test command → the new overlap case fails against the current implementation, while existing favorite tests remain runnable.

### Step 2: Add a per-station single-flight guard

In `VoltWayStore`, expose an observable set or derived query for favorite IDs currently mutating, and add a guard at the start of `toggleFavorite` before the optimistic update. Mark the canonical station ID busy through completion (including failure/reconciliation). Clear it with an operation token or captured account revision so a late result from an old account cannot remove a newer account's busy marker. Clear the busy state on sign-out. A second tap while busy may be ignored; after completion, another tap must work normally. Do not create a global lock that prevents saving different stations concurrently.

**Verify**: the new overlap and account-switch tests plus the existing alias tests pass.

### Step 3: Reflect the busy state in the native control

Disable the station-detail heart for that station while its mutation is in flight and keep an accessible label/value that indicates saving/removing is in progress. Retain the existing native toolbar button and its favorite state after completion.

**Verify**: Swift suite and `git diff --check` pass; `git diff --name-only` lists only files in scope.

## Test plan

- Rapid double tap with delayed POST, then delayed DELETE; only one request per in-flight operation.
- A failed mutation still releases the busy state and keeps existing rollback/reconciliation behavior.
- Two different station IDs can save concurrently.
- Sign-out followed by another account's mutation cannot have its marker cleared by the prior account's response.
- Existing alias deletion tests remain green.

## Done criteria

- [ ] Same-station requests cannot overlap; different-station requests can.
- [ ] Heart shows a busy/disabled state and becomes available after success or failure.
- [ ] Account revision prevents stale completion from corrupting new-account state.
- [ ] Full Swift and Node suites pass; `git diff --check` passes.
- [ ] No files outside scope changed.

## STOP conditions

- Plan 002 changed favorite persistence so substantially that the test's save/delete semantics no longer apply.
- A reliable overlap test needs production hooks outside this plan's scope; report the needed hook before changing unrelated networking code.
- A fix would discard or conceal the existing partial-alias-deletion recovery path.

## Maintenance notes

If a future Saved screen gains its own heart button, bind it to this store-level busy state as well; UI-only disabling is insufficient because multiple entry points can call the store.
