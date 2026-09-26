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

PAYLOAD="$(jq -n \
  --argjson up "$UP" --arg serial "${CPU_SERIAL:-}" \
  --argjson temp "$TEMP" --argjson load1 "$LOAD1" --argjson cores "$CORES" \
  --argjson mem "$MEMPCT" --argjson disk "$DISKPCT" --arg throttled "$THROTTLED" \
  '{uptime_seconds:$up, cpu_serial:$serial,
    metrics:{temp:$temp, load1:$load1, cores:$cores,
             mem_used_pct:$mem, disk_used_pct:$disk, throttled:$throttled}}')"

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
