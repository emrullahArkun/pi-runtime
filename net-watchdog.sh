#!/bin/bash
# Brings the tunnel back when the server stays unreachable through it: restarts WireGuard,
# then the network, and as a last resort reboots. It reboots only when the Pi itself looks
# at fault; during a router or internet outage the kiosk keeps showing its cached times,
# while a boot without Wi-Fi would end on the Wi-Fi setup screen. Run by
# fleet-net-watchdog.timer as root.
set -uo pipefail

URL="${FLEET_HEARTBEAT_URL:-http://10.10.0.1:3000}"
CONFIG="${FLEET_CONFIG:-/etc/fleet/config}"
STATE_DIR="${STATE_DIR:-/run/fleet/net-watchdog}"
REBOOT_FILE="${REBOOT_FILE:-/var/lib/fleet/net-watchdog-reboot}"
PACKAGES_LOCK="${PACKAGES_LOCK:-/run/fleet-packages.lock}"
NET_DIR="${NET_DIR:-/sys/class/net}"
MIN_UPTIME_S="${MIN_UPTIME_S:-600}"
WG_AFTER_S="${WG_AFTER_S:-300}"
NET_AFTER_S="${NET_AFTER_S:-600}"
REBOOT_AFTER_S="${REBOOT_AFTER_S:-1200}"
REBOOT_COOLDOWN_S="${REBOOT_COOLDOWN_S:-21600}"
SETTLE_S="${SETTLE_S:-20}"

number() { [[ "$1" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }
log() { logger -t net-watchdog "$*" 2> /dev/null || true; }
reachable() { curl -fsS -o /dev/null --max-time 10 "${1%/}/health" 2> /dev/null; }

# Prints why a reboot would help, or fails when the fault lies beyond the Pi.
pi_at_fault() {
  local api gw="" wifi="" carrier=0 i
  api="$(sed -n 's/^FLEET_API_URL=//p' "$CONFIG" 2> /dev/null | tail -n 1)"
  if [ -n "$api" ] && reachable "$api"; then
    echo "Internet geht, nur der Tunnel nicht"
    return 0
  fi
  gw="$(ip route show default 2> /dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "via") {print $(i + 1); exit}}')"
  if [ -n "$gw" ] && ping -c 1 -W 3 "$gw" > /dev/null 2>&1; then
    return 1
  fi
  for i in "$NET_DIR"/*; do
    case "${i##*/}" in
      wl*) wifi="${i##*/}" ;;
      en* | eth*) [ "$(cat "$i/carrier" 2> /dev/null)" = 1 ] && carrier=1 ;;
    esac
  done
  # Neighbours' networks are nearly always in range; seeing none means the chip hangs.
  if [ -n "$wifi" ] && [ "$carrier" = 0 ] \
    && [ -z "$(nmcli -t -f SSID device wifi list ifname "$wifi" --rescan yes 2> /dev/null | grep -v '^$')" ]; then
    echo "WLAN sieht kein einziges Netz"
    return 0
  fi
  return 1
}

UPTIME_S="$(number "$(cut -d. -f1 "${PROC_UPTIME:-/proc/uptime}" 2> /dev/null)")"
[ "$UPTIME_S" -ge "$MIN_UPTIME_S" ] || exit 0

if reachable "$URL"; then
  [ -f "$STATE_DIR/since" ] && log "Server wieder erreichbar"
  rm -rf "$STATE_DIR"
  exit 0
fi

NOW="$(date +%s)"
mkdir -p "$STATE_DIR"
if [ ! -f "$STATE_DIR/since" ]; then
  echo "$NOW" > "$STATE_DIR/since"
  log "Server durch den Tunnel nicht erreichbar"
fi
DOWN_S=$((NOW - $(number "$(cat "$STATE_DIR/since")")))
STEP="$(number "$(cat "$STATE_DIR/step" 2> /dev/null)")"

if [ "$STEP" -lt 1 ] && [ "$DOWN_S" -ge "$WG_AFTER_S" ]; then
  echo 1 > "$STATE_DIR/step"
  log "seit ${DOWN_S} s nicht erreichbar, WireGuard neu starten"
  systemctl restart wg-quick@wg0
  exit 0
fi

if [ "$STEP" -lt 2 ] && [ "$DOWN_S" -ge "$NET_AFTER_S" ]; then
  echo 2 > "$STATE_DIR/step"
  log "seit ${DOWN_S} s nicht erreichbar, Netzwerk neu verbinden"
  nmcli networking off
  sleep 5
  nmcli networking on
  # wg-quick resolves the server's name only when it starts.
  sleep "$SETTLE_S"
  systemctl restart wg-quick@wg0
  exit 0
fi

[ "$STEP" -ge 2 ] && [ "$DOWN_S" -ge "$REBOOT_AFTER_S" ] || exit 0
if ! REASON="$(pi_at_fault)"; then
  [ -f "$STATE_DIR/outside" ] || log "seit ${DOWN_S} s nicht erreichbar, Fehler liegt hinter dem Router: kein Neustart"
  touch "$STATE_DIR/outside"
  exit 0
fi
LAST="$(number "$(cat "$REBOOT_FILE" 2> /dev/null)")"
[ $((NOW - LAST)) -ge "$REBOOT_COOLDOWN_S" ] || exit 0
mkdir -p "$(dirname "$REBOOT_FILE")"
echo "$NOW" > "$REBOOT_FILE"
log "seit ${DOWN_S} s nicht erreichbar (${REASON}), Neustart"
# Never cuts a package install short (same lock as the 03:00 reboot).
flock -w 1800 "$PACKAGES_LOCK" true
systemctl reboot
