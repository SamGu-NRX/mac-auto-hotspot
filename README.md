# mac-auto-hotspot

A signed menu bar app that watches your network state and, when the Mac goes offline, joins your
iPhone's Personal Hotspot. Comes with a CLI (`bin/hotspotd`) as the day-to-day front end. No sudo,
no Homebrew, no third-party dependencies.

## One thing you must do on the iPhone

**With the Personal Hotspot toggle OFF, no Mac software can wake it — not this tool, not any
other — without Accessibility access to the Wi-Fi menu, which this project deliberately does not
use.** A toggle-off hotspot only becomes joinable through Instant Hotspot, which is an iOS
Bluetooth/Wi-Fi handshake the phone initiates, not something a Mac can trigger from software.

So: on the iPhone, go to Settings → Personal Hotspot and leave **Allow Others to Join** enabled.
With that on, the phone advertises the hotspot over Bluetooth LE and starts broadcasting Wi-Fi the
moment a known Mac looks for it — which is what makes this tool's join attempts actually land.
Leave the toggle itself off; you don't need to switch it on by hand.

## Requirements

- macOS 26 (Tahoe) on Apple Silicon.
- The Swift toolchain to build the app once. `swiftc` ships with the Command Line Tools, not the
  full Xcode install.
- A Wi-Fi interface named `en0`.
- The hotspot already saved as a preferred network, so its password is in the system keychain.
  Verify with:

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
- `--interval <seconds>` — safety-net poll interval, in case the event-driven watcher misses a
  transition (default 300).
- `--cooldown <seconds>` — minimum gap between join attempts after a failure (default 30).
- `--router <ip>` — the iPhone's tethering gateway IP, used to verify a join actually succeeded
  (default `172.20.10.1`).
- `--no-load` — write config and the plist but don't bootstrap the agent.
- `--dry-run` — print what would happen, change nothing.

`install.sh` builds and ad-hoc signs `AutoHotspot.app`, installs it at the fixed path
`~/Applications/AutoHotspot.app` (outside the repo checkout, so moving or deleting the checkout
later doesn't break it), and writes a plist with `KeepAlive` + `RunAtLoad` and no periodic-timer key.
The app is a long-running process, not a periodic job.

## One-time Location Services prompt

The app asks for **When In Use** location access the first time it launches. This isn't optional
window dressing: on macOS 26, reading a real Wi-Fi SSID — even the one you're already associated
to — is gated behind that permission for every process, with no exception for background agents.
Without it, the app can still detect "online vs. offline" (that needs no permission) but can't scan
for or report the actual network name.

Approve the prompt once and it sticks, as long as the app's code signature doesn't change.
That's the catch: **an ad-hoc-signed rebuild rotates the signature's ad-hoc cdhash, and macOS treats
that as a new app — it silently revokes the Location grant and you'll be prompted again.**
`hotspotd menubar` (no flags) never rebuilds for exactly this reason; only `hotspotd menubar
--rebuild` does.

Without a code-signing certificate, `hotspotd menubar --rebuild` protects the grant a different
way: it hashes `menubar/AutoHotspot.swift`, `menubar/Wifi.swift`, and `menubar/Info.plist`, and
compares that against the fingerprint recorded after the last successful install. If they match —
and the installed app is still there — it skips the compile/sign/reinstall entirely and prints a
line saying so, instead of doing pointless work that would rotate the cdhash for no reason.
Rerunning `./install.sh` to fix something unrelated is safe: the app is untouched unless the
sources actually changed. `install.sh` prints "App bundle: preserved" or "App bundle: rebuilt"
near the end of its output so you know at a glance whether you'll need to re-approve Location.
Pass `--force` to `hotspotd menubar --rebuild --force` when you genuinely need to rebuild despite
unchanged sources (for example, after switching signing identities).

No code-signing certificate is needed. The fingerprint check is what keeps the grant alive: a
rebuild only happens when you actually change the source, so approving Location once covers every
reinstall, repair and re-run after that.

If you are editing the Swift sources many times a day and would rather not re-approve on each
build, a self-signed identity named `AutoHotspot Signing` (Keychain Access → Certificate
Assistant → Create a Certificate → Code Signing) is picked up automatically and keeps the grant
across rebuilds too. It is strictly optional.

## Usage

`hotspotd` is the only command you need day to day. `install.sh` symlinks it into the first
writable directory on your `PATH` (`~/.local/bin`, `/opt/homebrew/bin`, or `/usr/local/bin`), so
after installing you can call it from anywhere. Open a new shell or run `hash -r` first — zsh
caches command lookups. If no writable `PATH` directory exists, the installer says so and you call
`bin/hotspotd` by path instead.

| Subcommand | What it does |
|---|---|
| `on` | Enables auto-join: flips `ENABLED=1` in the config and runs `launchctl enable`. |
| `off` | Disables auto-join: flips `ENABLED=0` and runs `launchctl disable`. |
| `status` | Prints whether the agent is loaded, enabled, and its current state. Add `--json` for machine-readable output. |
| `check` | Runs one degraded-mode reachability/join check immediately (see below), outside the app's own loop. |
| `doctor` | Prints an OK/WARN/FAIL checklist covering install state, launchd, the watcher process, Location authorization, the saved SSID, Wi-Fi power, the current router, and the code signature. Run this first whenever a join isn't happening. |
| `logs` | Prints the log file. Add `-f` to follow it, `--open` to open it in the default app. |
| `install` | Runs the installer (same as `./install.sh`). |
| `uninstall` | Runs the uninstaller (same as `./uninstall.sh`). |
| `menubar` | Launches the already-installed app. Add `--rebuild` to compile, re-sign, and reinstall it first — this is skipped automatically when sources are unchanged since the last install (see above); add `--force` to rebuild anyway. |
| `agent load` | (Re)bootstraps the launchd agent from the existing plist, without recompiling or re-signing the app bundle. The safe way to recover a stopped agent — the repair the menu bar app itself runs when it needs one. |

`status --json` reports 16 keys: `enabled`, `agent_installed`, `agent_loaded`, `watcher_running`,
`location_authorized`, `online`, `ssid`, `ssid_current`, `interface`, `wifi_power`,
`check_interval`, `cooldown`, `hotspot_router`, `last_join_result`, `log_path`, `config_path`. All
16 exist for scripting and for `hotspotd doctor`; the menu bar app surfaces only what needs
acting on — see "Menu bar app" below.

`on` and `off` both flip the config flag and call `launchctl enable`/`disable`. Pausing or resuming
never requires a reinstall or rebuild.

## Configuration

Config lives at `~/.config/auto-hotspot/config` and is sourced as a shell file. Keys:

- `SSID` — hotspot network name. Default `Andrew’s iPhone`. The apostrophe is U+2019 (RIGHT SINGLE
  QUOTATION MARK), not the ASCII `'`. If you retype this SSID with an ASCII apostrophe, the join
  will silently fail to match your iPhone's actual network name.
- `CHECK_INTERVAL` — seconds between the app's safety-net poll, which only matters if the
  event-driven watcher (`NWPathMonitor` plus sleep/wake notifications) somehow misses a
  transition. Default 300. This is no longer a periodic launchd timer — the app is a persistent
  process and reacts to network changes within seconds, not on a fixed clock.
- `COOLDOWN` — minimum seconds between join attempts after a failure. Default 30 (lowered from an
  earlier 300s default, now that joins are triggered by real events instead of a slow poll).
- `ENABLED` — `1` or `0`. Whether the agent should act on a state change.
- `WIFI_INTERFACE` — Wi-Fi device name. Default `en0`.
- `HOTSPOT_ROUTER` — the iPhone tethering gateway IP. Default `172.20.10.1`. A join is only ever
  reported as successful when the interface's router matches this value AND the reachability
  probe succeeds — `networksetup`'s own exit code is not trusted (see below).
- `NOTIFY` — `1` or `0`. Whether the app posts a user notification on join/failure. Default 1.
- `HOTSPOTD_BIN` — absolute path to `bin/hotspotd`, written by `install.sh`. The app reads this to
  find the CLI.

Every key is picked up live — no reinstall or rebuild needed for a config change to take effect.

## How it works

The old design was a periodic launchd timer running a bare shell script on a fixed clock. That shape could
never really work on macOS 26: a script has no process identity to hold a Location Services grant,
so it can never see a real SSID, and it had no way to tell a genuine join from
`networksetup`'s false "success". The current design fixes both problems by turning the signed app
itself into the agent:

1. **launchd** loads `AutoHotspot.app` with `KeepAlive=true` and `RunAtLoad=true` — a persistent
   process, not a periodic invocation, and carries no timer key in the plist.
2. **The watcher**, running inside that process, reacts to four sources: `NWPathMonitor` path
   transitions, `NSWorkspace.didWakeNotification` on wake from sleep, a coalescing safety-net
   timer at `CHECK_INTERVAL`, and a trigger file the CLI can touch to force an immediate check.
   Reaction time to a real network change is on the order of seconds, not minutes.
3. **The join engine**, also inside that process, does `CLLocationManager` authorization once at
   first launch, then uses `CWInterface.scanForNetworks(withSSID:)` and `associateToNetwork:` —
   the only code path in this project that can see and join networks on macOS 26, because it's
   the only code path that can hold the Location grant.
4. **Verification is permission-free everywhere**: a join (or an existing connection) only counts
   as real when `ipconfig getoption en0 router` equals `HOTSPOT_ROUTER` *and* the captive-portal
   reachability probe succeeds. `networksetup`'s own exit code is never trusted — it returns 0
   whether the join actually happened or not.
5. **`bin/hotspotd`** stays Wi-Fi-free. It renders `status` by merging its own probe with
   `agent.status`, a JSON file the app writes with the fields only it can know (real SSID,
   `location_authorized`, `watcher_running`, `last_join_result`); flips `ENABLED`; and asks the
   running agent to act immediately by touching the trigger file.
6. **`libexec/auto-hotspot-check.sh`** is the degraded-mode fallback for when the app isn't
   running at all — reachability probing plus a best-effort `networksetup` join, verified against
   the same router-fingerprint check as the app, so it can never report a false success either.

## Logs

- `~/Library/Logs/auto-hotspot.log` — shared log for both the app and the fallback script,
  ISO-8601 timestamps with UTC offset. Rotates to `.log.1` once it hits 1 MB.
- `~/Library/Logs/auto-hotspot.launchd.out` and `.launchd.err` — launchd's own stdout/stderr
  capture for the agent process.

## Menu bar app

The app lives at `~/Applications/AutoHotspot.app`, built from `menubar/AutoHotspot.swift` and
`menubar/Wifi.swift`. `hotspotd menubar` launches the already-installed copy without touching it;
`hotspotd menubar --rebuild` recompiles, re-signs, and reinstalls it — see "One-time Location
Services prompt" above for why that distinction matters.

The menu is deliberately minimal: nothing to click when everything is healthy beyond the toggle
and Quit. Root menu, top to bottom:

1. A disabled status line — one sentence covering online/offline and, when known, the current or
   target SSID (e.g. "● Online — eduroam", "● Offline — auto-join paused").
2. Zero or more **problem rows**, present only while the condition they cover is true:
   - **Grant Location Access…** — Location Services isn't authorized, so the app can't read SSIDs
     and every join is blind. Opens the Privacy pane directly.
   - **Turn Wi-Fi On** — the radio is off. Turns it on in-process, no shell-out.
   - **Restart Background Agent** — the launchd agent isn't loaded or the watcher isn't running.
     Runs `hotspotd agent load`, which never rebuilds or re-signs the app, so the Location
     Services grant survives.
   - **Last Join Failed (\<result\>) — Open Log** — still offline after a failed join attempt.
     Opens the log, which names every SSID the scan actually saw.
3. **Auto-Join Hotspot** — a checkable toggle.
4. **Quit Auto Hotspot**.

Everything else — interface, check interval, cooldown, hotspot router, config path, log path,
target SSID, Check Now, in-app config editing — was cut. `hotspotd doctor` and
`hotspotd status --json` are the diagnostic surface now; see `docs/decisions/0002-minimal-menu.md`
for why.

The status item icon is `antenna.radiowaves.left.and.right` (slashed when auto-join is paused) —
chosen over `personalhotspot` and over `wifi`/`wifi.slash` (which reads as "your Wi-Fi is broken"
rather than "auto-join is off"). `iconOnSymbol`/`iconOffSymbol` at the top of `AutoHotspot.swift`
are the single point of change if the glyph ever needs to change again.

To have it start at login, add `~/Applications/AutoHotspot.app` to Login Items yourself; the
installer doesn't do this for you.

## Uninstall

```
./uninstall.sh
```

Add `--purge` to also remove the config, state directory, and logs.

## Troubleshooting

Run `hotspotd doctor` first — it checks install state, launchd, the watcher process, Location
authorization, the saved SSID, Wi-Fi power, the current router, and the code signature in one
pass, and tells you exactly which one is failing.

- **Is the agent loaded?**

```
launchctl print gui/$(id -u)/com.andrewwang.autohotspot
```

Exit code 113 means it isn't loaded.

- **`airport` command not found.** The legacy `airport` binary no longer exists on macOS 26. This
  project doesn't use it.
- **`wdutil info` needs sudo.** This project avoids sudo entirely, so it doesn't use `wdutil`
  either.
- **`networksetup -getairportnetwork en0` says "You are not associated with an AirPort network."**
  Normal on macOS 26 even while genuinely connected — SSID visibility there is gated behind
  Location Services for every process. This is exactly why the join engine lives in the signed
  app rather than a plain script.
- **The menu bar shows `ssid_current` as `<redacted>`.** Same cause: something (usually
  `ipconfig getsummary`) is reading the SSID without the Location grant. Check `location_authorized`
  in `status --json` — if it's `false`, re-launch the app and approve the prompt.
- **Location keeps re-prompting after every rebuild.** Ad-hoc signatures rotate their cdhash on
  every build, so each rebuild is a new app identity. Normally you never see this, because
  `install.sh` skips the rebuild while the sources are unchanged — if you are seeing it repeatedly,
  something is changing the fingerprint inputs (the two Swift files or `Info.plist`) between runs.
- **Join fails with a privileges complaint in the log.** Join the hotspot once by hand from the
  Wi-Fi menu. That stores the credential for your user account, after which the app's join will
  work.
- **Nothing joins even though the phone is nearby.** Check "Allow Others to Join" on the iPhone
  (see the top of this README) — with it off, no amount of software on the Mac side can wake the
  hotspot.
- **A join fails with `not_found` even though the toggle still looks on.** iOS silently stops
  broadcasting Personal Hotspot roughly 90 seconds after the last client disconnects, regardless
  of what the toggle shows. In the log this looks like a full sweep that found dozens of networks
  and zero matches for the target SSID. Reconnect once from the iPhone, or just open the Personal
  Hotspot screen, before testing — either wakes the broadcast back up.

## License

MIT. See `LICENSE`.
