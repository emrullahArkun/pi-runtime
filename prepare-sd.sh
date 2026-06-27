#!/bin/bash
# Workaround fuer den Raspberry-Pi-Imager-Bug, bei dem "Custom Settings"
# (User, WLAN, SSH, Hostname) still unter den Tisch fallen — kein firstrun.sh
# auf der SD obwohl der Imager "Schreiben erfolgreich" sagt.
#
# Ansatz: alles direkt in bootfs + rootfs schreiben, kein firstrun.sh-Hack.
# Grund: init_resize.sh (Pi-Erstboot-Partition-Expand) ueberschreibt cmdline.txt
# und wirft systemd.run-Eintraege raus -> Hooks via cmdline sind unzuverlaessig.
#
# Voraussetzung: Pi OS Lite ist BEREITS via Imager auf die SD geflasht.
# Sowohl bootfs als auch rootfs muessen im Laptop gemountet sein (Auto-Mount).
#
# Usage:
#   sudo ./prepare-sd.sh \
#     --hostname kiosk-test \
#     --user gebetszeiten-pi \
#     --password 'meinPasswort' \
#     --ssid 'MeinWLAN' \
#     --psk 'wlanPasswort'
#
# Optional:
#   --device /dev/sdX     (sonst Auto-Detect der gemounteten bootfs/rootfs)
#   --country DE          (Default: DE)
#   --timezone Europe/Berlin
#   --keyboard de
#
# Was passiert:
#   bootfs:
#     1) `ssh` (leere Datei)        -> SSH-Daemon auto-aktivieren
#     2) `userconf.txt`             -> User + gehashtes Passwort
#   rootfs:
#     3) /etc/hostname              -> Hostname
#     4) /etc/hosts                 -> 127.0.1.1 mapping
#     5) /etc/NetworkManager/system-connections/home-wifi.nmconnection
#                                   -> WLAN-Verbindung (auto-connect)
#     6) /etc/localtime symlink     -> Timezone
#     7) /etc/timezone              -> Timezone-Name
#     8) /etc/default/keyboard      -> Keyboard-Layout
#
# Nach Boot:
#   - Pi vergibt sich seinen Hostnamen, NetworkManager waehlt sich automatisch
#     ins WLAN ein. Erster Boot dauert wegen init_resize + Konfig ~2min.
#   - Pi taucht in der FritzBox als <hostname> auf.
#   - SSH: ssh <user>@<hostname>.local
#
# Re-Run: idempotent. Ueberschreibt existierende Files.

set -euo pipefail

HOSTNAME=""
USER_NAME=""
USER_PW=""
SSID=""
PSK=""
COUNTRY="DE"
TIMEZONE="Europe/Berlin"
KEYBOARD="de"
DEVICE=""

usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname)  HOSTNAME="$2"; shift 2 ;;
    --user)      USER_NAME="$2"; shift 2 ;;
    --password)  USER_PW="$2"; shift 2 ;;
    --ssid)      SSID="$2"; shift 2 ;;
    --psk)       PSK="$2"; shift 2 ;;
    --country)   COUNTRY="$2"; shift 2 ;;
    --timezone)  TIMEZONE="$2"; shift 2 ;;
    --keyboard)  KEYBOARD="$2"; shift 2 ;;
    --device)    DEVICE="$2"; shift 2 ;;
    -h|--help)   usage ;;
    *)           echo "Unbekanntes Argument: $1"; usage ;;
  esac
done

# --- Pflicht-Argumente ---
MISSING=()
[ -z "$HOSTNAME" ]  && MISSING+=("--hostname")
[ -z "$USER_NAME" ] && MISSING+=("--user")
[ -z "$USER_PW" ]   && MISSING+=("--password")
[ -z "$SSID" ]      && MISSING+=("--ssid")
[ -z "$PSK" ]       && MISSING+=("--psk")
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "FEHLER: fehlende Pflicht-Parameter: ${MISSING[*]}"
  echo
  usage
fi

if [ "$EUID" -ne 0 ]; then
  echo "FEHLER: bitte mit sudo ausfuehren (Schreiben in rootfs braucht root)."
  exit 1
fi

# --- Dependencies ---
for cmd in openssl findmnt; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "FEHLER: '$cmd' nicht gefunden. Bitte installieren."
    exit 1
  fi
done

# --- bootfs + rootfs finden ---
BOOT_DIR=""
ROOT_DIR=""
WE_MOUNTED_BOOT=0
WE_MOUNTED_ROOT=0

find_part_in_mounts() {
  # $1 = fstype (vfat oder ext4), $2 = file-marker zum Identifizieren
  local fstype="$1" marker="$2"
  while IFS= read -r line; do
    if [ -e "$line/$marker" ]; then
      echo "$line"
      return 0
    fi
  done < <(findmnt -rn -t "$fstype" -o TARGET 2>/dev/null | grep -E "/(media|run/media)/" || true)
  return 1
}

if [ -n "$DEVICE" ]; then
  # Explizit: bootfs = ${DEVICE}1 oder p1, rootfs = ${DEVICE}2 oder p2
  if [ ! -b "$DEVICE" ]; then
    echo "FEHLER: $DEVICE ist kein Block-Device."; exit 1
  fi
  case "$DEVICE" in
    *[0-9]) echo "FEHLER: $DEVICE sieht aus wie eine Partition. Root-Device angeben."; exit 1 ;;
  esac
  for cand1 in "${DEVICE}1" "${DEVICE}p1"; do
    [ -b "$cand1" ] && BOOT_PART="$cand1" && break
  done
  for cand2 in "${DEVICE}2" "${DEVICE}p2"; do
    [ -b "$cand2" ] && ROOT_PART="$cand2" && break
  done
  if [ -z "${BOOT_PART:-}" ] || [ -z "${ROOT_PART:-}" ]; then
    echo "FEHLER: Partitionen zu $DEVICE nicht gefunden."; exit 1
  fi
  # Mount falls nicht gemountet
  BOOT_DIR="$(findmnt -n -o TARGET --source "$BOOT_PART" 2>/dev/null || true)"
  if [ -z "$BOOT_DIR" ]; then
    BOOT_DIR="$(mktemp -d -t prep-boot.XXXXXX)"
    mount "$BOOT_PART" "$BOOT_DIR"
    WE_MOUNTED_BOOT=1
  fi
  ROOT_DIR="$(findmnt -n -o TARGET --source "$ROOT_PART" 2>/dev/null || true)"
  if [ -z "$ROOT_DIR" ]; then
    ROOT_DIR="$(mktemp -d -t prep-root.XXXXXX)"
    mount "$ROOT_PART" "$ROOT_DIR"
    WE_MOUNTED_ROOT=1
  fi
else
  # Auto-Detect via Marker-Files
  BOOT_DIR="$(find_part_in_mounts vfat "cmdline.txt" || true)"
  ROOT_DIR="$(find_part_in_mounts ext4 "etc/passwd" || true)"
  if [ -z "$BOOT_DIR" ] || [ -z "$ROOT_DIR" ]; then
    echo "FEHLER: bootfs oder rootfs nicht gemountet."
    echo "       bootfs gefunden: ${BOOT_DIR:-<nichts>}"
    echo "       rootfs gefunden: ${ROOT_DIR:-<nichts>}"
    echo "       SD-Karte einstecken und warten bis beide Partitionen automounten,"
    echo "       oder --device /dev/sdX explizit angeben."
    exit 1
  fi
fi

cleanup() {
  if [ "$WE_MOUNTED_BOOT" = "1" ] && mountpoint -q "$BOOT_DIR"; then
    sync; umount "$BOOT_DIR" 2>/dev/null || true; rmdir "$BOOT_DIR" 2>/dev/null || true
  fi
  if [ "$WE_MOUNTED_ROOT" = "1" ] && mountpoint -q "$ROOT_DIR"; then
    sync; umount "$ROOT_DIR" 2>/dev/null || true; rmdir "$ROOT_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Sanity-Checks
if [ ! -f "$BOOT_DIR/cmdline.txt" ] || [ ! -f "$BOOT_DIR/config.txt" ]; then
  echo "FEHLER: $BOOT_DIR sieht nicht nach Pi-Boot-Partition aus."; exit 1
fi
if [ ! -f "$ROOT_DIR/etc/passwd" ] || [ ! -d "$ROOT_DIR/etc/NetworkManager" ]; then
  echo "FEHLER: $ROOT_DIR sieht nicht nach Pi-rootfs aus (etc/passwd oder etc/NetworkManager fehlt)."
  exit 1
fi

echo "=== Vorbereitung ==="
echo "  bootfs:    $BOOT_DIR"
echo "  rootfs:    $ROOT_DIR"
echo "  hostname:  $HOSTNAME"
echo "  user:      $USER_NAME"
echo "  wifi:      $SSID (country=$COUNTRY)"
echo "  timezone:  $TIMEZONE"
echo "  keyboard:  $KEYBOARD"
echo

# Falls noch ein alter firstrun.sh-Hack rumliegt: aufraeumen
if [ -f "$BOOT_DIR/firstrun.sh" ]; then
  echo "  (alter firstrun.sh in bootfs gefunden -> wird entfernt)"
  rm -f "$BOOT_DIR/firstrun.sh"
  sed -i 's| systemd.run=[^ ]*||g; s| systemd.run_success_action=[^ ]*||g' "$BOOT_DIR/cmdline.txt"
fi

# --- bootfs: SSH + userconf ---

echo "[1/8] bootfs/ssh anlegen (SSH-Daemon aktivieren)..."
touch "$BOOT_DIR/ssh"

# Nur schreiben wenn nicht schon vom userconfig.service konsumiert
echo "[2/8] bootfs/userconf.txt anlegen (User + gehashtes PW)..."
PW_HASH="$(openssl passwd -6 "$USER_PW")"
printf '%s:%s\n' "$USER_NAME" "$PW_HASH" > "$BOOT_DIR/userconf.txt"

# --- rootfs: hostname ---

echo "[3/8] rootfs/etc/hostname setzen..."
printf '%s\n' "$HOSTNAME" > "$ROOT_DIR/etc/hostname"

echo "[4/8] rootfs/etc/hosts patchen..."
HOSTS_FILE="$ROOT_DIR/etc/hosts"
if grep -qE "^127\.0\.1\.1\s" "$HOSTS_FILE" 2>/dev/null; then
  sed -i "s/^127\.0\.1\.1\s.*/127.0.1.1\t${HOSTNAME}/" "$HOSTS_FILE"
else
  printf '127.0.1.1\t%s\n' "$HOSTNAME" >> "$HOSTS_FILE"
fi

# --- rootfs: WLAN via project-eigener wifi-fallback Mechanismus ---
# Nutzt die battle-tested Pipeline aus infra/raspberry/:
#   1) wifi-fallback.sh + .service auf rootfs kopieren
#   2) Service via Symlink in multi-user.target.wants enablen
#   3) wifi.conf in bootfs ablegen mit SSID/PSK
# Beim Boot liest die Service-Unit die wifi.conf, legt per nmcli die
# NM-Connection an, setzt raspi-config wifi-country, und benennt die
# wifi.conf nach Anwendung um (Audit-Trail).

echo "[5/8] WLAN ueber Project-wifi-fallback aktivieren..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIFI_FB_SH="$SCRIPT_DIR/wifi-fallback.sh"
WIFI_FB_SVC="$SCRIPT_DIR/wifi-fallback.service"

if [ ! -f "$WIFI_FB_SH" ] || [ ! -f "$WIFI_FB_SVC" ]; then
  echo "FEHLER: wifi-fallback.sh oder .service nicht in $SCRIPT_DIR gefunden."
  exit 1
fi

# wifi-fallback.sh nach /usr/local/sbin/ auf rootfs
install -d -m 0755 -o root -g root "$ROOT_DIR/usr/local/sbin"
install -m 0755 -o root -g root "$WIFI_FB_SH" "$ROOT_DIR/usr/local/sbin/wifi-fallback.sh"

# wifi-fallback.service nach /etc/systemd/system/ auf rootfs
install -d -m 0755 -o root -g root "$ROOT_DIR/etc/systemd/system"
install -m 0644 -o root -g root "$WIFI_FB_SVC" "$ROOT_DIR/etc/systemd/system/wifi-fallback.service"

# Service enablen via Symlink (offline-equivalent zu `systemctl enable`)
install -d -m 0755 -o root -g root "$ROOT_DIR/etc/systemd/system/multi-user.target.wants"
ln -sf "/etc/systemd/system/wifi-fallback.service" \
  "$ROOT_DIR/etc/systemd/system/multi-user.target.wants/wifi-fallback.service"

# wifi.conf in bootfs ablegen — wird vom Service beim Boot konsumiert
WIFI_CONF="$BOOT_DIR/wifi.conf"
{
  printf '# Auto-generiert von prepare-sd.sh am %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# Wird von wifi-fallback.service beim Boot eingelesen + umbenannt.\n'
  printf 'country=%s\n' "$COUNTRY"
  printf 'ssid=%s\n' "$SSID"
  printf 'psk=%s\n' "$PSK"
} > "$WIFI_CONF"
chmod 0600 "$WIFI_CONF" 2>/dev/null || true

# Alte .nmconnection von Vorgaenger-Version aufraeumen falls vorhanden
rm -f "$ROOT_DIR/etc/NetworkManager/system-connections/home-wifi.nmconnection"

# --- rootfs: Timezone ---

echo "[6/8] rootfs Timezone $TIMEZONE setzen..."
if [ -f "$ROOT_DIR/usr/share/zoneinfo/$TIMEZONE" ]; then
  rm -f "$ROOT_DIR/etc/localtime"
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$ROOT_DIR/etc/localtime"
  printf '%s\n' "$TIMEZONE" > "$ROOT_DIR/etc/timezone"
else
  echo "  WARN: zoneinfo/$TIMEZONE im rootfs nicht gefunden — skip."
fi

# --- rootfs: Keyboard ---

echo "[7/8] rootfs Keyboard-Layout $KEYBOARD setzen..."
cat > "$ROOT_DIR/etc/default/keyboard" << EOF
XKBMODEL="pc105"
XKBLAYOUT="${KEYBOARD}"
XKBVARIANT=""
XKBOPTIONS=""

BACKSPACE="guess"
EOF

# --- Persistent Journal aktivieren ---
# Bookworm-Default: journalctl-Logs landen in /run (tmpfs, weg nach Reboot).
# Damit wir bei WLAN-Fehlern nachsehen koennen, journald explizit auf disk
# umstellen — Directory anlegen + Storage=persistent in journald.conf.d.
echo "[8/8] Persistent Journal aktivieren..."
install -d -m 2755 -o root -g systemd-journal "$ROOT_DIR/var/log/journal" 2>/dev/null \
  || install -d -m 0755 "$ROOT_DIR/var/log/journal"

install -d -m 0755 -o root -g root "$ROOT_DIR/etc/systemd/journald.conf.d"
cat > "$ROOT_DIR/etc/systemd/journald.conf.d/10-persistent.conf" << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=200M
EOF

# --- WLAN-Country zusaetzlich global setzen (manche Tools brauchen das) ---
# raspi-config liest /etc/default/crda oder vergleichbares. Wir setzen das via
# regulatory.bin / cfg80211 conf — der cmdline-Eintrag cfg80211.ieee80211_regdom
# ist eh schon im Pi-Default und gilt.
if [ -d "$ROOT_DIR/etc/default" ]; then
  : > /dev/null
fi

echo
echo "=== Verify ==="
echo "bootfs:"
ls -la "$BOOT_DIR/" | grep -E "ssh|userconf" || true
echo
echo "rootfs/etc/hostname:"
cat "$ROOT_DIR/etc/hostname"
echo
echo "rootfs/etc/NetworkManager/system-connections/:"
ls -la "$ROOT_DIR/etc/NetworkManager/system-connections/"
echo
echo "rootfs/etc/timezone:"
cat "$ROOT_DIR/etc/timezone" 2>/dev/null || echo "(nicht gesetzt)"
echo
echo "=== Fertig ==="
echo "SD-Karte sauber auswerfen (Datei-Manager / 'sync; udisksctl power-off')."
echo "Dann in den Pi, Strom dran."
echo "Erster Boot dauert ~90s (init_resize beim allerersten Mal, danach ~30s)."
echo "Pi taucht als '${HOSTNAME}' in der FritzBox auf."
echo "SSH: ssh ${USER_NAME}@${HOSTNAME}.local"
