# 3. Config parsing is last-assignment-wins for every key, and the shared contract lives in the portable core

## Status

Accepted.

## Context

The runtime config (`~/.config/auto-hotspot/config`) was parsed twice in the original code:
the shell worker sourced it (so every key — including `SSID` — took its **last** assignment,
matching shell sourcing semantics), while the menubar app's `targetSSID()` took the **first**
`SSID=` line it saw. The same file, two different answers, depending on which agent read it.
The controller/CLI extraction made this impossible to keep: `core/HotspotCore` is now the single
parser both agents share, so one policy has to be chosen.

A duplicate `SSID=` line is the realistic case — a config writer that appends instead of
rewriting, a user hand-editing below an existing block — and shell sourcing (the behavior
`bin/hotspotd` and `libexec/auto-hotspot-check.sh` inherit) resolves it to the last value.

## Decision

`RuntimeConfig` parses every key last-assignment-wins, `SSID` included. Duplicate lines are not
an error and do not abort parsing; the final assignment for each key is the effective one.
The policy is pinned by `ConfigParsingTests.testLastAssignmentWinsForSSID`.

## Consequences

- The menubar app now agrees with the shell worker on every config file, including ones with
  duplicated keys. The one behavior change (first→last for a duplicated `SSID`) affects only
  files that were already ambiguous between the two agents.
- The parser contract (last-wins, empty values tolerated, malformed numbers fall back to the
  built-in default, unknown keys and comments ignored) is exercised by the portable test suite,
  which runs on Linux where the core is developed and tested.
- The macOS-specific probes (curl reachability, `ipconfig` router read, CoreWLAN join) stay in
  the menubar app as glue behind `ControllerEffects`; the decision logic itself keeps no
  framework or network dependency (enforced by `GuardTests`).
