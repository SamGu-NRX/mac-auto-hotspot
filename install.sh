#!/bin/bash
set -uo pipefail

# install.sh - install the auto-hotspot LaunchAgent for the current user.
# Never run this as root: it installs a per-user LaunchAgent under
# $HOME/Library/LaunchAgents and must run as the logged-in user.

if [ "$(id -u)" -eq 0 ]; then
  echo "error: do not run install.sh as root. This installs a user LaunchAgent and must run as the logged-in user." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd -P)"

LABEL="com.andrewwang.autohotspot"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG="$HOME/.config/auto-hotspot/config"
LOG="$HOME/Library/Logs/auto-hotspot.log"
STATE_DIR="$HOME/.local/state/auto-hotspot"
DOMAIN="gui/$(id -u)"
TEMPLATE="$ROOT/share/com.andrewwang.autohotspot.plist.template"
CHECKER="$ROOT/libexec/auto-hotspot-check.sh"

# Backstop LaunchAgent: runs $CHECKER on a fixed interval so reconnection
# still happens if the AutoHotspot.app watcher is down or crash-looping.
# See share/com.andrewwang.autohotspot.checker.plist.template.
CHECKER_LABEL="com.andrewwang.autohotspot.checker"
CHECKER_PLIST="$HOME/Library/LaunchAgents/$CHECKER_LABEL.plist"
CHECKER_TEMPLATE="$ROOT/share/com.andrewwang.autohotspot.checker.plist.template"

# The app bundle is the agent now; it lives at a fixed path outside this
# checkout so TCC identity (Location Services grant) survives rebuilds.
APP_PATH="$HOME/Applications/AutoHotspot.app"
AGENT_EXEC="$APP_PATH/Contents/MacOS/AutoHotspot"

SSID_OVERRIDE=""
CHECK_INTERVAL=300
COOLDOWN=30
IFACE="en0"
HOTSPOT_ROUTER="172.20.10.1"
NO_LOAD=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: install.sh [options]

Installs the auto-hotspot LaunchAgent for the current user (must not run as root).

Options:
  --ssid NAME          Hotspot SSID to join when offline (default: Andrew’s iPhone)
  --interval SECONDS   Safety-net poll interval, read at runtime by the agent (default: 300)
  --cooldown SECONDS   Minimum seconds between join attempts (default: 30)
  --interface NAME     Wi-Fi interface to manage (default: en0)
  --router IP          iOS tethering gateway used to verify a join (default: 172.20.10.1)
  --no-load            Render config/plist but skip launchctl bootstrap
  --dry-run            Print exactly what would happen; touch nothing
  -h, --help           Show this help

After installing, use:
  bin/hotspotd status   Check current state
  bin/hotspotd logs      Tail the log
  bin/hotspotd off       Pause auto-hotspot
  bin/hotspotd menubar   Launch the menu bar toggle app
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ssid)
      SSID_OVERRIDE="${2:-}"
      shift 2
      ;;
    --interval)
      CHECK_INTERVAL="${2:-}"
      shift 2
      ;;
    --cooldown)
      COOLDOWN="${2:-}"
      shift 2
      ;;
    --interface)
      IFACE="${2:-}"
      shift 2
      ;;
    --router)
      HOTSPOT_ROUTER="${2:-}"
      shift 2
      ;;
    --no-load)
      NO_LOAD=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
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

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
    *) return 0 ;;
  esac
}

if ! is_positive_int "$CHECK_INTERVAL"; then
  echo "error: --interval must be a positive integer (got: $CHECK_INTERVAL)" >&2
  usage >&2
  exit 1
fi
if ! is_positive_int "$COOLDOWN"; then
  echo "error: --cooldown must be a positive integer (got: $COOLDOWN)" >&2
  usage >&2
  exit 1
fi

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

echo "==> Checking prerequisites"
if [ ! -f "$TEMPLATE" ]; then
  echo "error: missing plist template: $TEMPLATE" >&2
  exit 1
fi
if [ ! -f "$CHECKER" ]; then
  echo "error: missing checker script: $CHECKER" >&2
  exit 1
fi
if [ ! -f "$CHECKER_TEMPLATE" ]; then
  echo "error: missing checker plist template: $CHECKER_TEMPLATE" >&2
  exit 1
fi

echo "==> Marking scripts executable"
run chmod +x "$ROOT/bin/hotspotd" "$CHECKER" "$ROOT/install.sh" "$ROOT/uninstall.sh"

echo "==> Creating config, log, and state directories"
run mkdir -p "$HOME/.config/auto-hotspot" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$STATE_DIR"

echo "==> Seeding configuration"
if [ "$DRY_RUN" -eq 1 ]; then
  if [ -f "$CONFIG" ]; then
    echo "would keep existing config: $CONFIG"
  else
    echo "would create config: $CONFIG"
  fi
else
  if [ ! -f "$CONFIG" ]; then
    {
      echo "# auto-hotspot configuration"
      printf 'SSID="Andrew\342\200\231s iPhone"\n'
      echo "CHECK_INTERVAL=300"
      echo "COOLDOWN=30"
      echo "ENABLED=1"
      echo "WIFI_INTERFACE=\"en0\""
      echo "HOTSPOT_ROUTER=\"172.20.10.1\""
      echo "NOTIFY=1"
    } > "$CONFIG"
    echo "created $CONFIG"
  else
    echo "kept existing $CONFIG"
  fi
fi

# Always (re)write HOTSPOTD_BIN, and apply any CLI overrides, without
# clobbering the rest of the file and without using sed -i.
set_config_key() {
  # set_config_key KEY VALUE_LITERAL_SHELL_ASSIGNMENT
  key="$1"
  assignment="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would set $key in $CONFIG"
    return
  fi
  tmp="$(mktemp "${CONFIG}.XXXXXX")"
  if [ -f "$CONFIG" ]; then
    grep -v -E "^${key}=" "$CONFIG" > "$tmp" || true
  fi
  printf '%s\n' "$assignment" >> "$tmp"
  mv -f "$tmp" "$CONFIG"
}

set_config_key "HOTSPOTD_BIN" "HOTSPOTD_BIN=\"$ROOT/bin/hotspotd\""

if [ -n "$SSID_OVERRIDE" ]; then
  set_config_key "SSID" "SSID=\"$SSID_OVERRIDE\""
fi
set_config_key "CHECK_INTERVAL" "CHECK_INTERVAL=$CHECK_INTERVAL"
set_config_key "COOLDOWN" "COOLDOWN=$COOLDOWN"
set_config_key "WIFI_INTERFACE" "WIFI_INTERFACE=\"$IFACE\""
set_config_key "HOTSPOT_ROUTER" "HOTSPOT_ROUTER=\"$HOTSPOT_ROUTER\""

echo "==> Building and installing the menu bar app (agent)"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "would run: $ROOT/bin/hotspotd menubar --rebuild --build-only"
else
  if ! "$ROOT/bin/hotspotd" menubar --rebuild --build-only; then
    echo "error: failed to build/sign/install AutoHotspot.app" >&2
    exit 1
  fi
  if [ ! -x "$AGENT_EXEC" ]; then
    echo "error: $AGENT_EXEC is missing after build; the agent cannot be installed" >&2
    exit 1
  fi
  echo "installed $APP_PATH"
fi

echo "==> Rendering LaunchAgent plist"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "would render $TEMPLATE -> $PLIST"
else
  # Delimiter is a control character (SOH, \001), not `|` — a path
  # containing `|` (unlikely but not impossible) would otherwise produce a
  # malformed sed expression instead of a clean substitution.
  sed \
    -e $'s\001__LABEL__\001'"$LABEL"$'\001g' \
    -e $'s\001__APP_BUNDLE_PATH__\001'"$APP_PATH"$'\001g' \
    -e $'s\001__LOG_PATH__\001'"$HOME/Library/Logs/auto-hotspot.launchd.out"$'\001g' \
    -e $'s\001__ERR_LOG_PATH__\001'"$HOME/Library/Logs/auto-hotspot.launchd.err"$'\001g' \
    "$TEMPLATE" > "$PLIST.tmp"

  if ! plutil -lint "$PLIST.tmp" >/dev/null; then
    echo "error: rendered plist failed plutil -lint" >&2
    rm -f "$PLIST.tmp"
    exit 1
  fi

  if [ -f "$PLIST" ]; then
    cp -p "$PLIST" "$PLIST.bak"
    echo "backed up existing plist to $PLIST.bak"
  fi

  mv -f "$PLIST.tmp" "$PLIST"
  chmod 644 "$PLIST"
  echo "wrote $PLIST"
fi

echo "==> Rendering backstop checker LaunchAgent plist"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "would render $CHECKER_TEMPLATE -> $CHECKER_PLIST"
else
  sed \
    -e $'s\001__CHECKER_LABEL__\001'"$CHECKER_LABEL"$'\001g' \
    -e $'s\001__CHECKER_PATH__\001'"$CHECKER"$'\001g' \
    -e $'s\001__CHECK_INTERVAL__\001'"$CHECK_INTERVAL"$'\001g' \
    -e $'s\001__CHECKER_LOG_PATH__\001'"$HOME/Library/Logs/auto-hotspot.checker.launchd.out"$'\001g' \
    -e $'s\001__CHECKER_ERR_LOG_PATH__\001'"$HOME/Library/Logs/auto-hotspot.checker.launchd.err"$'\001g' \
    "$CHECKER_TEMPLATE" > "$CHECKER_PLIST.tmp"

  if ! plutil -lint "$CHECKER_PLIST.tmp" >/dev/null; then
    echo "error: rendered checker plist failed plutil -lint" >&2
    rm -f "$CHECKER_PLIST.tmp"
    exit 1
  fi

  if [ -f "$CHECKER_PLIST" ]; then
    cp -p "$CHECKER_PLIST" "$CHECKER_PLIST.bak"
    echo "backed up existing checker plist to $CHECKER_PLIST.bak"
  fi

  mv -f "$CHECKER_PLIST.tmp" "$CHECKER_PLIST"
  chmod 644 "$CHECKER_PLIST"
  echo "wrote $CHECKER_PLIST"
fi

if [ "$NO_LOAD" -eq 1 ]; then
  echo "==> Skipping launchd bootstrap (--no-load)"
else
  echo "==> Loading LaunchAgent"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would run: launchctl bootout \"$DOMAIN/$LABEL\""
    echo "would run: launchctl enable \"$DOMAIN/$LABEL\""
    echo "would run: launchctl bootstrap \"$DOMAIN\" \"$PLIST\""
  else
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl enable "$DOMAIN/$LABEL"
    if launchctl bootstrap "$DOMAIN" "$PLIST"; then
      if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        echo "loaded: $LABEL is running under $DOMAIN"
      else
        echo "warning: bootstrap succeeded but launchctl print could not find $LABEL" >&2
      fi
    else
      echo "error: launchctl bootstrap failed" >&2
      exit 1
    fi
  fi

  echo "==> Loading backstop checker LaunchAgent"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would run: launchctl bootout \"$DOMAIN/$CHECKER_LABEL\""
    echo "would run: launchctl enable \"$DOMAIN/$CHECKER_LABEL\""
    echo "would run: launchctl bootstrap \"$DOMAIN\" \"$CHECKER_PLIST\""
  else
    launchctl bootout "$DOMAIN/$CHECKER_LABEL" 2>/dev/null || true
    launchctl enable "$DOMAIN/$CHECKER_LABEL"
    if launchctl bootstrap "$DOMAIN" "$CHECKER_PLIST"; then
      if launchctl print "$DOMAIN/$CHECKER_LABEL" >/dev/null 2>&1; then
        echo "loaded: $CHECKER_LABEL is running under $DOMAIN"
      else
        echo "warning: bootstrap succeeded but launchctl print could not find $CHECKER_LABEL" >&2
      fi
    else
      echo "error: launchctl bootstrap failed for $CHECKER_LABEL" >&2
      exit 1
    fi
  fi
fi

echo "==> Linking hotspotd onto PATH"
LINK_DIR=""
for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in
    *":$d:"*)
      if [ -d "$d" ] && [ -w "$d" ]; then
        LINK_DIR="$d"
        break
      fi
      ;;
  esac
done

if [ -z "$LINK_DIR" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    # Don't touch $HOME/.local/bin at all under --dry-run, even to check
    # writability — report what a real run would most likely do instead.
    echo "would create $HOME/.local/bin (if needed) and link hotspotd into it"
    LINK_DIR="$HOME/.local/bin"
  elif mkdir -p "$HOME/.local/bin" 2>/dev/null && [ -w "$HOME/.local/bin" ]; then
    LINK_DIR="$HOME/.local/bin"
    echo "note: $LINK_DIR is not on your PATH yet. Add this to your shell profile:"
    echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
fi

if [ -n "$LINK_DIR" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would link $LINK_DIR/hotspotd -> $ROOT/bin/hotspotd"
  elif ln -sfn "$ROOT/bin/hotspotd" "$LINK_DIR/hotspotd" 2>/dev/null; then
    echo "linked $LINK_DIR/hotspotd -> $ROOT/bin/hotspotd"
  else
    echo "warning: could not link into $LINK_DIR; call $ROOT/bin/hotspotd directly" >&2
  fi
else
  echo "warning: no writable PATH directory found; call $ROOT/bin/hotspotd directly" >&2
fi

echo "==> Done"
cat <<EOF
Next steps (open a new shell first, or run: hash -r)
  hotspotd status   check current state
  hotspotd logs     tail the log
  hotspotd off      pause auto-hotspot
  hotspotd menubar  launch the menu bar toggle app (already installed above)

Note: RunAtLoad means a reachability check just ran.
EOF
