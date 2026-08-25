# CLAUDE.md

Guidance for agents working in this repo.

## Layout

- `bin/hotspotd` — the CLI. This is the only user-facing entry point; scripts and the menu bar app all go through it.
- `libexec/auto-hotspot-check.sh` — the only file that touches Wi-Fi. Reachability probing, joining, cooldown, and locking all live here.
- `share/*.plist.template` — the LaunchAgent plist template, with `__PLACEHOLDER__` tokens that `install.sh` fills in.
- `menubar/` — Swift source and `Info.plist` for the menu bar app. No build logic lives here; that's `bin/hotspotd menubar`.
- `install.sh` / `uninstall.sh` — setup and teardown.
- `build/` — generated output (the compiled app bundle). Gitignored.

## Hard rules

- No sudo anywhere, in any script.
- No Homebrew, no third-party dependencies. Everything is stock macOS tools plus Swift's standard library.
- bash 3.2 compatible: `#!/bin/bash`, no bash-4-only syntax (no associative arrays, no `mapfile`, no `${var,,}`).
- The repo path contains a space. Quote every path expansion, everywhere, no exceptions.
- UTF-8 everywhere. The SSID contains U+2019 (RIGHT SINGLE QUOTATION MARK); don't let an editor or shell normalize it to ASCII `'`.
- The menu bar app never duplicates CLI logic. It only shells out to `bin/hotspotd`.

## Shared contract

These five files must agree, and any change to one of these values must land in all five at once: `bin/hotspotd`, `libexec/auto-hotspot-check.sh`, `share/*.plist.template`, `install.sh`, `menubar/AutoHotspot.swift`.

| Item | Value |
|---|---|
| launchd label | `com.andrewwang.autohotspot` |
| plist path | `~/Library/LaunchAgents/com.andrewwang.autohotspot.plist` |
| config path | `~/.config/auto-hotspot/config` |
| log path | `~/Library/Logs/auto-hotspot.log` |
| state dir | `~/.local/state/auto-hotspot/` |
| launchd domain | `gui/$(id -u)` |

`status --json` key set: `enabled`, `agent_loaded`, `online`, `ssid`, `ssid_current`, `interface`, `wifi_power`, `check_interval`, `cooldown`, `log_path`.

## Commands

```
./install.sh --dry-run
bin/hotspotd status --json
AUTO_HOTSPOT_FORCE=1 libexec/auto-hotspot-check.sh
bash -n <script>          # syntax-check every shell file before committing
swiftc -O -o build/AutoHotspot menubar/AutoHotspot.swift
plutil -lint <rendered-plist>
```

Env overrides for testing without touching the real install: `AUTO_HOTSPOT_CONFIG`, `AUTO_HOTSPOT_LOG`, `AUTO_HOTSPOT_STATE`, `AUTO_HOTSPOT_FORCE`.

## Gotchas

- `launchctl load`/`unload` are deprecated. Use `bootstrap`/`bootout`.
- `launchctl bootout` exits 3 when nothing is loaded. Don't treat that as a failure.
- `launchctl print` exits 113 when the service is unknown to launchd.
- A prior `launchctl disable` blocks `bootstrap` from loading the agent again until `launchctl enable` runs first.
- `KeepAlive` and `StartInterval` can't coexist in the same plist.
- Ad-hoc `codesign` on the menu bar app bundle is mandatory. Without it, macOS refuses to launch the app.
- `LSUIElement` in `Info.plist` is what hides the Dock icon for the menu bar app.

## Commits

Conventional Commits (`feat`, `fix`, `docs`, `chore`, …), imperative mood, lowercase subject, no AI attribution trailers.
