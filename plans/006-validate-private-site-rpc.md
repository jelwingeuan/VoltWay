# Plan 006: Reject private charger submissions that discovery cannot show

> **Executor instructions**: Follow the steps and gates below. Preserve all existing uncommitted work. The advisor maintains `plans/README.md`; do not edit it. Do not deploy or push.
>
> **Drift check (run first)**: `git diff --stat e169084..HEAD -- supabase/migrations/202609280003_private_charger_sharing.sql supabase/tests/private_favorite_storage.sql .github/workflows/swift.yml README.md && git status --short`
> If the cited SQL/RPC behavior has changed, stop and report before implementing.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED — tightening the public RPC must not break valid iPhone submissions or existing private-site RLS.
- **Depends on**: none; the existing disposable database CI job supplies a verification path.
- **Category**: correctness/security
- **Planned at**: commit `e169084`, 2026-10-28

## Why this matters

An authenticated client can call `create_private_charger_site` directly. The current table check accepts a nonblank name, any coordinate object, and any connector array; the RPC reports success. The stations Edge Function then rejects malformed coordinates or unsupported/empty connectors, so the owner and invitee cannot discover the saved site. Validate and canonicalize the submission at the server boundary before any insert, with direct database tests. This does not authorize publishing private locations: existing owner-consent, invitation, and RLS rules remain in force.

## Current state

- `supabase/migrations/202609280003_private_charger_sharing.sql:4-9` only checks JSON object/array shapes and nonblank name on `private_charger_sites.station`. The `security definer` RPC at lines 49-97 checks caller, consent, and invitation email, then inserts `p_station` with controlled `id/source/access/availability/price` fields.
- `supabase/functions/stations/shared.ts:166-185` requires a nonblank name of at most 100 characters, Malaysian latitude 0.8-7.5 and longitude 99-120.5, and at least one recognized connector. `stations/index.ts:67` drops invalid rows without returning them.
- `VoltWay/AppStore.swift:262-277` validates the iPhone form, but a direct RPC caller bypasses that check. `VoltWay/Models.swift:4-7` emits canonical connector kinds `type2`, `ccs2`, and `chademo`.
- `supabase/tests/private_favorite_storage.sql` uses pgTAP inside a rolled-back transaction and presently plans 10 tests; it directly seeds an intentionally malformed legacy private row for an RLS test. Keep that seed valid for the test: this plan changes the RPC, **not** the table check or old rows.
- `.github/workflows/swift.yml` runs the pgTAP file in a disposable Supabase database and checks `Tests=10`. It also runs Node tests and iOS tests. Match its existing style.
- The repo uses imperative `supabase/migrations/*.sql`. No local Supabase CLI is currently installed; CI pins CLI `2.122.0`. Never reset a non-disposable local database.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Drift | `git diff --stat e169084..HEAD -- supabase/migrations/202609280003_private_charger_sharing.sql supabase/tests/private_favorite_storage.sql .github/workflows/swift.yml README.md` | No unexpected committed drift |
| Static diff | `git diff --check` | Exit 0 |
| Backend Node | `node --test supabase/functions/stations/*.test.mjs supabase/functions/sync-ocm/*.test.mjs supabase/functions/sync-mevnet/*.test.mjs` | All tests pass, when Node 24+ is available |
| Database | `supabase test db supabase/tests/private_favorite_storage.sql --local` | New pgTAP count passes **only against a confirmed disposable local database** |
| CI | GitHub Actions `database` job on an authorized push/PR | Disposable migration and pgTAP job green |

If the local Supabase CLI or a disposable database is unavailable, record database runtime verification as pending; do not claim that SQL has passed. `supabase --help`/`supabase test --help` must be consulted before invoking the CLI. Supabase's current [database-function guidance](https://supabase.com/docs/guides/database/functions) calls for a pinned search path, explicit caller checks, and narrow function privileges.

## Scope

**In scope**:
- A new migration under `supabase/migrations/` replacing `public.create_private_charger_site` (same signature and return type)
- `supabase/tests/private_favorite_storage.sql`
- `.github/workflows/swift.yml` only to update the expected pgTAP count
- `README.md` only to document server-side validation and its verification gate

**Out of scope**:
- The iPhone form, Edge Function normalization, CarPlay, catalog import, favorite serialization, and existing table constraints/RLS policies
- Any deployment, credential use, destructive reset of a non-disposable database, or automatic publication of private coordinates

## Git workflow

Stay on the current branch and preserve unrelated dirty files. The repository uses conventional commit subjects (for example `fix: improve VoltWay reliability and verification`), but **do not commit or push** without operator instruction.

## Steps

### 1. Add direct RPC regression tests first

Extend `supabase/tests/private_favorite_storage.sql` with owner-authenticated `throws_ok` cases for: missing or out-of-range coordinates, an empty connector array, an unsupported connector kind, an over-100-character name, and invalid connector numeric values. Assert invalid calls create no private-site row. Add a valid canonical site call that returns its UUID and remains visible to the owner; verify stored source/access/status/price remain server-controlled even if supplied values claim otherwise. Set JWT sub/email for the synthetic owner using the file's existing `set local role authenticated` pattern. Increase `plan(...)` and the workflow's `Tests=...` gate by exactly the number of new assertions. Do not change the existing direct-seed RLS test.

**Verify**: `rg -n 'create_private_charger_site|select plan\(|Tests=' supabase/tests/private_favorite_storage.sql .github/workflows/swift.yml` shows the new assertions and matching count. If a disposable CLI database is available, the new assertions should fail before the migration; otherwise record red runtime as unavailable.

### 2. Replace the RPC with validated, bounded input

Create a new migration using `supabase migration new <descriptive-name>` if the CLI exists (discover via `--help`); if it does not, add a timestamped migration using `apply_patch` and record that tool limitation. Keep the existing function signature, `security definer`, `set search_path = ''`, `auth.uid()` guard, owner-consent check, invitation behavior, and explicit `revoke`/`grant` execute privileges. Before inserting, require a nonnull UUID; a JSON object; trimmed name/address/operator strings within the iPhone's 100/240/100-character limits; numeric Malaysian coordinates within the normalizer's bounds; and 1-20 connector objects using only canonical `type2`, `ccs2`, or `chademo`. Optional connector power must be numeric in (0, 1000], optional count a positive integer <=1000, and optional charge-point count a positive integer <=1000. Reject malformed input with a clear generic validation error before any row or invite is written. Cap invitation email length at 254 while preserving the existing format check.

Build the stored station from the validated fields only, rather than keeping arbitrary extra JSON keys: canonical name/address/coordinate/operator/connectors/chargePointCount plus the server-controlled `private:` ID, `ownerProvided` source/attribution, `private` access, unknown availability, and null price. This bounds stored data and ensures a successful call produces a row the existing normalizer can display. Do not mutate historical rows or add a table constraint, because the current pgTAP RLS seed intentionally contains an invalid historical payload.

**Verify**: inspect the migration diff against the original RPC; no new direct INSERT grant or broadened RLS policy. Run the database test only if a disposable local database is confirmed.

### 3. Reconcile verification and documentation

Update `README.md` to state that private-site RPC input is validated server-side and that a configured project still needs hosted RLS verification. Run `git diff --check`, the Node suite if its runtime is available, and the disposable pgTAP suite if possible. If SQL runtime is unavailable, leave the work unverified and report the exact missing gate for CI.

**Verify**: `git status --short` lists only the scoped files plus pre-existing unrelated edits; `git diff --check` exits 0. The CI `database` job must pass after an authorized push/PR before this plan can be marked DONE.

## Test plan

- Invalid direct RPC payloads do not create a site or invitation.
- A valid iPhone-shaped payload succeeds and produces a discoverable, owner-visible canonical row.
- Caller-supplied `source`, `access`, `availability`, and `price` never survive server-side canonicalization.
- Existing invite/revocation favorite tests remain unchanged and pass.

## Done criteria

- [ ] New direct RPC pgTAP cases and exact CI count are in place.
- [ ] The RPC rejects malformed/oversized inputs before insertion and stores only validated fields.
- [ ] Existing `auth.uid()`, consent, invitation, RLS, and execute restrictions are not weakened.
- [ ] `git diff --check`, Node suite, and disposable database CI job pass.
- [ ] No files outside scope changed by this plan.

## STOP conditions

Stop and report if the RPC signature or normalizer acceptance rules have changed from the excerpts, if a valid iPhone submission fails under the new checks, if a step needs edits outside Scope, or if a verification gate fails twice after a reasonable correction. Never run `supabase db reset` against an unconfirmed local database.

## Maintenance notes

Keep the SQL canonical connector allowlist aligned with `ConnectorKind` and the Edge Function's `normalizePrivateSite`. If a future UI adds connector kinds or multi-connector private sites, update all three plus direct RPC tests. Hosted RLS and owner-permission verification remain release prerequisites; passing a mock or local pgTAP test is not proof of either in production.
