#!/bin/bash
#
# auto-hotspot-check.sh — periodic reachability check + hotspot join worker.
#
# Invoked by launchd on a timer, or by `hotspotd check` (which sets
# AUTO_HOTSPOT_FORCE=1). This is the only script that touches Wi-Fi.

set -uo pipefail

# ---- HOME fallback (launchd sometimes runs with a bare environment) ----
if [ -z "${HOME:-}" ]; then
    HOME="$(/usr/bin/id -P "$(/usr/bin/id -un)" | /usr/bin/cut -d: -f9)"
    if [ -z "$HOME" ]; then
        echo "auto-hotspot-check: HOME is unset and could not be determined" >&2
        exit 1
    fi
fi

# ---- paths (shared contract with bin/hotspotd) ----
CONFIG="${AUTO_HOTSPOT_CONFIG:-$HOME/.config/auto-hotspot/config}"
LOG="${AUTO_HOTSPOT_LOG:-$HOME/Library/Logs/auto-hotspot.log}"
STATE_DIR="${AUTO_HOTSPOT_STATE:-$HOME/.local/state/auto-hotspot}"

# ---- defaults, then source config ----
SSID="Andrew’s iPhone"
CHECK_INTERVAL=120
ENABLED=1
COOLDOWN=300
WIFI_INTERFACE=en0

if [ -f "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

# ---- logging setup ----
/bin/mkdir -p "$(/usr/bin/dirname "$LOG")" "$STATE_DIR"

LOG_MAX=1048576
if [ -f "$LOG" ]; then
    _log_size="$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)"
    if [ "$_log_size" -ge "$LOG_MAX" ]; then
        /bin/mv -f "$LOG" "$LOG.1"
    fi
fi

log() {
    _level="$1"
    shift
    _msg="$*"
    _ts="$(/bin/date +%Y-%m-%dT%H:%M:%S%z)"
    printf '[%s] [%s] %s\n' "$_ts" "$_level" "$_msg" >> "$LOG"
}

# ---- single-flight lock ----
LOCK_DIR="$STATE_DIR/lock"

acquire_lock() {
    if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
        return 0
    fi
    # lock held — check staleness (older than 5 minutes)
    if [ -n "$(/usr/bin/find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
        /bin/rmdir "$LOCK_DIR" 2>/dev/null
        if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

if ! acquire_lock; then
    log warn "another check is running, skipping"
    exit 0
fi

trap '/bin/rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# ---- kill switch ----
FORCE="${AUTO_HOTSPOT_FORCE:-0}"
if [ "$FORCE" != "1" ] && [ "$ENABLED" != "1" ]; then
    log info "disabled, skipping"
    exit 0
fi

# ---- reachability probe ----
# Sets PROBE_NC_RC as a side effect for logging.
probe_online() {
    /usr/bin/nc -z -G 3 1.1.1.1 53 >/dev/null 2>&1
    PROBE_NC_RC=$?

    _body="$(/usr/bin/curl -sS -m 4 http://captive.apple.com/hotspot-detect.html 2>/dev/null)"
    case "$_body" in
        *'<TITLE>Success</TITLE>'*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

LAST_JOIN_FILE="$STATE_DIR/last-join-attempt"

current_ssid() {
    /usr/sbin/networksetup -getairportnetwork "$WIFI_INTERFACE" 2>/dev/null | /usr/bin/sed -n 's/^Current Wi-Fi Network: //p'
}

if probe_online; then
    _ssid_now="$(current_ssid)"
    if [ -z "$_ssid_now" ]; then
        _ssid_now="other/none"
    fi
    log info "online (nc=$PROBE_NC_RC) via $_ssid_now"
    [ -f "$LAST_JOIN_FILE" ] && /bin/rm -f "$LAST_JOIN_FILE"
    exit 0
fi

# ---- offline: cooldown gate ----
if [ "$FORCE" != "1" ] && [ -f "$LAST_JOIN_FILE" ]; then
    _stamp="$(/bin/cat "$LAST_JOIN_FILE" 2>/dev/null || echo 0)"
    case "$_stamp" in
        ''|*[!0-9]*) _stamp=0 ;;
    esac
    _now="$(/bin/date +%s)"
    _elapsed=$(( _now - _stamp ))
    if [ "$_elapsed" -lt "$COOLDOWN" ]; then
        _left=$(( COOLDOWN - _elapsed ))
        log info "offline but in cooldown (${_left}s left), skipping"
        exit 0
    fi
fi

# write the stamp BEFORE attempting the join so a crash mid-attempt still throttles
/bin/date +%s > "$LAST_JOIN_FILE"

# ---- Wi-Fi power ----
_power_line="$(/usr/sbin/networksetup -getairportpower "$WIFI_INTERFACE" 2>/dev/null)"
case "$_power_line" in
    *": On"*) _power_on=1 ;;
    *) _power_on=0 ;;
esac

if [ "$_power_on" != "1" ]; then
    _power_out="$(/usr/sbin/networksetup -setairportpower "$WIFI_INTERFACE" on 2>&1)"
    _power_line="$(/usr/sbin/networksetup -getairportpower "$WIFI_INTERFACE" 2>/dev/null)"
    case "$_power_line" in
        *": On"*) _power_on=1 ;;
        *) _power_on=0 ;;
    esac
    if [ "$_power_on" != "1" ]; then
        log error "wi-fi is off and could not be enabled without sudo: $_power_out"
        exit 3
    fi
fi

# ---- already-associated check ----
_ssid_now="$(current_ssid)"
if [ -z "$_ssid_now" ]; then
    : # not associated to anything; not an error, proceed to join
elif [ "$_ssid_now" = "$SSID" ]; then
    log warn "associated to target SSID but offline"
fi

# ---- join ----
_join_out="$(/usr/sbin/networksetup -setairportnetwork "$WIFI_INTERFACE" "$SSID" 2>&1)"
_join_rc=$?
if [ -n "$_join_out" ]; then
    log info "join output: $_join_out"
fi
log info "join rc=$_join_rc"

# ---- settle + re-probe ----
/bin/sleep 5

_attempt=0
_became_online=0
while [ "$_attempt" -lt 3 ]; do
    if probe_online; then
        _became_online=1
        break
    fi
    _attempt=$(( _attempt + 1 ))
    if [ "$_attempt" -lt 3 ]; then
        /bin/sleep 3
    fi
done

if [ "$_became_online" = "1" ]; then
    _settle_seconds=$(( 5 + _attempt * 3 ))
    log info "joined \"$SSID\" and online after ${_settle_seconds}s"
    /bin/rm -f "$LAST_JOIN_FILE"
    exit 0
fi

log error "still offline after join attempt (rc=$_join_rc): $_join_out"
exit 2
