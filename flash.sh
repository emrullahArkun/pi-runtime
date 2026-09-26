#!/bin/bash
# Bereitet eine SD-Karte mit Pi OS Lite fuer Zero-Touch-Boot vor.
#
# Voraussetzung: Pi OS Lite ist BEREITS via Raspberry Pi Imager auf die SD
# geflasht (mit SSH enabled + Default-User gesetzt). Dieses Skript fuegt nur
# die Fleet-Onboarding-Dateien zur Boot-Partition hinzu.
#
# WICHTIG — Imager-Einstellungen:
#   - Username:   gebetszeiten-app          (FEST, Fleet-Konvention, siehe api/src/ssh.ts)
#   - Hostname:   <pro Pi frei>   (z.B. merkez, alperenler — identifiziert den Pi)
#   - SSH:        Public-Key oder Passwort, beides geht
#   setup.sh bricht ab, wenn der Username nicht "gebetszeiten-app" ist.
#
# Was passiert:
#   1) Boot-Partition (FAT32, "bootfs") finden + mounten
#   2) fleet-enrollment.txt mit Token + API-URL + Kiosk-URL ablegen
#   3) (optional) wifi.conf mit SSID/PSK/Country ablegen
#   4) Sauber unmounten
#
# Usage:
#   sudo ./flash.sh --device /dev/sdX --token TOKEN \
#                   --api https://<deine-api> --kiosk-url https://<deine-kiosk-app>
#   (optional zusaetzlich: --ssid MeinWLAN --psk passwort123 --country DE)
#
# Tipps:
#   - Device finden: `lsblk` (z.B. /dev/sdX, NICHT /dev/sdX1)
#   - Token erzeugen: `manage-pis add` auf dem VPS

set -euo pipefail

DEVICE=""
TOKEN=""
API_URL=""
KIOSK_BASE_URL=""
SSID=""
PSK=""
COUNTRY=""

usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --device)  DEVICE="$2"; shift 2 ;;
    --token)     TOKEN="$2"; shift 2 ;;
    --api)       API_URL="$2"; shift 2 ;;
    --kiosk-url) KIOSK_BASE_URL="$2"; shift 2 ;;
    --ssid)    SSID="$2"; shift 2 ;;
    --psk)     PSK="$2"; shift 2 ;;
    --country) COUNTRY="$2"; shift 2 ;;
    -h|--help) usage ;;
    *)         echo "Unbekanntes Argument: $1"; usage ;;
  esac
done

if [ -z "$DEVICE" ] || [ -z "$TOKEN" ] || [ -z "$API_URL" ] || [ -z "$KIOSK_BASE_URL" ]; then
  echo "FEHLER: --device, --token, --api und --kiosk-url sind Pflicht."
  usage
fi

if [ "$EUID" -ne 0 ]; then
  echo "FEHLER: bitte mit sudo ausfuehren (mounten braucht root)."
  exit 1
fi

# Device-Sanity: Block-Device, kein partition-suffix.
if [ ! -b "$DEVICE" ]; then
  echo "FEHLER: $DEVICE ist kein Block-Device."
  exit 1
fi
# Robuster Partition-Check: lsblk weiss, ob's ein Whole-Device (disk) oder eine
# Partition (part) ist — die naive "endet auf Ziffer"-Heuristik zickt sonst bei
# mmcblk0 / nvme0n1 (Whole-Device, enden aber auch auf Ziffer).
DEV_TYPE="$(lsblk -no TYPE "$DEVICE" 2>/dev/null | head -1)"
if [ "$DEV_TYPE" = "part" ]; then
  echo "FEHLER: $DEVICE ist eine Partition. Bitte das Root-Device angeben"
  echo "       (z.B. /dev/sdb statt /dev/sdb1, oder /dev/mmcblk0 statt /dev/mmcblk0p1)."
  exit 1
fi

# Boot-Partition finden — bei Pi OS Lite immer erste Partition, FAT32, Label "bootfs".
BOOT_PART=""
for cand in "${DEVICE}1" "${DEVICE}p1"; do
  if [ -b "$cand" ]; then
    BOOT_PART="$cand"
    break
  fi
done
if [ -z "$BOOT_PART" ]; then
  echo "FEHLER: Boot-Partition (${DEVICE}1 oder ${DEVICE}p1) nicht gefunden."
  echo "Ist die SD-Karte schon mit Pi OS Lite geflasht?"
  exit 1
fi

# Falls bereits gemountet (z.B. von Auto-Mount), wir nutzen DEN Mount.
EXISTING_MOUNT="$(findmnt -n -o TARGET --source "$BOOT_PART" 2>/dev/null || true)"
if [ -n "$EXISTING_MOUNT" ]; then
  MOUNT_DIR="$EXISTING_MOUNT"
  WE_MOUNTED=0
  echo "Boot-Partition bereits gemountet: $MOUNT_DIR"
else
  MOUNT_DIR="$(mktemp -d -t flash-boot.XXXXXX)"
  WE_MOUNTED=1
  echo "Mounte $BOOT_PART -> $MOUNT_DIR"
  mount "$BOOT_PART" "$MOUNT_DIR"
fi

ROOT_MOUNT_DIR=""
WE_MOUNTED_ROOT=0
# Aufraeumen auch bei Fehler.
cleanup() {
  if [ "$WE_MOUNTED_ROOT" = "1" ] && [ -n "$ROOT_MOUNT_DIR" ] && mountpoint -q "$ROOT_MOUNT_DIR"; then
    sync
    umount "$ROOT_MOUNT_DIR" || echo "WARN: rootfs umount fehlgeschlagen — bitte manuell pruefen."
    rmdir "$ROOT_MOUNT_DIR" 2>/dev/null || true
  fi
  if [ "$WE_MOUNTED" = "1" ] && mountpoint -q "$MOUNT_DIR"; then
    sync
    umount "$MOUNT_DIR" || echo "WARN: umount fehlgeschlagen — bitte manuell pruefen."
    rmdir "$MOUNT_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Heuristik: ist das wirklich die bootfs-Partition?
if [ ! -f "$MOUNT_DIR/cmdline.txt" ] && [ ! -f "$MOUNT_DIR/config.txt" ]; then
  echo "FEHLER: $MOUNT_DIR sieht nicht nach Pi-Boot-Partition aus (cmdline.txt/config.txt fehlen)."
  exit 1
fi

# --- fleet-enrollment.txt ---
ENROLL_FILE="$MOUNT_DIR/fleet-enrollment.txt"
cat > "$ENROLL_FILE" << EOF
# Auto-generiert von flash.sh am $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Wird von setup.sh gelesen und nach erfolgreicher Registrierung geloescht.
FLEET_API_URL=$API_URL
FLEET_ENROLLMENT_TOKEN=$TOKEN
KIOSK_BASE_URL=$KIOSK_BASE_URL
EOF
chmod 600 "$ENROLL_FILE" 2>/dev/null || true  # FAT32 ignoriert chmod, aber egal
echo "  $ENROLL_FILE geschrieben."

# --- wifi.conf (optional) ---
if [ -n "$SSID" ]; then
  WIFI_FILE="$MOUNT_DIR/wifi.conf"
  {
    echo "# Auto-generiert von flash.sh am $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Wird von wifi-fallback.service beim Boot eingelesen + umbenannt."
    [ -n "$COUNTRY" ] && echo "country=$COUNTRY"
    echo "ssid=$SSID"
    [ -n "$PSK" ] && echo "psk=$PSK"
  } > "$WIFI_FILE"
  chmod 600 "$WIFI_FILE" 2>/dev/null || true
  echo "  $WIFI_FILE geschrieben (SSID: $SSID)."
else
  echo "  wifi.conf: skip (kein --ssid)."
fi

# --- rootfs: First-Boot-Bootstrap installieren ---
# Pi OS Lite hat von Haus aus kein git. Frueher musste man nach dem Imager-
# Firstrun manuell `apt install git && git clone pi-runtime && bash setup.sh`
# tippen — kein Zero-Touch. Loesung: systemd-Oneshot auf der rootfs-Partition,
# der beim zweiten Boot (nach Imager-Firstrun) automatisch git nachzieht,
# pi-runtime klont und setup.sh als gebetszeiten-app startet. Self-disable
# via ConditionPathExists am Sentinel.
ROOT_PART=""
for cand in "${DEVICE}2" "${DEVICE}p2"; do
  if [ -b "$cand" ]; then
    ROOT_PART="$cand"
    break
  fi
done
if [ -z "$ROOT_PART" ]; then
  echo "WARN: rootfs-Partition nicht gefunden — First-Boot-Bootstrap NICHT installiert."
  echo "       Du musst auf dem Pi manuell git installieren + pi-runtime klonen + setup.sh starten."
else
  EXISTING_ROOT_MOUNT="$(findmnt -n -o TARGET --source "$ROOT_PART" 2>/dev/null || true)"
  if [ -n "$EXISTING_ROOT_MOUNT" ]; then
    ROOT_MOUNT_DIR="$EXISTING_ROOT_MOUNT"
    WE_MOUNTED_ROOT=0
    echo "rootfs bereits gemountet: $ROOT_MOUNT_DIR"
  else
    ROOT_MOUNT_DIR="$(mktemp -d -t flash-root.XXXXXX)"
    WE_MOUNTED_ROOT=1
    echo "Mounte $ROOT_PART -> $ROOT_MOUNT_DIR"
    mount "$ROOT_PART" "$ROOT_MOUNT_DIR"
  fi

  # Sanity: sieht das nach Pi-OS rootfs aus?
  if [ ! -d "$ROOT_MOUNT_DIR/etc/systemd/system" ] || [ ! -d "$ROOT_MOUNT_DIR/usr/local/sbin" ]; then
    echo "FEHLER: $ROOT_MOUNT_DIR sieht nicht nach Pi-OS rootfs aus (etc/systemd, usr/local/sbin fehlen)."
    exit 1
  fi

  BOOTSTRAP_SCRIPT="$ROOT_MOUNT_DIR/usr/local/sbin/fleet-bootstrap.sh"
  cat > "$BOOTSTRAP_SCRIPT" << 'BOOTSTRAP_EOF'
#!/bin/bash
# Auto-generiert von flash.sh — laeuft EINMAL beim ersten Boot (nach Imager-
# Firstrun, der den User anlegt). Installiert git, klont pi-runtime, startet
# setup.sh als gebetszeiten-app. Self-disable via Sentinel.
set -e
exec > >(tee -a /var/log/fleet-bootstrap.log) 2>&1
echo "=== fleet-bootstrap started at $(date) ==="

# Netz warten (network-online.target reicht oft nicht — DNS oder Captive-WLAN).
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 -o /dev/null https://github.com 2>/dev/null; then
    echo "Netz ok nach $((i*2))s"
    break
  fi
  sleep 2
done

apt-get update
apt-get install -y --no-install-recommends git ca-certificates

if [ -d /opt/kiosk/.git ]; then
  echo "/opt/kiosk existiert bereits — ueberspringe clone."
else
  git clone https://github.com/emrullahArkun/pi-runtime.git /opt/kiosk
fi

PI_USER="gebetszeiten-app"
USER_HOME="/home/$PI_USER"
if ! id "$PI_USER" >/dev/null 2>&1 || [ ! -d "$USER_HOME" ]; then
  echo "FEHLER: User '$PI_USER' fehlt — Pi Imager Username muss '$PI_USER' sein."
  exit 1
fi
chown -R "$PI_USER:$PI_USER" /opt/kiosk

# setup.sh ruft viel `sudo` auf. Im Bootstrap kann niemand ein Passwort tippen
# -> NOPASSWD muss sitzen. Imager setzt es NICHT automatisch fuer Custom-User
# (frueherer Test "sudo -u $PI_USER -n true" lief faelschlich als root durch
# und sagte gruen). Also bedingungslos temp sudoers, am Ende per Trap weg.
TEMP_SUDOERS="/etc/sudoers.d/010-fleet-bootstrap-tmp"
echo "$PI_USER ALL=(ALL) NOPASSWD: ALL" > "$TEMP_SUDOERS"
chmod 0440 "$TEMP_SUDOERS"
trap 'rm -f "$TEMP_SUDOERS"' EXIT

# setup.sh als gebetszeiten-app laufen lassen — passt zum Guard in setup.sh.
# Eigene scope-limitierte sudoers (90-fleet-control) wird darin selbst angelegt.
sudo -u "$PI_USER" -H bash /opt/kiosk/setup.sh
BOOTSTRAP_EOF
  chmod 0755 "$BOOTSTRAP_SCRIPT"
  echo "  $BOOTSTRAP_SCRIPT geschrieben."

  BOOTSTRAP_UNIT="$ROOT_MOUNT_DIR/etc/systemd/system/fleet-bootstrap.service"
  cat > "$BOOTSTRAP_UNIT" << 'UNIT_EOF'
[Unit]
Description=Fleet first-boot bootstrap (apt git + clone pi-runtime + setup.sh)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/fleet/bootstrap-done

[Service]
Type=oneshot
ExecStartPre=/bin/mkdir -p /var/lib/fleet
ExecStart=/usr/local/sbin/fleet-bootstrap.sh
ExecStartPost=/bin/touch /var/lib/fleet/bootstrap-done
ExecStartPost=/bin/systemctl disable fleet-bootstrap.service
ExecStartPost=/sbin/reboot
StandardOutput=journal
StandardError=journal
# setup.sh macht apt upgrade + viele Pakete (cage, chromium, wireguard, …).
# Auf langsamen SD-Karten / kleinen Pis sind 30min real. Statt zu raten:
# infinity. Falls's haengt, sieht der User's an der bootstrap.log + kann
# manuell reflashen — eine harte Grenze hilft hier nicht, sondern bricht
# nur den happy path.
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
UNIT_EOF
  chmod 0644 "$BOOTSTRAP_UNIT"
  echo "  $BOOTSTRAP_UNIT geschrieben."

  # Symlink im wants-Dir = "enabled". systemctl enable kann man offline so
  # nachbilden, ohne den systemd-Daemon zu beruehren.
  WANTS_DIR="$ROOT_MOUNT_DIR/etc/systemd/system/multi-user.target.wants"
  mkdir -p "$WANTS_DIR"
  ln -sf /etc/systemd/system/fleet-bootstrap.service "$WANTS_DIR/fleet-bootstrap.service"
  echo "  fleet-bootstrap.service aktiviert (multi-user.target.wants)."
fi

echo
echo "Fertig. SD-Karte kann ausgeworfen und in den Pi gesteckt werden."
