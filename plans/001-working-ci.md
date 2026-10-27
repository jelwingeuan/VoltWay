# Plan 001: Make CI run VoltWay's real iOS and backend suites

> **Executor instructions**: Follow the steps and gates below. Update this plan's status in `plans/README.md` when done. Do not push or open a PR unless the operator asks.
>
> **Drift check (run first)**: `git diff --stat 093cd1d -- .github/workflows/swift.yml && git status --short`
> If these files changed, compare the excerpts below with the current files. Stop on a mismatch affecting this plan.

## Status

- **Priority**: P1
- **Effort**: S–M
- **Risk**: MED — runner images and simulator inventories can change.
- **Depends on**: none
- **Category**: dx, tests
- **Planned at**: commit `093cd1d`, 2026-10-27

## Why this matters

The sole GitHub Actions job runs Swift Package Manager commands against an Xcode-only app. It cannot exercise the iOS tests and never runs the existing Node backend tests. Make a push or PR provide a real regression gate before taking the higher-risk data changes in later plans.

## Current state

- `.github/workflows/swift.yml:15-22` uses `runs-on: macos-latest`, then `swift build -v` and `swift test -v`.
- `VoltWay.xcodeproj/project.pbxproj:51-57` defines `VoltWay` and `VoltWayTests` native targets; there is no `Package.swift`.
- `README.md:56-60` gives the actual commands:
  ```sh
  xcodebuild -project VoltWay.xcodeproj -scheme VoltWay -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
  node --test supabase/functions/stations/*.test.mjs supabase/functions/sync-ocm/*.test.mjs supabase/functions/sync-mevnet/*.test.mjs
  ```
- `.gitignore:2-4` ignores `DerivedData/`, `build/`, and Xcode user data. Match the existing two-space YAML indentation and short workflow style.
- As of this plan's date, GitHub's [xcode-27 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) lists Xcode 27.0, Node 24, and an iPhone 18 Pro simulator. Recheck the image when executing; it is a preview image and can change.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Check project/scheme | `xcodebuild -list -project VoltWay.xcodeproj` | `VoltWay` scheme and `VoltWayTests` target listed |
| iOS tests | `xcodebuild -project VoltWay.xcodeproj -scheme VoltWay -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO test` | exit 0, test summary has no failures |
| Backend tests | `node --test supabase/functions/stations/*.test.mjs supabase/functions/sync-ocm/*.test.mjs supabase/functions/sync-mevnet/*.test.mjs` | exit 0, zero failures |
| Diff check | `git diff --check` | exit 0, no whitespace errors |

## Scope

**In scope**: `.github/workflows/swift.yml` only; `plans/README.md` status row.

**Out of scope**: app, Edge Functions, SQL migrations, test sources, deployment credentials, CarPlay entitlement. Do not add Supabase secrets to CI: these tests run against demo/mock fixtures.

## Git workflow

- Work on `codex/001-working-ci` if a branch is required by the operator. Recent messages use conventional commits such as `fix: improve Explore and saved charger reliability`.
- Commit only with operator authorization; do not push or open a PR unless instructed.

## Steps

### Step 1: Replace SwiftPM commands with the Xcode test command

Use the `xcode-27` runner label, print `xcodebuild -version` and `xcrun simctl list devices available`, and run the exact iOS test command above. Explicitly set `CODE_SIGNING_ALLOWED=NO`; do not request signing secrets. Keep the trigger on `main` push and PR.

**Verify**: `rg -n 'swift build|swift test|xcodebuild|runs-on|CODE_SIGNING_ALLOWED' .github/workflows/swift.yml` → no `swift build`/`swift test`; shows `xcode-27`, `xcodebuild ... test`, and `CODE_SIGNING_ALLOWED=NO`.

### Step 2: Add the backend regression step

Run Node 24 and the exact documented `node --test` glob command. The image currently includes Node 24; either assert `node --version` begins with `v24.` or use an official `actions/setup-node` step pinned to major version 24. Do not install application packages; none are declared.

**Verify**: `rg -n 'node --version|setup-node|node --test|supabase/functions' .github/workflows/swift.yml` → Node 24 selection/check and all three test globs appear.

### Step 3: Run and report the gates

Run the two suite commands from the table on an Xcode 27 host with a working iPhone simulator. If local CoreSimulator is unavailable, do not report iOS tests as passed: push the branch only when authorized and use the GitHub Actions run as the authoritative runtime gate.

**Verify**: `git diff --check` → exit 0. Then obtain a completed GitHub Actions run for the new workflow after operator-authorized push/PR; both iOS and Node steps must be green.

## Test plan

- No new product tests are required; this plan makes existing `VoltWayTests` and Node suites execute in CI.
- Confirm the workflow has no `continue-on-error` on either suite and that both commands are separate required steps. The first authorized push/PR is the runtime CI check.

## Done criteria

- [ ] Workflow uses Xcode 27 / an iPhone 18 Pro simulator and no SwiftPM command.
- [ ] Workflow runs all three existing Node test glob groups with Node 24.
- [ ] `git diff --check` exits 0.
- [ ] A completed Actions run after an authorized push/PR reports both suites green; until then status remains IN PROGRESS.
- [ ] No files outside scope (other than this plan index) changed.

## STOP conditions

- The Xcode image no longer includes a suitable iPhone simulator or Xcode 27. Check the official image inventory and report the replacement, rather than guessing a destination.
- The `VoltWay` scheme is not shared or `xcodebuild -list` does not show it.
- A test fails for a product-code reason; this plan does not authorize app/backend fixes.
- The only path to a green job requires signing credentials or live Supabase secrets.

## Maintenance notes

Review the runner image inventory when upgrading Xcode or the deployment target. The workflow must remain paired with the test commands in `README.md`; later UI tests should join this same Xcode gate.
