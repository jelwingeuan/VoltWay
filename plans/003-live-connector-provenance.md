# Plan 003: Prevent directory connector facts from inheriting live availability

> **Executor instructions**: Run the drift check, make only the scoped change, run each verification gate, and update `plans/README.md`. Do not deploy or push without operator authorization.
>
> **Drift check (run first)**: `git diff --stat 093cd1d -- supabase/functions/stations/shared.ts supabase/functions/stations/shared.test.mjs && git status --short`
> Stop if `combineNationwide` or its tests no longer match the excerpts below.

## Status

- **Priority**: P1 (driver-facing truthfulness)
- **Effort**: S–M
- **Risk**: MED — compatibility results for deduplicated sites will change.
- **Depends on**: `plans/001-working-ci.md`
- **Category**: correctness
- **Planned at**: commit `093cd1d`, 2026-10-27

## Why this matters

`combineNationwide` adds an Open Charge Map connector type to a Gentari site while keeping Gentari's site-wide live availability. A Type 2-only driver can then find the site as compatible and see a fresh available count even though Gentari never confirmed Type 2 availability. Avoid attaching a live status to directory-only connector evidence. Preserve the site and source attribution; do not pretend that OCM has a live feed.

## Current state

- `supabase/functions/stations/shared.ts:315-337` processes sources in Gentari, OCM, MEVnet order. For a same-site duplicate it preserves `existing` (the partner station) and appends connector kinds absent from `existing.connectors`:
  ```ts
  connectors: [...existing.connectors, ...incoming.connectors.filter((connector) =>
    !existing.connectors.some((current) => current.kind === connector.kind))],
  ```
  The spread also preserves `existing.availability` and `existing.price`.
- `supabase/functions/stations/shared.test.mjs:100-112` currently expects OCM Type 2 enrichment on a Gentari CCS2 station and expects the merged station to match a Type 2 filter.
- `VoltWay/Models.swift:55-60` considers any station connector compatible; `:608` uses the station's availability for Available now. There is no per-connector live-status model.
- `supabase/functions/stations/shared.ts:271-300` has an older `combineSources` path that suppresses duplicates without connector enrichment. `stations/index.ts:35` uses `combineNationwide`, so that is the active path.
- Tests use Node's `node:test` and `assert`, with no package install (`shared.test.mjs:1-13`). Match the nearby test style.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `node --test supabase/functions/stations/shared.test.mjs` | exit 0, no failures |
| Full backend suite | `node --test supabase/functions/stations/*.test.mjs supabase/functions/sync-ocm/*.test.mjs supabase/functions/sync-mevnet/*.test.mjs` | exit 0, no failures |
| Swift suite | `xcodebuild -project VoltWay.xcodeproj -scheme VoltWay -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO test` | exit 0, no failures when simulator works |
| Diff check | `git diff --check` | exit 0 |

## Scope

**In scope**: `supabase/functions/stations/shared.ts`, `supabase/functions/stations/shared.test.mjs`, `plans/README.md` status row.

**Out of scope**: Gentari's own connectors/status/price, OCM-only records, station ID/source-ID merge, dedup accounting, Swift UI, schema, credentials, CarPlay. This plan is the conservative safety fix; a later separately designed per-connector status model could restore directory-only connector discovery without claiming live availability.

## Git workflow

- Branch `codex/003-live-connector-provenance` if requested. Follow conventional messages such as `fix: improve charger catalog and trip reliability`.
- No push or PR without operator authorization.

## Steps

### Step 1: Write failing coverage for mismatched connector provenance

In `shared.test.mjs`, construct a Gentari CCS2 site with a fresh available status and positive count, plus a same-site OCM record with Type 2. Assert the merged record keeps Gentari's ID, availability, CCS2 connector, combined source IDs and attribution, but does **not** advertise Type 2 as a partner-confirmed connector. Assert `filterStations(..., new Set(["type2"]), 0)` does not return the partner record. Add a second case that an unmatched OCM Type 2-only site remains discoverable with unknown availability, so this change does not remove directory-only sites. Update the pre-existing enrichment test at lines 100-112 to express the new safety rule.

**Verify**: `node --test supabase/functions/stations/shared.test.mjs` → the new mismatched-connector case fails before the implementation; existing unrelated tests still run.

### Step 2: Keep partner connector claims authoritative on a live merged site

In `combineNationwide`, when an `existing.source === "gentari"` site merges with a non-partner directory/planning record, preserve `existing.connectors` unchanged. Continue merging source IDs, attribution, access, address fallback, and planning metadata exactly as today. For records without a Gentari live source, retain current directory-only connector behavior. Do not zero out Gentari availability for its own verified connectors.

**Verify**: focused and full backend commands → all tests pass. The new test must prove a Type 2-only filter cannot inherit the partner's available status while an OCM-only Type 2 site still appears with unknown status.

### Step 3: Check app contract and diff

Confirm `stations/index.ts:35-50` still returns the same station schema and stable Gentari IDs, and that no coordinate was added to the charger request. Run the Swift suite when a simulator is available; this backend-only change should not require app decoding changes.

**Verify**: `git diff --check` → exit 0; `git diff --name-only` → only the two scoped source/test files and plan index.

## Test plan

- Same-site Gentari CCS2 + OCM Type 2 with fresh partner availability: Gentari-only connector remains; Type 2-only match fails; source attribution and duplicate ID remain.
- Same-site identical connector kind: Gentari power/count wins.
- Unmatched OCM Type 2: remains a directory record with `availability.state == "unknown"`, displayed as status unavailable.
- Existing MEVnet proposed separation and duplicate-count tests remain green.

## Done criteria

- [ ] No merged Gentari station advertises a connector kind present only in a directory source while retaining Gentari availability.
- [ ] Gentari ID, live facts, and cross-source metadata are unchanged; unmatched OCM sites remain discoverable.
- [ ] Focused and full Node suites pass; Swift suite passes when the simulator is available.
- [ ] `git diff --check` passes and only scoped files changed.

## STOP conditions

- A written Gentari feed contract says its site-wide status is valid for all site connectors including OCM-listed kinds; obtain that contract before overriding the conservative rule.
- Preserving every connector kind on merged records is a hard launch requirement; this needs a separate per-connector provenance/status design, not a silent UI label change.
- The active merge path or station schema has changed since this plan was written.

## Maintenance notes

When adding another live operator, distinguish operator-confirmed connector kinds from third-party directory data before merging. A future per-connector status design should cover Explore, Saved, Trip, detail, and CarPlay consistently; do not reintroduce a site-level available label for an unconfirmed compatible connector.
