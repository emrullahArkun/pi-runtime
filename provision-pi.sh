#!/bin/bash
# provision-pi.sh — one command from an empty SD card to a fleet Pi.
#
# Asks for the name (and optionally the Wi-Fi for a first start at home), creates the
# Pi's slot on the server and writes everything to the card: the newest gold image from
# image/build.sh (or, without one, Raspberry Pi OS Lite 64-bit, installed on the first
# start), cloud-init user-data (user gebetszeiten-app, hostname, your SSH key, a random
# device password) and the fleet enrollment. The password is shown once at the end.
# No Raspberry Pi Imager needed.
#
# Usage:
#   ./provision-pi.sh [--name merkez] [--device /dev/sdX] [--ssh-key ~/.ssh/id_ed25519.pub]
#                     [--ssid WLAN --psk pw] [--image os.img.xz] [--official] [--no-os]
#   --official  Raspberry Pi OS instead of the gold image (installs on the first start)
#   --no-os     the card was already flashed with the Imager (old way): only adds the
#               enrollment and the first-boot bootstrap.
#
# Run WITHOUT sudo (the server connection uses your SSH key); the script calls sudo
# itself for writing the card.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=image/os-image.sh
. "$SCRIPT_DIR/image/os-image.sh"
CONF="$SCRIPT_DIR/fleet.conf"
PI_USER="gebetszeiten-app"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/big-kiosk"

NAME=""
DEVICE=""
SSID=""
PSK=""
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
IMAGE=""
WRITE_OS=1
OFFICIAL=0

usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)    NAME="$2"; shift 2 ;;
    --device)  DEVICE="$2"; shift 2 ;;
    --ssid)    SSID="$2"; shift 2 ;;
    --psk)     PSK="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --image)   IMAGE="$2"; shift 2 ;;
    --no-os)   WRITE_OS=0; shift ;;
    --official) OFFICIAL=1; shift ;;
    --config)  CONF="$2"; shift 2 ;;
    -h|--help) usage ;;
    *)         echo "Unbekanntes Argument: $1"; usage ;;
  esac
done

if [ "$EUID" -eq 0 ]; then
  echo "FEHLER: NICHT mit sudo starten, das Skript fragt selbst nach sudo."
  exit 1
fi

VPS_ALIAS="hetzner"
FLEET_API_URL="https://bigfleet.ipv64.net"
KIOSK_BASE_URL="https://big-gebetszeiten.vercel.app"
COUNTRY="DE"
DEFAULT_SSID=""
DEFAULT_PSK=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi
SSID="${SSID:-${DEFAULT_SSID:-}}"
PSK="${PSK:-${DEFAULT_PSK:-}}"

ask() { local reply; read -r -p "$1" reply; printf '%s' "$reply"; }
confirm() { case "$(ask "$1 [y/N] ")" in y|Y|yes|j|J|ja) return 0 ;; *) return 1 ;; esac; }

# Removable disks and SD slots, never the disk this computer runs from.
candidate_devices() {
  local system
  system="$(lsblk -nrpo PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1)"
  lsblk -dnrpo NAME,TYPE,RM,TRAN | while read -r name type rm tran; do
    [ "$type" = "disk" ] && [ "$name" != "$system" ] || continue
    case "$name" in /dev/mmcblk*) echo "$name"; continue ;; esac
    { [ "$rm" = "1" ] || [ "$tran" = "usb" ]; } && echo "$name"
  done
}

describe() { lsblk -dno SIZE,MODEL "$1" | sed 's/  */ /g'; }

# --- Name ---
while ! printf '%s' "$NAME" | grep -qE '^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$'; do
  [ -n "$NAME" ] && echo "  Nur Kleinbuchstaben, Zahlen und Bindestriche."
  NAME="$(ask "Name der Anzeige (z. B. merkez-2): ")"
done

# --- SD card ---
if [ -z "$DEVICE" ]; then
  mapfile -t CANDIDATES < <(candidate_devices)
  if [ "${#CANDIDATES[@]}" -eq 1 ]; then
    DEVICE="${CANDIDATES[0]}"
  else
    echo "SD-Karte waehlen:"
    for dev in "${CANDIDATES[@]}"; do echo "  $dev  ($(describe "$dev"))"; done
    DEVICE="$(ask "Geraet (z. B. /dev/mmcblk0): ")"
  fi
fi
if [ ! -b "$DEVICE" ] || [ "$(lsblk -dno TYPE "$DEVICE")" != "disk" ]; then
  echo "FEHLER: $DEVICE ist keine Karte ('lsblk' zeigt die Laufwerke)."
  exit 1
fi

# --- Device password and SSH key (only when writing the OS) ---
USER_DATA=""
cleanup() { [ -n "$USER_DATA" ] && rm -f "$USER_DATA"; return 0; }
trap cleanup EXIT

if [ "$WRITE_OS" = "1" ]; then
  if [ ! -f "$SSH_KEY" ] || ! grep -qE '^(ssh-(ed25519|rsa)|ecdsa-)' "$SSH_KEY"; then
    echo "FEHLER: $SSH_KEY ist kein oeffentlicher SSH-Schluessel (.pub)."
    exit 1
  fi
  # Device password (sudo in the panel terminal): random per Pi, shown once at the end.
  RAW=""
  while [ "${#RAW}" -lt 20 ]; do
    RAW+="$(openssl rand -base64 48 | tr -dc 'abcdefghjkmnpqrstuvwxyz23456789')"
  done
  DEVICE_PASSWORD="${RAW:0:5}-${RAW:5:5}-${RAW:10:5}-${RAW:15:5}"
  unset RAW
  PW_HASH="$(openssl passwd -6 -stdin <<< "$DEVICE_PASSWORD")"

  # The newest gold image from image/build.sh, if there is one and it is intact.
  if [ -z "$IMAGE" ] && [ "$OFFICIAL" = "0" ]; then
    mapfile -t GOLD_IMAGES < <(printf '%s\n' "$CACHE_DIR"/big-kiosk-*.img.xz | sort -r)
    for gold in "${GOLD_IMAGES[@]}"; do
      [ -f "$gold" ] || continue
      if (cd "$CACHE_DIR" && sha256sum -c --quiet "$(basename "$gold").sha256" 2>/dev/null); then
        IMAGE="$gold"
        break
      fi
      echo "WARN: $(basename "$gold") ist beschaedigt oder ohne Pruefsumme, uebersprungen."
    done
  fi
fi

# --- Wi-Fi for the first start (optional) ---
if [ -z "$SSID" ]; then
  SSID="$(ask "WLAN fuer den ersten Start zu Hause (leer lassen bei LAN-Kabel): ")"
  if [ -n "$SSID" ] && [ -z "$PSK" ]; then
    read -r -s -p "  WLAN-Passwort: " PSK; echo
  fi
fi

# --- Summary ---
echo
echo "=== Zusammenfassung ==="
echo "  Name:        $NAME"
echo "  SD-Karte:    $DEVICE ($(describe "$DEVICE"))"
if [ "$WRITE_OS" = "1" ]; then
  if [ -n "$IMAGE" ]; then
    echo "  System:      $(basename "$IMAGE"), wird frisch geschrieben"
  else
    echo "  System:      Raspberry Pi OS Lite 64-bit (ohne Gold-Image: Installation beim ersten Start)"
  fi
  echo "  Benutzer:    $PI_USER, SSH-Schluessel $(awk '{print $NF}' "$SSH_KEY")"
else
  echo "  System:      schon vom Imager geschrieben (--no-os)"
fi
echo "  WLAN:        ${SSID:-keins, erster Start per LAN-Kabel}"
echo "  Server:      $VPS_ALIAS"
echo
if [ "$WRITE_OS" = "1" ]; then
  echo "ACHTUNG: Alles auf $DEVICE wird geloescht."
fi
confirm "Weiter?" || { echo "Abgebrochen."; exit 1; }

# --- OS image ---
if [ "$WRITE_OS" = "1" ] && [ -z "$IMAGE" ]; then
  mkdir -p "$CACHE_DIR"
  echo
  echo "[1/4] Raspberry Pi OS pruefen..."
  IMAGE="$(fetch_official_image "$CACHE_DIR")" || exit 1
  echo "  $(basename "$IMAGE") ist geprueft."
fi

if [ "$WRITE_OS" = "1" ]; then
  USER_DATA="$(mktemp)"
  chmod 600 "$USER_DATA"
  cat > "$USER_DATA" << EOF
#cloud-config
# Written by provision-pi.sh, like the Raspberry Pi Imager does.
manage_resolv_conf: false
hostname: $NAME
manage_etc_hosts: true
apt:
  preserve_sources_list: true
  conf: |
    Acquire {
      Check-Date "false";
    };
timezone: Europe/Berlin
keyboard:
  model: pc105
  layout: "de"
user:
  name: $PI_USER
  shell: /bin/bash
  lock_passwd: false
  hashed_passwd: "$PW_HASH"
  ssh_authorized_keys:
    - "$(head -1 "$SSH_KEY")"
  sudo: null
ssh_pwauth: false
runcmd:
  - [ systemctl, enable, --now, ssh ]
  - [ rfkill, unblock, wifi ]
  - [ sh, -c, "for f in /var/lib/systemd/rfkill/*:wlan; do echo 0 > \\"\$f\\"; done" ]
EOF
fi

# --- Slot on the server ---
echo
echo "[2/4] Platz auf dem Server anlegen..."
EXISTING="$(ssh "$VPS_ALIAS" "sudo fleet manage-pis list" | awk -v name="$NAME" '
  { sub(/^#/, ""); n = ""; for (i = 4; i <= NF && $i !~ /^serial=/; i++) n = n (n ? " " : "") $i; if (n == name) print $1 }')"
for id in $EXISTING; do
  echo "  Es gibt schon einen Pi '$NAME' (#$id). Derselbe Pi kann sich sonst nicht neu anmelden."
  if confirm "  Alten Platz #$id loeschen?"; then
    ssh "$VPS_ALIAS" "sudo fleet manage-pis remove $id"
  else
    echo "Abgebrochen."; exit 1
  fi
done
ADD_OUT="$(ssh "$VPS_ALIAS" "sudo fleet manage-pis add \"$NAME\"")"
TOKEN="$(printf '%s\n' "$ADD_OUT" | awk '/enrollment_token:/ {print $2; exit}' | tr -d '[:space:]')"
if [ -z "$TOKEN" ]; then
  echo "FEHLER: kein Anmelde-Token vom Server bekommen:"
  printf '%s\n' "$ADD_OUT"
  exit 1
fi
printf '%s\n' "$ADD_OUT" | grep -E "created|wg_ip" || true

# --- Write the card ---
echo
echo "[3/4] SD-Karte beschreiben (sudo)..."
FLASH_ARGS=(--device "$DEVICE" --token "$TOKEN" --api "$FLEET_API_URL" --kiosk-url "$KIOSK_BASE_URL" --country "$COUNTRY")
[ "$WRITE_OS" = "1" ] && FLASH_ARGS+=(--image "$IMAGE" --user-data "$USER_DATA")
if [ -n "$SSID" ]; then
  FLASH_ARGS+=(--ssid "$SSID")
  [ -n "$PSK" ] && FLASH_ARGS+=(--psk "$PSK")
fi
sudo bash "$SCRIPT_DIR/flash.sh" "${FLASH_ARGS[@]}"

echo
echo "[4/4] Fertig."
sync
for part in $(lsblk -nrpo NAME "$DEVICE" | tail -n +2); do
  udisksctl unmount -b "$part" >/dev/null 2>&1 || true
done
if [ -n "${DEVICE_PASSWORD:-}" ]; then
  echo
  echo "  ┌──────────────────────────────────────────────────────────┐"
  echo "  │ Geraetepasswort fuer '$NAME' (jetzt in den Passwort-Manager):"
  echo "  │"
  echo "  │     $DEVICE_PASSWORD"
  echo "  │"
  echo "  │ Es wird nirgends gespeichert und nicht noch einmal angezeigt."
  echo "  └──────────────────────────────────────────────────────────┘"
  echo
fi
if [ -n "$IMAGE" ] && [[ "$(basename "$IMAGE")" == big-kiosk-* ]]; then
  echo "Karte in den Pi '$NAME' stecken, Strom an. Ohne Netz kommt nach 1-2 min"
  echo "der WLAN-Setup-Bildschirm, danach meldet sich der Pi selbst an."
elif [ -n "$SSID" ]; then
  echo "Karte herausnehmen, in den Pi '$NAME' stecken, Strom an."
  echo "Der erste Start dauert 5-15 min."
else
  echo "Karte herausnehmen, in den Pi '$NAME' stecken, LAN-Kabel an, Strom an."
  echo "Der erste Start dauert 5-15 min."
fi
echo "Danach:  ssh $VPS_ALIAS 'sudo fleet manage-pis list'"
