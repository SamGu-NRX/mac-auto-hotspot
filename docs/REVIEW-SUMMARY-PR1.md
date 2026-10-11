# mac-auto-hotspot portable core — PR #1 review summary

**PR:** https://github.com/SamGu-NRX/mac-auto-hotspot/pull/1 (draft, open)
**Branch:** `obv/products-l4-hotspot-controller-lifecycle-20261010` → `main` (base `c9c5b09`)
**Head:** `e243fb5` · **Review outcome:** Human review approved 2026-10-10 23:37 UTC with no feedback (task `todo_K6PiySyz` completed). Draft PR left open per project policy.

## What was delivered

The Watcher decision tree (disable check, lock, online gate, cooldown, Wi-Fi power, join, router-fingerprint + interface-bound verification, notification, status writes, force-rejoin latch) moved into a new portable Swift package `core/HotspotCore` behind a `ControllerEffects` protocol. The menubar app keeps only macOS glue (curl probe, `ipconfig` router read, CoreWLAN join) as `SystemEffects`; `Watcher.performEvaluation` delegates to `Controller.evaluate`. Shared paths, runtime-config parsing, state files, logging, and agent-status writing live in the core so `hotspotd` and the app share one contract.

Two milestones committed and pushed, both verified on the remote via the GitHub API:

- `0cf7d21` — `refactor(core): extract dependency-free controller lifecycle into a portable Swift package` (core package, recorder, guard/lifecycle/config/state tests, app integration)
- `e243fb5` — `docs: record the last-wins config contract and the core/app split as ADR 3`

Both authored by Sam Gu <127461594+SamGu-NRX@users.noreply.github.com> with the `obvious-autobuild[bot]` co-author trailer, confirmed on the remote commits before and after push.

## Verification (all mock-only, Linux sandbox)

- `swift test` (Swift 6.4 toolchain, Ubuntu): **39/39 HotspotCore tests pass, 0 failures**. The recording effects implementation refuses any effect a test did not allow, so every lifecycle scenario asserts its exact system-call surface — disabled and lock-busy states assert no probe ran; join stays a refusal until the online gate and verification allow it.
- Guard test keeps framework names, network, and file-system dependencies out of the core; it caught and rejected framework tokens in controller comments during development.
- `bash -n` passes on `bin/hotspotd` and `libexec/auto-hotspot-check.sh`.
- Static integration check: `SystemEffects` implements all 16 `ControllerEffects` methods; Watcher delegates to `Controller.evaluate`; no stale references to the moved logic. `loadRuntimeConfig()` is a free function in HotspotCore (not an effect), so the protocol surface is exactly the 16 methods.
- PR body's `## Handoff` section confirmed present on the remote PR.

## Compatibility contract (ADR 3)

Config parsing is last-assignment-wins for **every** key including `SSID`, matching shell sourcing semantics. Previously the menubar app's `targetSSID()` took the first `SSID=` line while the shell worker took the last; files with duplicated keys now resolve consistently across both agents. Documented in `docs/decisions/0003-config-parsing-and-portable-core.md` and pinned by `ConfigParsingTests.testLastAssignmentWinsForSSID`.

## Deferred (recorded in the PR Handoff)

- macOS-host compile of the menubar app — not possible on the Linux sandbox (AppKit/CoreWLAN unavailable); integration is verified statically.
- Live smoke of the join flow — no live Wi-Fi, scan, power change, permission request, or agent install was performed at any point.
- No merges; nothing touched on `main`; no workflow, deployment, or repository-settings changes.
