# CLAUDE.md

Guidance for agents working in this repo.

## Layout

- `bin/hotspotd` — the CLI. This is the only user-facing entry point. It touches no Wi-Fi: it
  renders `status` by merging its own probe with the app's `agent.status`, flips `ENABLED`, and
  pokes the running agent via the trigger file.
- `menubar/AutoHotspot.swift` + `menubar/Wifi.swift` — the app. This IS the agent now: launchd
  runs it directly (`KeepAlive`, no periodic-timer key in the plist). `Wifi.swift` is the only code in the repo
  that associates to a Wi-Fi network (`CWInterface.scanForNetworks`/`associateToNetwork:`) and the
  only code that can hold the Location Services grant SSID reads require on macOS 26.
  `AutoHotspot.swift` owns the watcher (`NWPathMonitor`, wake notifications, safety-net timer,
  trigger-file source) and the menu bar UI.
- `libexec/auto-hotspot-check.sh` — the degraded-mode fallback, used only when the app isn't
  running. It must never claim a join succeeded without verifying it: `networksetup`'s exit code
  is worthless, so it checks the DHCP router fingerprint (`HOTSPOT_ROUTER`) plus a reachability
  probe before reporting success.
- `share/*.plist.template` — the LaunchAgent plist template, with `__PLACEHOLDER__` tokens that
  `install.sh` fills in. `ProgramArguments` points at the installed app's Mach-O executable, not a
  script.
- `install.sh` / `uninstall.sh` — setup and teardown. `install.sh` builds, signs, and installs the
  app bundle to `~/Applications/AutoHotspot.app`, outside this checkout.
- `build/` — generated output (the compiled app bundle, before it's installed to
  `~/Applications`). Gitignored.
- `tools/` — one-off dev scripts (e.g. the icon contact-sheet generator). Never compiled into the
  app and never run by `install.sh`, `bin/hotspotd`, or the plist.

## Hard rules

- No sudo anywhere, in any script.
- No Homebrew, no third-party dependencies. Everything is stock macOS tools plus Swift's standard library.
- bash 3.2 compatible: `#!/bin/bash`, no bash-4-only syntax (no associative arrays, no `mapfile`, no `${var,,}`).
- The repo path contains a space. Quote every path expansion, everywhere, no exceptions.
- UTF-8 everywhere. The SSID contains U+2019 (RIGHT SINGLE QUOTATION MARK); don't let an editor or shell normalize it to ASCII `'`.
- Only `menubar/Wifi.swift` associates to networks. `libexec/auto-hotspot-check.sh` is the
  degraded-mode fallback and must never claim a success it did not verify against the router
  fingerprint. `bin/hotspotd` never touches Wi-Fi at all — it reads the app's `agent.status` and
  pokes the trigger file.

## Shared contract

These five files must agree, and any change to one of these values must land in all five at once: `bin/hotspotd`, `libexec/auto-hotspot-check.sh`, `share/*.plist.template`, `install.sh`, `menubar/AutoHotspot.swift` (+ `menubar/Wifi.swift`).

| Item | Value |
|---|---|
| launchd label | `com.andrewwang.autohotspot` |
| plist path | `~/Library/LaunchAgents/com.andrewwang.autohotspot.plist` |
| installed app bundle | `~/Applications/AutoHotspot.app` (outside the repo checkout, so the code signature — and the Location Services grant keyed to it — survives moving or deleting the checkout) |
| config path | `~/.config/auto-hotspot/config` |
| log path | `~/Library/Logs/auto-hotspot.log` |
| state dir | `~/.local/state/auto-hotspot/` |
| state dir contents | `last-join-attempt` (cooldown timestamp), `lock/` (mkdir-based lock), `trigger` (CLI touches this to poke the running agent into an immediate check), `agent.status` (JSON the app writes; the CLI's only source for fields it can't probe itself) |
| launchd domain | `gui/$(id -u)` |
| config keys | `SSID`, `CHECK_INTERVAL` (default 300, a safety-net poll interval inside the app — not a periodic launchd job), `COOLDOWN` (default 30), `ENABLED`, `WIFI_INTERFACE`, `HOTSPOT_ROUTER` (default `172.20.10.1`, the iPhone tethering gateway IP a join is verified against), `NOTIFY`, `HOTSPOTD_BIN` |

`status --json` key set (16 keys): `enabled`, `agent_installed`, `agent_loaded`,
`watcher_running`, `location_authorized`, `online`, `ssid`, `ssid_current`, `interface`,
`wifi_power`, `check_interval`, `cooldown`, `hotspot_router`, `last_join_result`, `log_path`,
`config_path`. `watcher_running`, `location_authorized`, and `last_join_result` come from the
app's `agent.status`, not from anything `bin/hotspotd` probes itself.

## Commands

```
./install.sh --dry-run
bin/hotspotd status --json
AUTO_HOTSPOT_FORCE=1 libexec/auto-hotspot-check.sh
bin/hotspotd agent load   # (re)bootstrap the launchd agent without rebuilding or re-signing it
bash -n <script>          # syntax-check every shell file before committing
swiftc -O -o build/AutoHotspot menubar/AutoHotspot.swift menubar/Wifi.swift
plutil -lint <rendered-plist>
```

Env overrides for testing without touching the real install: `AUTO_HOTSPOT_CONFIG`, `AUTO_HOTSPOT_LOG`, `AUTO_HOTSPOT_STATE`, `AUTO_HOTSPOT_FORCE`.

## Gotchas

- `launchctl load`/`unload` are deprecated. Use `bootstrap`/`bootout`.
- `launchctl bootout` exits 3 when nothing is loaded. Don't treat that as a failure.
- `launchctl print` exits 113 when the service is unknown to launchd.
- A prior `launchctl disable` blocks `bootstrap` from loading the agent again until `launchctl enable` runs first.
- `KeepAlive` can't coexist with a periodic timer key in the same plist. The current plist uses
  `KeepAlive` only — the app is a persistent process with its own internal safety-net timer, not
  a periodic launchd job.
- Ad-hoc `codesign` on the app bundle is mandatory. Without it, macOS refuses to launch the app.
  But an ad-hoc signature's cdhash rotates on every rebuild, which macOS treats as a new app
  identity and silently revokes the Location Services grant — that's why `hotspotd menubar` with
  no flags never rebuilds, and why a stable, user-created `AutoHotspot Signing` identity (see
  `security find-identity`) is preferred over ad-hoc whenever one exists.
- `LSUIElement` in `Info.plist` is what hides the Dock icon for the app.
- `networksetup -setairportnetwork` exits 0 whether the join succeeded or failed. Its exit code
  must never be trusted; parse its stdout and, more importantly, verify the outcome against the
  DHCP router fingerprint (`ipconfig getoption en0 router` == `HOTSPOT_ROUTER`) plus a reachability
  probe.
- `ipconfig getsummary` prints `SSID : <redacted>` while genuinely associated, because SSID is
  gated behind Location Services on macOS 26 for every process that hasn't been granted it —
  there's no background-agent exception. A bare shell script run by launchd can never hold that
  grant; that's the whole reason the join engine had to move into the signed app.
- `CWConfiguration.networkProfiles` is NOT Location-gated — it's the reliable way to read the list
  of saved SSIDs (e.g. to confirm the target hotspot is already a preferred network) without
  needing authorization first.
- `scutil -w <key>` returns immediately if the key already exists at the moment it's invoked, and
  macOS 26's `scutil` dropped `n.wait`. Never build a shell-based network watcher on `scutil` —
  it can't block-and-wait for a *future* transition the way this needs; that's a real reason (not
  just a style preference) the watcher lives in `NWPathMonitor` inside the Swift process instead.

## Commits

Conventional Commits (`feat`, `fix`, `docs`, `chore`, …), imperative mood, lowercase subject, no AI attribution trailers.

## Menu bar app conventions

- `NSMenu.autoenablesItems` must stay `false` on both the root menu and the Settings submenu.
  AppKit's auto-validation overrides any manual `isEnabled`, which silently breaks caption rows
  and the busy state during `Check Now`.
- Caption and settings rows are rendered with an explicit `attributedTitle` (secondary colour,
  small system font) rather than relying on the disabled-item appearance, which renders washed out.
- The status item icon uses `personalhotspot` / `personalhotspot.slash` — a placeholder pending
  the pick from the icon contact sheet (`tools/icon-contact-sheet.swift`, see `build/`). `wifi` /
  `wifi.slash` was tried and rejected: that pair reads as "your Wi-Fi is broken" rather than
  "auto-join is off". `iconOnSymbol` / `iconOffSymbol` at the top of `AutoHotspot.swift` are the
  single point of change once a final glyph is chosen.
- Entry point is `app.run()`, not `NSApplicationMain`, since there is no nib and the delegate is
  assigned by hand.
- The root menu is a status line, problem rows, the Auto-Join Hotspot toggle, and Quit — nothing
  else. A new `status --json` key earns a menu row only if it produces a problem the user can
  click to fix; everything informational belongs in `hotspotd doctor`.
- The menu must never shell out to `hotspotd install` or `hotspotd menubar --rebuild` — either one
  re-signs the app bundle, which rotates the ad-hoc cdhash and revokes the Location Services
  grant. `hotspotd agent load` is the safe repair path: it bootstraps the existing plist without
  touching the binary or its signature.

## PATH symlink

`install.sh` links `bin/hotspotd` into the first writable directory on `PATH`. `uninstall.sh`
removes it only when `readlink` confirms it points back into this checkout — never delete a
`hotspotd` on `PATH` without that check.
