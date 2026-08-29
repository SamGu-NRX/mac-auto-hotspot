# 2. The menu is problem-only, not a status readout

## Status

Accepted.

## Context

The menu had grown into a full status readout: a headline, the target hotspot, and a Settings
submenu listing every field from `status --json`, plus in-app actions like Edit Config… and Reveal
Log in Finder. None of it was information the user actually looked at day to day — `hotspotd
doctor` already covers the same ground for anyone actually diagnosing a problem, and the rule that
every new JSON key needed a matching menu row kept growing the menu further in the wrong
direction. The menu should tell the user one thing (is auto-join working) and get out of the way
otherwise.

## Decision

The root menu is a status line, zero or more problem rows, the Auto-Join Hotspot toggle, and Quit.
Nothing else. A problem row exists only while its condition is true — the menu is rebuilt from the
last fetched status each time it opens, not pre-built and hidden. A row earns a place in the menu
only if it is a click that fixes or diagnoses the thing (Grant Location Access…, Turn Wi-Fi On,
Restart Background Agent, Last Join Failed — Open Log); a condition that can only be reported, not
acted on, gets folded into the status line instead. Everything purely informational — interface,
check interval, cooldown, hotspot router, config path, log path, target SSID — moves to `hotspotd
doctor` and `status --json`, which remain the diagnostic surface.

## Consequences

- The "every JSON key needs a menu row" rule from `CLAUDE.md` is retired and replaced with the
  opposite rule: a key only gets a row if it becomes a clickable fix.
- In-app config editing (Edit Config…) and Check Now are gone. Editing config and forcing a check
  are terminal operations now (edit the file directly; `bin/hotspotd check` or the trigger file).
- The CLI is the diagnostic surface. Anyone debugging a stuck agent reaches for `hotspotd doctor`,
  not the menu bar.
