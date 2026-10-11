# hotspot-report — read-only diagnostics for auto-hotspot

A dependency-free Swift CLI that answers "what state does the auto-hotspot
controller actually see?" without touching anything: it reads the same files
`bin/hotspotd` reads, binds the effective values the controller would compute,
and renders them as terminal summary, JSON, or Markdown. It changes no
controller file, sends no packet, probes no network.

## Inputs (same bindings as bin/hotspotd)

| Input | Path |
|---|---|
| Config | `$AUTO_HOTSPOT_CONFIG` or `~/.config/auto-hotspot/config` |
| Log | `$AUTO_HOTSPOT_LOG` or `~/Library/Logs/auto-hotspot.log` |
| State dir | `$AUTO_HOTSPOT_STATE` or `~/.local/state/auto-hotspot` |
| Install paths | `$HOME`-derived (LaunchAgents plist, agent binary) |

## Modes

```
swift build
.build/debug/hotspot-report                 # terminal summary (redacted)
.build/debug/hotspot-report --json          # machine-readable envelope (redacted)
.build/debug/hotspot-report --markdown      # report tables (redacted)
.build/debug/hotspot-report bundle --output=/tmp/dir   # evidence bundle (opt-in)
```

Flags: `--clock=<ts>` pins time (`2026-10-11T04:31:00Z` or
`2026-10-11T06:31:00+0200`) for deterministic replay; `--redacted=false`
(bundle only) opts into unredacted log prose; `--help`, `--version`.

## What the JSON tells you

Every config key, `agent.status` field, and state file binds to one of five
explicit states — `present`, `missing` (with the controller default),
`malformed` (with the value the controller would fall back to), `stale` (past
the 600 s freshness rule), or `unparsed` — plus per-file line counts
(accepted / refused / ignored). Effective values match the controller:
bare config keys sourced by `load_config` (defaults include the SSID
'Andrew’s iPhone' with U+2019, `ENABLED=1`, `NOTIFY=1`), agent-status
freshness from mtime with the embedded `updated` field as fallback, and the
lock's 4x-cooldown stale window with a 300 s floor.

## Redaction policy

- Default outputs: SSID values become `REDACTED`; log message text never
  appears.
- The bundle is the explicit opt-in for log prose. Even there, SSIDs the
  readers saw are redacted as whole phrases (a multi-word SSID leaves no
  fragments), and log lines that do not match the repo's
  `[ts] [level] message` shape are listed by line number, never exported —
  their provenance is unknown.
- Bundle files are written 0600, the bundle directory 0700.

## Determinism

Same inputs plus `--clock` produce byte-identical JSON (verified: two runs,
identical sha256). Timestamps are parsed as written — UTC `Z` forms and
numeric-offset log stamps — with no locale or platform variance.

## Tests

```
swift test    # 45 tests: timestamp/JSON parsers, all four readers,
              # redaction (phrase-level), end-to-end bundle evidence
```

## Known limits

- Rotated log (`.1`) is noted, not read.
- No live Wi-Fi state beyond what the agent already recorded.
- On non-macOS hosts, install-path checks reflect the filesystem as mounted,
  not launchd reality.
- Never runs or modifies the controller; report-only.
