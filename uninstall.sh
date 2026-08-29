#!/bin/bash
set -uo pipefail

# uninstall.sh - remove the auto-hotspot LaunchAgent for the current user.
# Never run this as root: it only touches per-user paths under $HOME.

if [ "$(id -u)" -eq 0 ]; then
  echo "error: do not run uninstall.sh as root. This manages a user LaunchAgent and must run as the logged-in user." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd -P)"

LABEL="com.andrewwang.autohotspot"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG="$HOME/.config/auto-hotspot/config"
LOG="$HOME/Library/Logs/auto-hotspot.log"
STATE_DIR="$HOME/.local/state/auto-hotspot"
DOMAIN="gui/$(id -u)"
APP_PATH="$HOME/Applications/AutoHotspot.app"

# Backstop LaunchAgent installed alongside the watcher (see install.sh /
# share/com.andrewwang.autohotspot.checker.plist.template).
CHECKER_LABEL="com.andrewwang.autohotspot.checker"
CHECKER_PLIST="$HOME/Library/LaunchAgents/$CHECKER_LABEL.plist"

PURGE=0

usage() {
  cat <<EOF
Usage: uninstall.sh [options]

Removes the auto-hotspot LaunchAgent for the current user (must not run as root).

Options:
  --purge      Also delete config, state dir, and logs
  -h, --help   Show this help

Without --purge, config and logs are kept in place.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)
      PURGE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

echo "==> Unloading LaunchAgent"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "unloaded $LABEL"
elif [ "$rc" -eq 3 ]; then
  echo "$LABEL was already not loaded"
else
  echo "launchctl bootout exited with status $rc (continuing)"
fi

echo "==> Unloading backstop checker LaunchAgent"
launchctl bootout "$DOMAIN/$CHECKER_LABEL" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "unloaded $CHECKER_LABEL"
elif [ "$rc" -eq 3 ]; then
  echo "$CHECKER_LABEL was already not loaded"
else
  echo "launchctl bootout exited with status $rc (continuing)"
fi

echo "==> Clearing any disabled override"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl enable "$DOMAIN/$CHECKER_LABEL" 2>/dev/null || true

echo "==> Removing LaunchAgent plists"
rm -f "$PLIST" "$CHECKER_PLIST"

echo "==> Removing the menu bar app"
pkill -f "$APP_PATH/Contents/MacOS/AutoHotspot" 2>/dev/null || true
if [ -d "$APP_PATH" ]; then
  rm -rf "$APP_PATH"
  echo "removed $APP_PATH"
else
  echo "$APP_PATH not present"
fi
echo "note: macOS keeps the Location Services grant for the app's identity even after this."
echo "      Revoke it by hand in System Settings > Privacy & Security > Location Services if wanted."

echo "==> Removing hotspotd PATH symlink"
removed_link=0
for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
  link="$d/hotspotd"
  # only remove a symlink that points back into this checkout; never a real file
  if [ -L "$link" ]; then
    target="$(readlink "$link" 2>/dev/null || true)"
    if [ "$target" = "$ROOT/bin/hotspotd" ]; then
      rm -f "$link" && echo "removed $link" && removed_link=1
    else
      echo "skipped $link (points elsewhere: $target)"
    fi
  fi
done
if [ "$removed_link" -eq 0 ]; then
  echo "no symlink to remove"
fi

if [ "$PURGE" -eq 1 ]; then
  echo "==> Purging config, state, and logs"
  rm -rf "$HOME/.config/auto-hotspot" "$STATE_DIR"
  rm -f "$LOG" "$LOG.1" \
    "$HOME/Library/Logs/auto-hotspot.launchd.out" \
    "$HOME/Library/Logs/auto-hotspot.launchd.err" \
    "$HOME/Library/Logs/auto-hotspot.checker.launchd.out" \
    "$HOME/Library/Logs/auto-hotspot.checker.launchd.err"
else
  echo "==> Kept config ($CONFIG) and logs ($LOG*)"
fi

echo "==> Verifying"
still_loaded=0
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo "warning: $LABEL still appears loaded" >&2
  still_loaded=1
else
  echo "confirmed: $LABEL is not loaded"
fi
if launchctl print "$DOMAIN/$CHECKER_LABEL" >/dev/null 2>&1; then
  echo "warning: $CHECKER_LABEL still appears loaded" >&2
  still_loaded=1
else
  echo "confirmed: $CHECKER_LABEL is not loaded"
fi
if [ "$still_loaded" -eq 1 ]; then
  exit 1
fi
