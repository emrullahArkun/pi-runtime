#!/bin/bash
# provision-pi.sh — one command from an empty SD card to a fleet Pi.
#
# Asks for what it needs (name, device password, optionally the Wi-Fi for the first
# start), downloads and verifies Raspberry Pi OS Lite (64-bit), creates the Pi's slot
# on the server and writes everything to the card: OS, cloud-init user-data (user
# gebetszeiten-app, hostname, your SSH key) and the fleet enrollment.
# No Raspberry Pi Imager needed.
#
# Usage:
#   ./provision-pi.sh [--name merkez] [--device /dev/sdX] [--ssh-key ~/.ssh/id_ed25519.pub]
#                     [--ssid WLAN --psk pw] [--image os.img.xz] [--no-os]
#   --no-os   the card was already flashed with the Imager (old way): only adds the
#             enrollment and the first-boot bootstrap.
#
# Run WITHOUT sudo (the server connection uses your SSH key); the script calls sudo
# itself for writing the card.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/fleet.conf"
PI_USER="gebetszeiten-app"
OS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/big-kiosk"

NAME=""
DEVICE=""
SSID=""
PSK=""
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
IMAGE=""
WRITE_OS=1

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
  echo "Geraetepasswort fuer '$PI_USER' (fuer sudo im Panel-Terminal; am besten aus dem Passwort-Manager):"
  while :; do
    read -r -s -p "  Passwort: " PW; echo
    read -r -s -p "  Nochmal:  " PW2; echo
    if [ "${#PW}" -lt 12 ]; then echo "  Mindestens 12 Zeichen."; continue; fi
    [ "$PW" = "$PW2" ] && break
    echo "  Stimmt nicht ueberein."
  done
  PW_HASH="$(openssl passwd -6 -stdin <<< "$PW")"
  unset PW PW2
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
  echo "  System:      Raspberry Pi OS Lite 64-bit, wird frisch geschrieben"
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
  URL="$(curl -fsIL -o /dev/null -w '%{url_effective}' "$OS_URL")"
  IMAGE="$CACHE_DIR/$(basename "$URL")"
  curl -fsL "$URL.sha256" -o "$IMAGE.sha256"
  if ! (cd "$CACHE_DIR" && sha256sum -c --quiet "$(basename "$IMAGE").sha256" 2>/dev/null); then
    echo "  Lade $(basename "$URL") ..."
    curl -fL --progress-bar "$URL" -o "$IMAGE"
    (cd "$CACHE_DIR" && sha256sum -c --quiet "$(basename "$IMAGE").sha256") \
      || { echo "FEHLER: Pruefsumme stimmt nicht, Download kaputt."; rm -f "$IMAGE"; exit 1; }
  fi
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
packages:
- avahi-daemon
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
  passwd: "$PW_HASH"
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
if [ -n "$SSID" ]; then
  echo "Karte herausnehmen, in den Pi '$NAME' stecken, Strom an."
else
  echo "Karte herausnehmen, in den Pi '$NAME' stecken, LAN-Kabel an, Strom an."
fi
echo "Der erste Start dauert 5-15 min. Danach:  ssh $VPS_ALIAS 'sudo fleet manage-pis list'"
