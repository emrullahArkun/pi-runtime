#!/bin/bash
# Installed by setup.sh — sendet POST /pi/heartbeat ueber WG-Tunnel
# (inkl. Hardware-Snapshot) und persistiert die vom Server zurueckgelieferte
# kioskId nach /etc/fleet/kiosk-id.
set -euo pipefail
export LC_ALL=C   # deterministische Zahlenformatierung (Punkt, nicht Komma)
UP=$(cut -d. -f1 /proc/uptime)

# --- Hardware-Snapshot. Pi-spezifisches (Temp/Throttling) mit Fallback auf
#     JSON null bzw. leeren String, damit jq nie auf invalidem Input bricht. ---
TEMP="$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true)"
LOAD1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || true)"
CORES="$(nproc 2>/dev/null || true)"
MEMPCT="$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{if(t>0)printf "%d",(t-a)/t*100}' /proc/meminfo 2>/dev/null || true)"
DISKPCT="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}' || true)"
THROTTLED="$(vcgencmd get_throttled 2>/dev/null | sed 's/^throttled=//' || true)"
: "${TEMP:=null}"; : "${LOAD1:=null}"; : "${CORES:=null}"; : "${MEMPCT:=null}"; : "${DISKPCT:=null}"

# --- TV power via HDMI-CEC. Asking for the power status does not wake the TV. The
#     TV sits on cec0 or cec1 (whichever has a valid physical address, as in
#     fleet-control); an adapter without a logical address first joins as playback
#     device, one that has one is left alone.
tv_power() {
  command -v cec-ctl >/dev/null 2>&1 || { echo no-cec; return; }
  local dev status out
  for dev in /dev/cec0 /dev/cec1; do
    [ -e "$dev" ] || continue
    status="$(cec-ctl -d "$dev" 2>/dev/null || true)"
    if printf '%s' "$status" | grep -q 'Logical Address Mask *: 0x0000'; then
      cec-ctl -d "$dev" --playback >/dev/null 2>&1 || true
      status="$(cec-ctl -d "$dev" 2>/dev/null || true)"
    fi
    printf '%s' "$status" | grep -q 'Physical Address *: f\.f\.f\.f' && continue
    out="$(timeout 5 cec-ctl -d "$dev" --to 0 --give-device-power-status 2>&1 || true)"
    case "$out" in
      *"Not Acknowledged"*) echo no-answer ;;
      *"pwr-state: on"*) echo on ;;
      *"pwr-state: standby"*) echo standby ;;
      *"pwr-state: in transition"*) echo transition ;;
      *) echo no-answer ;;
    esac
    return
  done
  echo no-tv
}
TV_POWER="$(tv_power 2>/dev/null || true)"

# --- Clock. The Pi has no battery-backed clock; the server compares this time with
#     its own and shows the offset.
case "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" in
  yes) CLOCK_SYNCED=true ;;
  no) CLOCK_SYNCED=false ;;
  *) CLOCK_SYNCED=null ;;
esac
NOW="$(date +%s)"

# --- Network of the default route (the tunnel only carries 10.10.0.0/16).
IFACE="$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}' || true)"
NET_TYPE=""; WIFI_SSID=""; WIFI_DBM=null
case "$IFACE" in
  wl*)
    NET_TYPE=wifi
    WIFI_DBM="$(awk -v dev="$IFACE:" '$1 == dev {gsub(/\./, "", $4); print int($4)}' "${PROC_WIRELESS:-/proc/net/wireless}" 2>/dev/null || true)"
    WIFI_SSID="$(iw dev "$IFACE" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | head -n 1 || true)"
    ;;
  en* | eth*) NET_TYPE=ethernet ;;
  "") ;;
  *) NET_TYPE="$IFACE" ;;
esac
: "${WIFI_DBM:=null}"

PAYLOAD="$(jq -n \
  --argjson up "$UP" --arg serial "${CPU_SERIAL:-}" \
  --argjson temp "$TEMP" --argjson load1 "$LOAD1" --argjson cores "$CORES" \
  --argjson mem "$MEMPCT" --argjson disk "$DISKPCT" --arg throttled "$THROTTLED" \
  --arg tv "$TV_POWER" --argjson synced "$CLOCK_SYNCED" --argjson now "$NOW" \
  --arg net "$NET_TYPE" --arg ssid "${WIFI_SSID:0:64}" --argjson dbm "$WIFI_DBM" \
  '{uptime_seconds:$up, cpu_serial:$serial,
    metrics:({temp:$temp, load1:$load1, cores:$cores,
              mem_used_pct:$mem, disk_used_pct:$disk, throttled:$throttled,
              clock_synced:$synced, time:$now,
              wifi_signal_dbm:(if $dbm != null and $dbm >= -120 and $dbm <= 0 then $dbm else null end)}
             + (if $tv != "" then {tv_power:$tv} else {} end)
             + (if $net != "" then {net_type:$net} else {} end)
             + (if $ssid != "" then {wifi_ssid:$ssid} else {} end))}')"

RESP="$(curl -fsS --max-time 10 \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "${FLEET_HEARTBEAT_URL}/pi/heartbeat" || true)"

# Der Server vergibt die kioskId und liefert sie hier zurueck. In
# /etc/fleet/kiosk-id ablegen (0644, kiosk.sh liest das als der Pi-User und
# haengt es an die Kiosk-URL). Nur bei Aenderung schreiben.
KID="$(printf '%s' "$RESP" | jq -r '.kiosk_id // empty' 2>/dev/null || true)"
if [ -n "$KID" ]; then
  mkdir -p /etc/fleet
  if [ "$KID" != "$(cat /etc/fleet/kiosk-id 2>/dev/null || true)" ]; then
    printf '%s\n' "$KID" > /etc/fleet/kiosk-id
    chmod 0644 /etc/fleet/kiosk-id
  fi
fi
