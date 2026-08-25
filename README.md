# mac-auto-hotspot

A launchd LaunchAgent that polls internet reachability and, when the Mac is offline, joins your saved iPhone hotspot. Comes with a CLI (`bin/hotspotd`) and an optional menu bar toggle. No sudo, no Homebrew, no Xcode.

## Requirements

- macOS 26 (Tahoe) on Apple Silicon.
- The Swift toolchain, only if you build the menu bar app. `swiftc` ships with the Command Line Tools, not the full Xcode install.
- A Wi-Fi interface named `en0`.
- The hotspot already saved as a preferred network, so its password is in the system keychain. Verify with:

```
networksetup -listpreferredwirelessnetworks en0
```

If your hotspot SSID isn't in that list, join it once by hand first.

## Install

```
git clone <repo-url> mac-auto-hotspot
cd mac-auto-hotspot
./install.sh
```

Flags:

- `--ssid <name>` — hotspot SSID to join (default `Andrew’s iPhone`).
- `--interval <seconds>` — how often to check reachability (default 120).
- `--cooldown <seconds>` — minimum gap between join attempts (default 300).
- `--no-load` — write config and the plist but don't bootstrap the agent.
- `--dry-run` — print what would happen, change nothing.

`install.sh` sets `RunAtLoad` in the plist, so the first reachability check runs immediately once the agent loads, not after the first interval.

## Usage

`bin/hotspotd` is the only command you need day to day.

| Subcommand | What it does |
|---|---|
| `on` | Enables the agent: flips `ENABLED=1` in the config and runs `launchctl enable`. |
| `off` | Disables the agent: flips `ENABLED=0` and runs `launchctl disable`. |
| `status` | Prints whether the agent is loaded, enabled, and when it last ran. Add `--json` for machine-readable output. |
| `check` | Runs one reachability check immediately, outside the schedule. |
| `logs` | Prints the log file. Add `-f` to follow it, `--open` to open it in the default app. |
| `install` | Runs the installer (same as `./install.sh`). |
| `uninstall` | Runs the uninstaller (same as `./uninstall.sh`). |
| `menubar` | Builds and launches the menu bar toggle app. |

`on` and `off` both flip the config flag and call `launchctl enable`/`disable`. Pausing or resuming the agent never requires a reinstall.

## Configuration

Config lives at `~/.config/auto-hotspot/config` and is sourced as a shell file. Keys:

- `SSID` — hotspot network name. Default `Andrew’s iPhone`. The apostrophe is U+2019 (RIGHT SINGLE QUOTATION MARK), not the ASCII `'`. If you retype this SSID with an ASCII apostrophe, the join will silently fail to match your iPhone's actual network name.
- `CHECK_INTERVAL` — seconds between checks. Default 120.
- `COOLDOWN` — minimum seconds between join attempts after a failure. Default 300.
- `ENABLED` — `1` or `0`. Whether the agent should act on a check.
- `WIFI_INTERFACE` — Wi-Fi device name. Default `en0`.
- `HOTSPOTD_BIN` — absolute path to `bin/hotspotd`, written by `install.sh`. The menu bar app reads this to find the CLI.

Changing `CHECK_INTERVAL` requires re-running `./install.sh`, because the interval is baked into the launchd plist. Every other key is picked up on the next scheduled check, no reinstall needed.

## How the check works

Each run does a reachability probe, because a bare ping or open port isn't enough to prove real internet access:

1. `nc -z -G 3 1.1.1.1 53` — routed for the log line only; its result doesn't decide anything on its own.
2. `curl -sS -m 4 http://captive.apple.com/hotspot-detect.html` — the response body must contain `<TITLE>Success</TITLE>`. A bare HTTP 200 isn't accepted, because captive portals also return 200 with a login page as the body. This check alone decides online vs. offline.

If the probe reports offline, the script:

1. Makes sure Wi-Fi power is on.
2. Runs `networksetup -setairportnetwork en0 "$SSID"` with no password argument — the keychain supplies it.
3. Waits 5 seconds for the join to settle.
4. Re-probes up to 3 times.

A cooldown timestamp at `~/.local/state/auto-hotspot/last-join-attempt` limits failed joins to one attempt per `COOLDOWN` seconds, so a persistently unreachable hotspot doesn't get hammered. A `mkdir`-based lock directory prevents two runs from overlapping.

## Logs

- `~/Library/Logs/auto-hotspot.log` — the script's own log, ISO-8601 timestamps with UTC offset. Rotates to `.log.1` once it hits 1 MB.
- `~/Library/Logs/auto-hotspot.launchd.out` and `.launchd.err` — launchd's own stdout/stderr capture for the agent.

## Menu bar app

`bin/hotspotd menubar` compiles `menubar/AutoHotspot.swift` with `swiftc`, bundles the result into `build/AutoHotspot.app`, ad-hoc signs it with:

```
codesign --force --deep --sign - build/AutoHotspot.app
```

strips the quarantine attribute, and launches it. The app has no logic of its own — it shells out to `hotspotd` for every action. To have it start at login, add it to Login Items yourself; the installer doesn't do this for you.

## Uninstall

```
./uninstall.sh
```

Add `--purge` to also remove the config, state directory, and logs.

## Troubleshooting

- **Is the agent loaded?**

```
launchctl print gui/$(id -u)/com.andrewwang.autohotspot
```

Exit code 113 means it isn't loaded.

- **`airport` command not found.** The legacy `airport` binary no longer exists on macOS 26. This project doesn't use it.
- **`wdutil info` needs sudo.** This project avoids sudo entirely, so it doesn't use `wdutil` either.
- **`networksetup -getairportnetwork en0` says "You are not associated with an AirPort network."** That's normal when Wi-Fi is idle or on Ethernet, not an error condition.
- **Join fails with a privileges complaint in the log.** Join the hotspot once by hand from the Wi-Fi menu. That stores the credential for your user account, after which the script's join will work.

## License

MIT. See `LICENSE`.
