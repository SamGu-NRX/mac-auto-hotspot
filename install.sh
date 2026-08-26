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

SSID_OVERRIDE=""
INTERVAL=120
COOLDOWN=300
IFACE="en0"
NO_LOAD=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: install.sh [options]

Installs the auto-hotspot LaunchAgent for the current user (must not run as root).

Options:
  --ssid NAME          Hotspot SSID to join when offline (default: Andrew's iPhone)
  --interval SECONDS   How often to check reachability (default: 120)
  --cooldown SECONDS   Minimum seconds between join attempts (default: 300)
  --interface NAME     Wi-Fi interface to manage (default: en0)
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
      INTERVAL="${2:-}"
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
      echo "CHECK_INTERVAL=120"
      echo "COOLDOWN=300"
      echo "ENABLED=1"
      echo "WIFI_INTERFACE=\"en0\""
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
set_config_key "CHECK_INTERVAL" "CHECK_INTERVAL=$INTERVAL"
set_config_key "COOLDOWN" "COOLDOWN=$COOLDOWN"
set_config_key "WIFI_INTERFACE" "WIFI_INTERFACE=\"$IFACE\""

echo "==> Rendering LaunchAgent plist"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "would render $TEMPLATE -> $PLIST"
else
  sed \
    -e 's|__LABEL__|'"$LABEL"'|g' \
    -e 's|__CHECKER_PATH__|'"$CHECKER"'|g' \
    -e 's|__CHECK_INTERVAL__|'"$INTERVAL"'|g' \
    -e 's|__LOG_PATH__|'"$HOME/Library/Logs/auto-hotspot.launchd.out"'|g' \
    -e 's|__ERR_LOG_PATH__|'"$HOME/Library/Logs/auto-hotspot.launchd.err"'|g' \
    "$TEMPLATE" > "$PLIST.tmp"

  if ! plutil -lint "$PLIST.tmp" >/dev/null; then
    echo "error: rendered plist failed plutil -lint" >&2
    rm -f "$PLIST.tmp"
    exit 1
  fi

  mv -f "$PLIST.tmp" "$PLIST"
  chmod 644 "$PLIST"
  echo "wrote $PLIST"
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
  if mkdir -p "$HOME/.local/bin" 2>/dev/null && [ -w "$HOME/.local/bin" ]; then
    LINK_DIR="$HOME/.local/bin"
    echo "note: $LINK_DIR is not on your PATH yet. Add this to your shell profile:"
    echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
fi

if [ -n "$LINK_DIR" ]; then
  if ln -sfn "$ROOT/bin/hotspotd" "$LINK_DIR/hotspotd" 2>/dev/null; then
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
  hotspotd menubar  build + launch the menu bar toggle app

Note: RunAtLoad means a reachability check just ran.
EOF
