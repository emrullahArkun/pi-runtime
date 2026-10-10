#!/bin/bash
# Restarts the kiosk when the server has not heard from it for a while although this Pi
# reaches the server itself, which usually means a hung browser. Called by
# fleet-heartbeat.sh with the seconds the kiosk has been silent and the Pi's uptime.
# Restarts at most once an hour and counts them in /run (since boot) for the heartbeat.
set -uo pipefail

SILENT_S="${1:-}"
UPTIME_S="${2:-}"
SILENT_LIMIT_S="${SILENT_LIMIT_S:-600}"
MIN_UPTIME_S="${MIN_UPTIME_S:-900}"
COOLDOWN_S="${COOLDOWN_S:-3600}"
CONFIG="${FLEET_CONFIG:-/etc/fleet/config}"
STATE_FILE="${STATE_FILE:-/var/lib/fleet/kiosk-watchdog-at}"
COUNT_FILE="${COUNT_FILE:-/run/fleet/kiosk-restarts}"
FLEET_CONTROL="${FLEET_CONTROL:-/usr/local/sbin/fleet-control}"

number() { [[ "$1" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }

[[ "$SILENT_S" =~ ^[0-9]+$ && "$UPTIME_S" =~ ^[0-9]+$ ]] || exit 0
[ "$SILENT_S" -gt "$SILENT_LIMIT_S" ] || exit 0
# Right after boot the browser is still starting.
[ "$UPTIME_S" -gt "$MIN_UPTIME_S" ] || exit 0

NOW="$(date +%s)"
LAST="$(number "$(cat "$STATE_FILE" 2>/dev/null)")"
[ $((NOW - LAST)) -ge "$COOLDOWN_S" ] || exit 0

# Without the internet the kiosk cannot poll either, and a restart would not help.
API="$(sed -n 's/^FLEET_API_URL=//p' "$CONFIG" 2>/dev/null | tail -n 1)"
if [ -z "$API" ] || ! curl -fsS -o /dev/null --max-time 10 "${API%/}/health"; then
  exit 0
fi

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$COUNT_FILE")"
echo "$NOW" > "$STATE_FILE"
if SSH_ORIGINAL_COMMAND=restart-kiosk "$FLEET_CONTROL" > /dev/null 2>&1; then
  echo $(($(number "$(cat "$COUNT_FILE" 2>/dev/null)") + 1)) > "$COUNT_FILE"
  logger -t kiosk-watchdog "Kiosk seit ${SILENT_S} s still, neu gestartet" 2> /dev/null || true
fi
