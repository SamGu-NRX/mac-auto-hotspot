#!/bin/bash
#
# auto-hotspot-check.sh — degraded-mode reachability check + hotspot join worker.
#
# The AutoHotspot.app agent (menubar/AutoHotspot.swift) owns joining now: it's
# the only code path with a TCC grant to see real SSIDs on macOS 26. This
# script is the fallback used when that agent isn't running — invoked by
# `hotspotd check` (which sets AUTO_HOTSPOT_FORCE=1), or by anything that
# still wants a best-effort probe+join without the app.

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
AGENT_STATUS_FILE="$STATE_DIR/agent.status"
APP_PATH="$HOME/Applications/AutoHotspot.app"
AGENT_EXEC="$APP_PATH/Contents/MacOS/AutoHotspot"

# ---- defaults, then source config ----
# Literal U+2019 RIGHT SINGLE QUOTATION MARK below (not ASCII '). See the
# matching printf-octal form (with this same comment) in bin/hotspotd.
SSID="Sam Gu’s iPhone"
CHECK_INTERVAL=300
ENABLED=1
COOLDOWN=30
WIFI_INTERFACE=en0
# The iOS tethering gateway; join success is verified against this, not
# against networksetup's worthless exit code (see the join step below).
HOTSPOT_ROUTER="172.20.10.1"
NOTIFY=1

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

# ---- kill switch / force flag ----
FORCE="${AUTO_HOTSPOT_FORCE:-0}"

# ---- defer to the agent when it's running ----
# The app is the only process with the TCC grant to actually see SSIDs; if
# it's up, it owns joining and this worker would just fight it over Wi-Fi
# state. AUTO_HOTSPOT_FORCE=1 (from `hotspotd check`) overrides this.
if [ "$FORCE" != "1" ] && pgrep -qf "$AGENT_EXEC" >/dev/null 2>&1; then
    log info "agent is running, deferring"
    exit 0
fi

if [ "$FORCE" != "1" ] && [ "$ENABLED" != "1" ]; then
    log info "disabled, skipping"
    exit 0
fi

# ---- single-flight lock ----
LOCK_DIR="$STATE_DIR/lock"

# Stale-lock window scales with COOLDOWN so it doesn't dwarf it (COOLDOWN is
# now 30s by default, down from the 300s this was originally sized against).
_stale_seconds=$(( COOLDOWN * 4 ))
if [ "$_stale_seconds" -lt 300 ]; then
    _stale_seconds=300
fi
_stale_minutes=$(( _stale_seconds / 60 ))
if [ "$_stale_minutes" -lt 1 ]; then
    _stale_minutes=1
fi

acquire_lock() {
    if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
        return 0
    fi
    # lock held — check staleness
    if [ -n "$(/usr/bin/find "$LOCK_DIR" -maxdepth 0 -mmin +$_stale_minutes 2>/dev/null)" ]; then
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

# ---- reachability probe ----
probe_online() {
    _body="$(curl -sS -m 4 http://captive.apple.com/hotspot-detect.html 2>/dev/null)"
    case "$_body" in
        *'<TITLE>Success</TITLE>'*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Reachability pinned to the Wi-Fi interface specifically — used to verify a
# join, where "some interface is online" (e.g. Ethernet) is not good enough.
probe_online_via_wifi() {
    _body="$(curl -sS -m 4 --interface "$WIFI_INTERFACE" http://captive.apple.com/hotspot-detect.html 2>/dev/null)"
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

# Owned by the AutoHotspot.app agent, not this degraded-mode worker:
#   $STATE_DIR/trigger       - touched by `hotspotd` to poke the watcher
#   $STATE_DIR/agent.status  - JSON the app writes (real SSID, location_authorized, ...)

# current_ssid tries, in order: the agent's last-known SSID (it holds the only
# TCC grant that can actually see SSIDs on macOS 26), then networksetup, then
# ipconfig. All three can legitimately come back empty or the literal string
# "<redacted>" (confirmed on this machine: `ipconfig getsummary en0` prints
# "SSID : <redacted>" while associated) — that is NOT the same as "not
# associated", so it must never be reported as an empty string.
current_ssid() {
    _s=""
    if [ -f "$AGENT_STATUS_FILE" ]; then
        _s="$(/usr/bin/sed -n 's/.*"ssid_current" *: *"\([^"]*\)".*/\1/p' "$AGENT_STATUS_FILE" 2>/dev/null | /usr/bin/head -1)"
    fi
    if [ -z "$_s" ] || [ "$_s" = "<redacted>" ]; then
        _s="$(networksetup -getairportnetwork "$WIFI_INTERFACE" 2>/dev/null | /usr/bin/sed -n 's/^Current Wi-Fi Network: //p')"
    fi
    if [ -z "$_s" ] || [ "$_s" = "<redacted>" ]; then
        _s="$(ipconfig getsummary "$WIFI_INTERFACE" 2>/dev/null | /usr/bin/sed -n 's/.*SSID : \(.*\)/\1/p' | /usr/bin/head -1)"
    fi
    if [ -z "$_s" ] || [ "$_s" = "<redacted>" ]; then
        _s="(hidden)"
    fi
    printf '%s' "$_s"
}

# Mirror the app's strike gate: one probe decides "online", but a failure is
# retried before it is believed. Failback is deliberately NOT mirrored here —
# this script only runs when the menu bar agent is down, and dropping a
# working hotspot from a degraded fallback path is not a good trade.
FAILOVER_STRIKES="${FAILOVER_STRIKES:-3}"
STRIKE_INTERVAL="${STRIKE_INTERVAL:-5}"

confirm_offline() {
    _i=1
    while [ "$_i" -le "$FAILOVER_STRIKES" ]; do
        if probe_online; then
            [ "$_i" -gt 1 ] && log info "probe: recovered on attempt $_i/$FAILOVER_STRIKES, no failover"
            return 1
        fi
        _i=$(( _i + 1 ))
        [ "$_i" -le "$FAILOVER_STRIKES" ] && sleep "$STRIKE_INTERVAL"
    done
    log info "probe: $FAILOVER_STRIKES consecutive failures"
    return 0
}

if ! confirm_offline; then
    _ssid_now="$(current_ssid)"
    log info "online via $_ssid_now"
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
_power_line="$(networksetup -getairportpower "$WIFI_INTERFACE" 2>/dev/null)"
case "$_power_line" in
    *": On"*) _power_on=1 ;;
    *) _power_on=0 ;;
esac

if [ "$_power_on" != "1" ]; then
    _power_out="$(networksetup -setairportpower "$WIFI_INTERFACE" on 2>&1)"
    _power_line="$(networksetup -getairportpower "$WIFI_INTERFACE" 2>/dev/null)"
    case "$_power_line" in
        *": On"*) _power_on=1 ;;
        *) _power_on=0 ;;
    esac
    if [ "$_power_on" != "1" ]; then
        log error "wi-fi is off and could not be enabled: $_power_out"
        exit 3
    fi
fi

# ---- already-associated check ----
_ssid_now="$(current_ssid)"
if [ "$_ssid_now" = "$SSID" ]; then
    log warn "associated to target SSID but offline"
fi

# ---- join ----
# networksetup -setairportnetwork EXITS 0 REGARDLESS OF OUTCOME, so $? is
# worthless here — never trust it. The signal is stdout: it prints nothing on
# a real success, and an error message (e.g. "Could not find network X",
# "Failed to join network X") on failure. Treat ANY non-empty output as a
# hard failure rather than trying to enumerate every phrasing.
_join_out="$(networksetup -setairportnetwork "$WIFI_INTERFACE" "$SSID" 2>&1)"
if [ -n "$_join_out" ]; then
    log error "join failed: $_join_out"
    exit 2
fi

# ---- settle + re-probe ----
# Success requires BOTH: the interface's DHCP router matches the known iOS
# tethering gateway, AND a reachability probe bound to the Wi-Fi interface
# specifically succeeds. Neither alone rules out "some other interface is
# online while Wi-Fi sits unassociated" — the bug this replaces.
/bin/sleep 5

_attempt=0
_became_online=0
_router_now=""
while [ "$_attempt" -lt 3 ]; do
    _router_now="$(ipconfig getoption "$WIFI_INTERFACE" router 2>/dev/null)"
    if [ "$_router_now" = "$HOTSPOT_ROUTER" ] && probe_online_via_wifi; then
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
    log info "joined \"$SSID\" and online after ${_settle_seconds}s (router=$_router_now)"
    /bin/rm -f "$LAST_JOIN_FILE"
    exit 0
fi

log error "join attempt did not put us on the hotspot (router=$_router_now, expected=$HOTSPOT_ROUTER)"
exit 2
