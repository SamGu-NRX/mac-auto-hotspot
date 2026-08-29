# 1. The signed app is the agent; the shell script is a fallback

## Status

Accepted.

## Context

The original design ran a bare shell script (`libexec/auto-hotspot-check.sh`) from a launchd
`StartInterval` timer. On macOS 26 this cannot work, for two independent reasons found on the live
machine:

1. **SSID reads are gated behind Location Services, per-process, with no background-agent
   exception.** `networksetup -getairportnetwork en0` reports "not associated" and
   `system_profiler SPAirPortDataType` prints `<redacted>` even while `en0` holds a real IP and
   owns the default route. TCC authorization is granted to a specific signed process identity —
   there is no way for a plain shell script invoked by launchd to hold that grant, because a
   script has no stable code-signing identity of its own to grant it to.
2. **`networksetup -setairportnetwork` exits 0 regardless of outcome.** The log showed
   `join output: Could not find network Andrew's iPhone` immediately followed by `join rc=0`,
   which the old script read as success. Any design that trusts that exit code produces false
   positives.

Reason 1 forces the join logic into something that can hold a TCC grant: a signed app, not a
script. Reason 2 forces independent verification of every join, regardless of where the join logic
lives.

## Decision

Turn the signed Swift menu bar app into the agent itself. `AutoHotspot.app` is installed at a
fixed path (`~/Applications/AutoHotspot.app`, outside the repo checkout) and launchd runs it
directly with `KeepAlive=true` / `RunAtLoad=true` and no `StartInterval`. One process holds all
three responsibilities that used to be split or missing:

- **The watcher** — `NWPathMonitor` for path transitions, `NSWorkspace.didWakeNotification` for
  sleep/wake, a coalescing safety-net timer, and a trigger file the CLI can touch.
- **The join engine** (`Wifi.swift`) — `CLLocationManager.requestWhenInUseAuthorization()` once at
  first launch, then `CWInterface.scanForNetworks(withSSID:)` / `associateToNetwork:`. This is the
  only code path in the repo that can see and join networks on macOS 26, because it's the only
  code path that holds the Location grant.
- **The menu bar UI** — unchanged in function.

All three live in one process because TCC authorization is scoped to process identity (via the
code signature's designated requirement). Splitting the watcher, the join engine, and the UI into
separate processes would mean juggling multiple TCC subjects for one logical agent, with no benefit.

`bin/hotspotd` is demoted to a Wi-Fi-free CLI: it renders `status` by merging its own probe with
`agent.status` (JSON the app writes), flips `ENABLED`, and pokes the running agent via a trigger
file. `libexec/auto-hotspot-check.sh` is demoted to a degraded-mode fallback for when the app
isn't running — reachability probing plus a best-effort `networksetup` join — and is rewritten so
it can never report a false success: every claimed join is checked against the DHCP router
fingerprint (`HOTSPOT_ROUTER`) plus a reachability probe, not against `networksetup`'s exit code.

TCC identity is kept stable across rebuilds by three measures: never rebuilding on a plain
`hotspotd menubar` invocation (only `--rebuild` does), installing to a fixed path outside the
space-containing repo checkout, and preferring a user-created codesigning identity
(`AutoHotspot Signing`, checked via `security find-identity`) over ad-hoc signing when one exists,
since an ad-hoc signature's cdhash rotates on every rebuild and each rotation is read by macOS as
a new app that needs a fresh Location prompt.

## Rejected alternatives

**A shell watcher built on `scutil -w`.** `scutil -w <key>` returns immediately if the key already
exists at invocation time, and macOS 26's `scutil` no longer has an `n.wait` counterpart to block
until a *future* change. There's no way to build a reliable blocking watch loop out of it, and it
still wouldn't solve the Location-gating problem — it would only replace one probe with another.

**Accessibility-based UI scripting of the Wi-Fi menu.** Driving the menu bar's "Personal
Hotspots" list via Accessibility APIs would sidestep the Location gate (CoreWLAN's authorization
model, not the menu UI, is what's gated) at the cost of a permission with much broader reach than
this tool needs, plus fragility against any Wi-Fi menu UI change across macOS versions. The user
explicitly ruled this out: Location Services is an acceptable ask, Accessibility is not.

**A Bluetooth PAN connection to the iPhone instead of Wi-Fi.** Personal Hotspot exposes a Bluetooth
PAN interface as well as Wi-Fi, and iOS can be told to advertise it without the Wi-Fi
Location-gating problem at all. Rejected because it changes the network path entirely (a PAN link
is much lower throughput than Wi-Fi tethering) and doesn't address the actual failure mode being
fixed, which is "join the Wi-Fi hotspot reliably" — swapping the transport doesn't verify or
improve that, it just avoids the problem for a use case the user didn't ask to change.

## Consequences

- One process now needs both `NSApplication`-level menu bar behavior and to survive as a
  `KeepAlive` launchd job — a shape more like a background service with an optional UI than a
  typical menu bar app, but macOS doesn't distinguish the two at the process level, so this is
  free.
- Rebuilding the app is no longer a routine operation — it has a real, user-visible cost (a
  re-prompt) unless the stable signing identity is set up. This is documented prominently in
  README.md and surfaced by `hotspotd doctor`.
- The shell fallback still exists and still has value: it's the path that runs before the app is
  ever installed, and after `pkill`/crash before it's relaunched, so the system doesn't go fully
  dark on Wi-Fi joins during that window.
