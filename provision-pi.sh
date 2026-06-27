#!/bin/bash
# provision-pi.sh — One-Command-Provisioning fuer einen Fleet-Pi.
#
# Schachtelt die zwei bestehenden Schritte zu einem Aufruf:
#   1) Token am VPS erzeugen   (ssh <vps> '... manage-pis.js add <name>')
#   2) SD praeparieren         (sudo ./flash.sh --token <token> ...)
# Der Token wird automatisch aus der manage-pis-Ausgabe gegriffen und
# durchgereicht — kein Copy-Paste mehr.
#
# Voraussetzung: Pi OS Lite ist via Raspberry Pi Imager auf die SD geflasht,
# inkl. Username (FEST: gebetszeiten-app), Hostname, WLAN und SSH. Dieses Skript
# fuegt nur das Fleet-Onboarding + den First-Boot-Bootstrap hinzu (via flash.sh).
#
# Konstanten (VPS-Alias, API-URL, Kiosk-URL) haben sinnvolle Defaults im Skript
# (VPS=hetzner + Prod-URLs). Eine fleet.conf ist nur noetig, wenn du die
# ueberschreiben willst:  cp fleet.conf.example fleet.conf
#
# Usage:
#   ./provision-pi.sh --name merkez [--device /dev/sdX]
#   --device ist optional: fehlt es, wird die frisch geflashte Pi-SD automatisch
#   erkannt und vor dem Schreiben zur Bestaetigung gezeigt.
#   (optional, falls WLAN NICHT schon im Imager gesetzt: --ssid WLAN --psk pw)
#
# NICHT mit sudo starten — die VPS-SSH-Verbindung braucht deinen User-SSH-Key.
# Das Skript ruft sudo selbst nur fuer flash.sh (mounten) auf.
#
# Tipps:
#   - --name ist das Label in der Fleet-DB; pro Pi eindeutig, idealerweise gleich
#     dem im Imager gesetzten Hostnamen.
#   - Device manuell finden:  lsblk   (Root-Device, z.B. /dev/sdb — NICHT sdb1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/fleet.conf"

NAME=""
DEVICE=""
SSID=""
PSK=""

usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit 1
}

# Erkennt die frisch geflashte Pi-SD ueber das vfat-Boot-Partition-Label
# ("bootfs" bei Pi OS Bookworm, "boot" bei aelteren). Funktioniert auch wenn die
# Karte NICHT gemountet ist (das Label ist via lsblk immer sichtbar). Gibt das
# Eltern-Block-Device zurueck — nur, wenn GENAU EINES eindeutig gefunden wird.
detect_pi_sd() {
  local found="" line PKNAME LABEL FSTYPE
  while IFS= read -r line; do
    # lsblk -P liefert shell-quotetes KEY="VALUE" ... -> eval-safe.
    PKNAME=""; LABEL=""; FSTYPE=""
    eval "$line"
    [ -n "$PKNAME" ] && [ "$FSTYPE" = "vfat" ] || continue
    [ "$LABEL" = "bootfs" ] || [ "$LABEL" = "boot" ] || continue
    found="$found /dev/$PKNAME"
  done < <(lsblk -Pno PKNAME,LABEL,FSTYPE 2>/dev/null)

  found="$(printf '%s\n' $found | sed '/^$/d' | sort -u)"
  [ -n "$found" ] || return 1
  [ "$(printf '%s\n' "$found" | grep -c .)" = "1" ] || return 1
  printf '%s\n' "$found"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)    NAME="$2"; shift 2 ;;
    --device)  DEVICE="$2"; shift 2 ;;
    --ssid)    SSID="$2"; shift 2 ;;
    --psk)     PSK="$2"; shift 2 ;;
    --config)  CONF="$2"; shift 2 ;;
    -h|--help) usage ;;
    *)         echo "Unbekanntes Argument: $1"; usage ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "FEHLER: --name ist Pflicht."
  usage
fi

# Nicht als root — sonst nutzt `ssh` den root-SSH-Key statt deinem.
if [ "$EUID" -eq 0 ]; then
  echo "FEHLER: NICHT mit sudo starten."
  echo "       Die VPS-Verbindung laeuft ueber deinen User-SSH-Key; flash.sh"
  echo "       ruft das Skript selbst per sudo auf."
  exit 1
fi

# --- Defaults (gelten ohne fleet.conf) ---
VPS_ALIAS="hetzner"
FLEET_API_URL="https://bigfleet.ipv64.net"
KIOSK_BASE_URL="https://big-gebetszeiten.vercel.app"
COUNTRY="DE"
DEFAULT_SSID=""
DEFAULT_PSK=""

# --- fleet.conf laden (optional) ---
# Nur noetig, wenn du obige Defaults ueberschreiben willst (anderer VPS-Alias,
# andere URLs, WLAN-Default). Fehlt die Datei, gelten die Defaults.
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

# WLAN: CLI-Arg schlaegt fleet.conf/Default; leer = Imager hat WLAN gesetzt.
SSID="${SSID:-${DEFAULT_SSID:-}}"
PSK="${PSK:-${DEFAULT_PSK:-}}"

# flash.sh muss daneben liegen.
if [ ! -f "$SCRIPT_DIR/flash.sh" ]; then
  echo "FEHLER: flash.sh nicht in $SCRIPT_DIR gefunden."
  exit 1
fi

# --- Device aufloesen: explizit via --device, sonst Pi-SD auto-erkennen ---
if [ -z "$DEVICE" ]; then
  if DEVICE="$(detect_pi_sd)"; then
    echo "  Auto-erkannte Pi-SD: $DEVICE"
  else
    echo "FEHLER: keine frisch geflashte Pi-SD eindeutig erkannt (0 oder mehrere"
    echo "       Kandidaten). Device explizit angeben:  --device /dev/sdX"
    echo "       ('lsblk' zeigt die Karte; Root-Device, nicht die Partition)."
    exit 1
  fi
fi

# Device-Sanity (flash.sh prueft danach nochmal hart).
if [ ! -b "$DEVICE" ]; then
  echo "FEHLER: $DEVICE ist kein Block-Device. 'lsblk' zeigt die SD-Karte."
  exit 1
fi

echo "=== Provisioning ==="
echo "  Pi-Name (DB):  $NAME"
echo "  SD-Device:     $DEVICE"
echo "  VPS:           $VPS_ALIAS"
echo "  API:           $FLEET_API_URL"
echo "  Kiosk-URL:     $KIOSK_BASE_URL"
if [ -n "$SSID" ]; then
  echo "  WLAN:          $SSID (country=$COUNTRY)"
else
  echo "  WLAN:          (vom Imager gesetzt — flash.sh schreibt keine wifi.conf)"
fi
echo
read -r -p "Passt das? Die SD-Karte wird beschrieben. [y/N] " ok
case "$ok" in
  y|Y|yes|j|J) ;;
  *) echo "Abgebrochen."; exit 1 ;;
esac

# ─── 1) Token am VPS erzeugen ─────────────────────────────────────────
echo
echo "[1/2] Token am VPS erzeugen (manage-pis add \"$NAME\")..."
# Nutzt den VPS-Wrapper /usr/local/sbin/manage-pis (von 06-api.sh installiert):
# der sourct /etc/fleet-api/env selbst, daher keine DB_PATH/Pfad-Angaben noetig.
REMOTE_CMD="sudo manage-pis add \"$NAME\""
if ! ADD_OUT="$(ssh "$VPS_ALIAS" "$REMOTE_CMD")"; then
  echo "FEHLER: manage-pis add auf dem VPS fehlgeschlagen."
  printf '%s\n' "$ADD_OUT"
  exit 1
fi
printf '%s\n' "$ADD_OUT"

TOKEN="$(printf '%s\n' "$ADD_OUT" | awk '/enrollment_token:/ {print $2; exit}' | tr -d '[:space:]')"
if [ -z "$TOKEN" ]; then
  echo "FEHLER: Konnte enrollment_token nicht aus der Ausgabe lesen."
  echo "       Pruefe das Ausgabeformat / die manage-pis-Pfade in fleet.conf."
  exit 1
fi
echo "  -> Token erhalten (${#TOKEN} Zeichen)."

# ─── 2) SD praeparieren (flash.sh, braucht sudo zum Mounten) ──────────
echo
echo "[2/2] SD praeparieren via flash.sh (sudo)..."
FLASH_ARGS=(
  --device "$DEVICE"
  --token "$TOKEN"
  --api "$FLEET_API_URL"
  --kiosk-url "$KIOSK_BASE_URL"
)
if [ -n "$SSID" ]; then
  FLASH_ARGS+=( --ssid "$SSID" --country "$COUNTRY" )
  [ -n "$PSK" ] && FLASH_ARGS+=( --psk "$PSK" )
fi
sudo bash "$SCRIPT_DIR/flash.sh" "${FLASH_ARGS[@]}"

echo
echo "=== Fertig ==="
echo "SD-Karte sauber auswerfen, in Pi '$NAME' stecken, Strom dran."
echo "Der Pi bootet, zieht pi-runtime, laeuft setup.sh selbst und landet im Kiosk"
echo "(First-Boot dauert real ~5-15min wegen apt + Paketen)."
echo
echo "Status checken:"
echo "  ssh $VPS_ALIAS 'sudo manage-pis list'"
echo "  oder im Admin-Panel (#admin)."
