#!/bin/bash
# Sets up a fleet kiosk Pi on Raspberry Pi OS Lite.
#
#   (no option)  install and enroll, as the kiosk user (first-boot bootstrap, manual runs)
#   --install    everything that needs no identity; builds the gold image (root, chroot)
#   --enroll     registration, WireGuard, heartbeat, remote control (fleet-enroll, root)
#   --update     nightly run of kiosk-selfupdate.sh (root): --install without upgrading,
#                then the enroll steps that are safe to repeat, never a new registration

set -e

MODE="${1:-all}"
case "$MODE" in
  all|--install|--enroll|--update) ;;
  *) echo "FEHLER: unbekannter Modus '$MODE' (--install, --enroll, --update)."; exit 1 ;;
esac
UPDATE=0; DO_INSTALL=1; DO_ENROLL=1
[ "$MODE" = "--update" ] && UPDATE=1
[ "$MODE" = "--install" ] && DO_ENROLL=0
[ "$MODE" = "--enroll" ] && DO_INSTALL=0

if [ "$EUID" -eq 0 ] && [ "$MODE" = "all" ]; then
  echo "FEHLER: Bitte NICHT als root ausfuehren. Lauf als normaler User mit sudo-Rechten."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The gold image is built in a chroot: units can be enabled there, not started.
IN_CHROOT=0
systemd-detect-virt -q --chroot 2>/dev/null && IN_CHROOT=1

# Fleet-weite Konvention: der Linux-User muss "gebetszeiten-app" heissen. Die API SSHt
# mit diesem fest verdrahteten Namen (siehe api/src/ssh.ts SSH_USER), damit
# sie ohne pro-Pi-Konfig auskommt. Setup.sh wuerde sonst die SSH-Keys ins
# falsche Home schreiben und Remote-Control bricht sofort weg.
EXPECTED_USER="gebetszeiten-app"
if [ "$EUID" -eq 0 ] && [ "$DO_INSTALL" = "1" ] && ! id "$EXPECTED_USER" >/dev/null 2>&1; then
  # Gold image: Raspberry Pi OS ships a locked placeholder user (UID 1000, "pi") that its
  # cloud-init renames on the first start. Renamed here already, cloud-init finds the right
  # name and only sets the password and SSH key; a second user would make it fail.
  PLACEHOLDER="$(getent passwd 1000 | cut -d: -f1)"
  if [ -n "$PLACEHOLDER" ]; then
    usermod -l "$EXPECTED_USER" "$PLACEHOLDER"
    usermod -m -d "/home/$EXPECTED_USER" -s /bin/bash "$EXPECTED_USER"
    groupmod -n "$EXPECTED_USER" "$(getent group 1000 | cut -d: -f1)"
    sed -i "s/^$PLACEHOLDER:/$EXPECTED_USER:/" /etc/subuid /etc/subgid
  else
    useradd -m -s /bin/bash -G sudo,video,render,input,tty "$EXPECTED_USER"
  fi
fi
if [ "$EUID" -eq 0 ]; then
  USERNAME="$EXPECTED_USER"
  USERHOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
  USERUID="$(id -u "$USERNAME")"
else
  USERNAME="$USER"
  USERHOME="$HOME"
  USERUID="$(id -u)"
fi
if [ "$USERNAME" != "$EXPECTED_USER" ] || [ -z "$USERHOME" ]; then
  echo "FEHLER: setup.sh laeuft als '$USERNAME', erwartet aber '$EXPECTED_USER'."
  echo ""
  echo "  Im Pi Imager muss als Username '$EXPECTED_USER' eingestellt sein."
  echo "  Hostname und Pi-Name in der Fleet-DB sind weiterhin frei waehlbar."
  echo "  Bitte SD-Karte mit korrektem Imager-Username neu flashen."
  exit 1
fi

# --- Pi-Modell erkennen ---
# Zero 2W / Pi 3 haben schwaechere GPU und wenig RAM -> gpu_mem=64 ist optimal
# Pi 4 / Pi 5 haben genug RAM -> gpu_mem=128 fuer bessere GPU-Performance + Video-Decode
PI_MODEL="${PI_MODEL:-$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'Unknown')}"
case "$PI_MODEL" in
  *"Pi Zero"*|*"Pi 3"*) GPU_MEM=64 ;;
  *"Pi 4"*|*"Pi 5"*)    GPU_MEM=128 ;;
  *)                    GPU_MEM=64 ;;  # Sicherer Default fuer unbekannte Modelle
esac

echo "=== Raspberry Pi Kiosk Setup ==="
echo "Modell: $PI_MODEL"
echo "User:   $USERNAME (UID $USERUID)"
echo "Home:   $USERHOME"
echo "GPU:    ${GPU_MEM} MB"
[ "$MODE" != "all" ] && echo "Modus:  $MODE"
echo ""

# Never asks: the nightly update and the image build have nobody to answer.
APT=(sudo env DEBIAN_FRONTEND=noninteractive apt-get -q -y -o DPkg::Lock::Timeout=600
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Installs what is missing; never upgrades what is there.
ensure_packages() {
  local missing=() pkg
  for pkg in "$@"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed" || missing+=("$pkg")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  [ "$UPDATE" = "1" ] && "${APT[@]}" update
  "${APT[@]}" install "${missing[@]}"
}

# Files in the kiosk user's home stay theirs when the update runs as root.
own() {
  [ "$EUID" -eq 0 ] && chown "$USERNAME:" "$@"
  return 0
}

if [ "$DO_INSTALL" = "1" ]; then

# Before any kernel update: the image's MODULES=dep picks the drivers of the machine that
# builds the initramfs (the laptop in the image build) and leaves out the display driver
# the boot screen needs.
INITRAMFS_CONF=/etc/initramfs-tools/conf.d/big-kiosk.conf
REBUILD_INITRAMFS=0
if [ "$(cat "$INITRAMFS_CONF" 2>/dev/null)" != "MODULES=most" ]; then
  sudo install -d -m 0755 /etc/initramfs-tools/conf.d
  echo "MODULES=most" | sudo tee "$INITRAMFS_CONF" > /dev/null
  REBUILD_INITRAMFS=1
fi

# --- System updaten ---
if [ "$UPDATE" = "0" ]; then
  echo "[1/8] System updaten..."
  "${APT[@]}" update && "${APT[@]}" full-upgrade
fi

# --- Kiosk-Pakete installieren ---
# cage + chromium = primaerer Kiosk (Wayland-Compositor + Browser)
# cog + wpewebkit = leichtere Alternative fuer schwache Hardware (via ~/.use-cog Toggle)
# v4l-utils = liefert cec-ctl fuer die TV-Steuerung per HDMI-CEC (fleet-control
#   tv-on/tv-off; Port /dev/cec0 ODER /dev/cec1 wird per Auto-Detect gewaehlt,
#   je nachdem an welchem HDMI der TV haengt; Zugriff via video-Gruppe, usermod unten).
# HINWEIS: NICHT zram-tools installieren - Pi OS Bookworm hat zram via
# systemd-zram-setup@zram0 bereits eingebaut, zram-tools wuerde konflikten.
echo "[2/8] Kiosk-Pakete installieren..."
ensure_packages \
  cage \
  chromium \
  cog \
  libwpebackend-fdo-1.0-1 \
  fonts-noto-core \
  fonts-noto-color-emoji \
  grim \
  v4l-utils

# --- Bildschirmschoner / Blanking deaktivieren ---
echo "[3/8] Screen blanking deaktivieren..."
if ! grep -q "consoleblank=0" /boot/firmware/cmdline.txt; then
  sudo sed -i 's/$/ consoleblank=0/' /boot/firmware/cmdline.txt
fi

# --- GPU Memory + HDMI-Hotplug + Watchdog in config.txt setzen ---
# gpu_mem: modellabhaengig (oben gesetzt)
# hdmi_force_hotplug: Display funktioniert auch wenn TV beim Boot aus ist
# dtparam=watchdog=on: Hardware-Watchdog aktivieren (Auto-Reboot bei System-Freeze)
echo "[4/8] config.txt Kiosk-Einstellungen..."
if ! grep -q "^gpu_mem=" /boot/firmware/config.txt; then
  echo "gpu_mem=${GPU_MEM}" | sudo tee -a /boot/firmware/config.txt > /dev/null
else
  sudo sed -i "s/^gpu_mem=.*/gpu_mem=${GPU_MEM}/" /boot/firmware/config.txt
fi
if ! grep -q "^hdmi_force_hotplug=" /boot/firmware/config.txt; then
  echo "hdmi_force_hotplug=1" | sudo tee -a /boot/firmware/config.txt > /dev/null
fi
if ! grep -q "^dtparam=watchdog=on" /boot/firmware/config.txt; then
  echo "dtparam=watchdog=on" | sudo tee -a /boot/firmware/config.txt > /dev/null
fi

# --- Systemd-Watchdog: nach 15s ohne Heartbeat Reboot ausloesen ---
echo "[5/8] Systemd-Watchdog aktivieren..."
sudo sed -i 's/^#*RuntimeWatchdogSec=.*/RuntimeWatchdogSec=15s/' /etc/systemd/system.conf
sudo sed -i 's/^#*RebootWatchdogSec=.*/RebootWatchdogSec=2min/' /etc/systemd/system.conf

# --- User zu noetigen Gruppen hinzufuegen (DRM, Input, TTY) ---
echo "[6/8] User-Gruppen setzen..."
sudo usermod -aG video,render,input,tty "$USERNAME"

# --- Kiosk-Scripts kopieren ---
# kiosk.sh     = Standard (Chromium via Cage/Wayland)
# kiosk-cog.sh = Fallback (Cog + WPE WebKit direkt auf DRM, leichter)
# Umschalten: `touch ~/.use-cog` fuer Cog, `rm ~/.use-cog` zurueck zu Chromium, dann reboot.
echo "[7/8] Kiosk-Scripts einrichten..."
for script in kiosk.sh kiosk-cog.sh; do
  if [ -f "$SCRIPT_DIR/$script" ] && [ "$SCRIPT_DIR/$script" != "$USERHOME/$script" ]; then
    cp "$SCRIPT_DIR/$script" "$USERHOME/$script"
  fi
  [ -f "$USERHOME/$script" ] && chmod +x "$USERHOME/$script" && own "$USERHOME/$script"
done

# --- Transparentes Cursor-Theme (Mauszeiger im Kiosk verstecken) ---
# cage/wlroots zeichnet beim Start einen Default-Cursor in die Bildschirmmitte.
# Ohne angeschlossene Maus gibt es nie ein Pointer-Motion-Event, daher kann das
# Web-CSS (cursor:none) ihn nicht erreichen. Loesung: ein voll transparentes
# XCursor-Theme, das kiosk.sh per XCURSOR_THEME aktiviert. Die Cursor-Datei ist
# ein minimaler 1x1-transparenter Xcursor (vorab lokal erzeugt + verifiziert).
# Idempotent — bei jedem Run neu geschrieben.
echo "[+] Transparentes Cursor-Theme (fleet-hidden)..."
CURSOR_DIR="/usr/share/icons/fleet-hidden/cursors"
sudo install -d -m 0755 "$CURSOR_DIR"
CURSOR_TMP="$(mktemp)"
base64 -d > "$CURSOR_TMP" << 'B64'
WGN1chAAAAAAAAEAAQAAAAIA/f8YAAAAHAAAACQAAAACAP3/GAAAAAEAAAABAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAA=
B64
sudo install -m 0644 "$CURSOR_TMP" "$CURSOR_DIR/left_ptr"
rm -f "$CURSOR_TMP"
# Gaengige Cursor-Namen auf den transparenten Cursor zeigen lassen (relative Links).
for name in default arrow top_left_arrow pointer hand1 hand2 xterm text watch left_ptr_watch; do
  sudo ln -sf left_ptr "$CURSOR_DIR/$name"
done
sudo tee /usr/share/icons/fleet-hidden/index.theme > /dev/null << 'EOF'
[Icon Theme]
Name=fleet-hidden
Comment=Vollstaendig transparenter Cursor fuer Kiosk-Displays
EOF

# Entscheidend: cage/wlroots liest XCURSOR_THEME hier NICHT zuverlaessig, sondern
# laedt das "default"-Cursor-Theme — bzw. einen Built-in-Cursor, wenn gar keins
# existiert (Pi OS Lite hat oft kein Cursor-Theme installiert). Darum legen wir ein
# vollwertiges "default"-Theme mit dem transparenten Cursor DIREKT an (nicht per
# Inherits — das loesen nicht alle wlroots-Versionen auf). Genau diese Variante
# greift auf dem Geraet nachweislich.
DEFAULT_CURSOR_DIR="/usr/share/icons/default/cursors"
sudo install -d -m 0755 "$DEFAULT_CURSOR_DIR"
sudo cp -f "$CURSOR_DIR/left_ptr" "$DEFAULT_CURSOR_DIR/left_ptr"
for name in default arrow top_left_arrow pointer hand1 hand2 xterm text watch left_ptr_watch; do
  sudo ln -sf left_ptr "$DEFAULT_CURSOR_DIR/$name"
done
sudo tee /usr/share/icons/default/index.theme > /dev/null << 'EOF'
[Icon Theme]
Name=Default
Comment=Fleet-Kiosk: transparenter Default-Cursor
EOF

# Belt-and-Suspenders: falls auf einem Pi DOCH ein echtes Cursor-Theme installiert
# ist (z.B. Adwaita) und cage dieses statt "default" laedt, dessen left_ptr/default
# ebenfalls durch den transparenten ersetzen. Eigene Themes ueberspringen, Original
# einmalig als .fleetbak sichern.
for d in /usr/share/icons/*/cursors; do
  [ -d "$d" ] || continue
  case "$d" in */fleet-hidden/cursors|*/default/cursors) continue ;; esac
  for name in left_ptr default; do
    f="$d/$name"
    [ -e "$f" ] || continue
    [ -e "$f.fleetbak" ] || sudo cp -aP "$f" "$f.fleetbak" 2>/dev/null || true
    sudo cp -f "$CURSOR_DIR/left_ptr" "$f"
  done
done

# --- Autologin auf tty1 einrichten ---
echo "[8/8] Autologin auf tty1 + Kiosk-Autostart..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear --noissue %I \$TERM
Type=idle
EOF

# .bash_profile-Hook: auf tty1 automatisch kiosk.sh starten
PROFILE="$USERHOME/.bash_profile"
touch "$PROFILE"
if ! grep -q "kiosk-autostart" "$PROFILE"; then
  cat << 'EOF' >> "$PROFILE"

# kiosk-autostart
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec "$HOME/kiosk.sh"
fi
EOF
fi
own "$PROFILE"
# No login text between the boot screen and the kiosk.
touch "$USERHOME/.hushlogin"
own "$USERHOME/.hushlogin"

# --- Boot screen (Plymouth) instead of boot messages ---
# Same look as the TV setup page. plymouth-quit keeps the last frame until cage takes over
# the screen, so the TV goes from the boot screen straight to the setup page or the kiosk.
echo "[+] Startbildschirm..."
ensure_packages plymouth
THEME_DIR=/usr/share/plymouth/themes/big
THEME_BEFORE="$(cat "$THEME_DIR"/* 2>/dev/null | sha256sum)"
sudo install -d -m 0755 "$THEME_DIR"
sudo install -m 0644 "$SCRIPT_DIR"/splash/big.plymouth "$SCRIPT_DIR"/splash/big.script \
  "$SCRIPT_DIR"/splash/ring.png "$SCRIPT_DIR"/splash/track.png "$THEME_DIR/"
sudo install -m 0644 "$SCRIPT_DIR/wifi-setup/web/big-mark.png" "$THEME_DIR/logo.png"
if [ "$THEME_BEFORE" != "$(cat "$THEME_DIR"/* | sha256sum)" ] || [ "$(plymouth-set-default-theme)" != "big" ]; then
  sudo plymouth-set-default-theme big
  REBUILD_INITRAMFS=1
fi
for flag in quiet splash plymouth.ignore-serial-consoles loglevel=3 logo.nologo vt.global_cursor_default=0; do
  grep -qE "(^| )${flag}( |\$)" /boot/firmware/cmdline.txt || sudo sed -i "1 s/\$/ ${flag}/" /boot/firmware/cmdline.txt
done
grep -q "^disable_splash=" /boot/firmware/config.txt || echo "disable_splash=1" | sudo tee -a /boot/firmware/config.txt > /dev/null
sudo install -d -m 0755 /etc/systemd/system/plymouth-quit.service.d
printf '[Service]\nExecStart=\nExecStart=-/usr/bin/plymouth quit --retain-splash\n' \
  | sudo tee /etc/systemd/system/plymouth-quit.service.d/retain-splash.conf > /dev/null
if [ "$REBUILD_INITRAMFS" = "1" ]; then
  echo "  -> initramfs neu bauen (dauert)..."
  sudo update-initramfs -u -k all
fi

# --- Swap only in RAM ---
# Raspberry Pi OS pages idle memory out to /var/swap on the SD card (zram+file); the kiosk
# keeps its compressed swap in RAM only. /tmp and the journal are in RAM already.
if [ -f /etc/rpi/swap.conf ]; then
  sudo install -d -m 0755 /etc/rpi/swap.conf.d
  printf '[Main]\nMechanism=zram\n' | sudo tee /etc/rpi/swap.conf.d/big-kiosk.conf > /dev/null
fi

# The first-boot wizard of Raspberry Pi OS would ask on tty8 to rename the user.
sudo systemctl disable userconfig.service 2>/dev/null || true

# Alte systemd kiosk.service deaktivieren falls vorhanden (Autologin-Weg ist zuverlaessiger)
sudo systemctl disable kiosk.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/kiosk.service
sudo systemctl daemon-reload

# Boot-Target: multi-user (ohne Desktop)
sudo systemctl set-default multi-user.target

# --- WLAN-Fallback Service (Phase 3 light) ---
# Ermoeglicht "Operator legt /boot/firmware/wifi.conf ab → Pi joint Heim-WLAN
# beim naechsten Boot". Ohne Laptop geht es ueber den Fernseher (wifi-setup/, unten).
# Idempotent: wifi-fallback.sh + .service werden bei jedem setup.sh-Run
# ueberschrieben (deren Konfig steckt in der wifi.conf, nicht im Service).
echo "[+] WLAN-Fallback Service installieren..."
if [ -f "$SCRIPT_DIR/wifi-fallback.sh" ] && [ -f "$SCRIPT_DIR/wifi-fallback.service" ]; then
  sudo install -m 0755 -o root -g root "$SCRIPT_DIR/wifi-fallback.sh" /usr/local/sbin/wifi-fallback.sh
  sudo install -m 0644 -o root -g root "$SCRIPT_DIR/wifi-fallback.service" /etc/systemd/system/wifi-fallback.service
  sudo systemctl daemon-reload
  sudo systemctl enable wifi-fallback.service
  echo "  wifi-fallback.service enabled (feuert nur wenn /boot/firmware/wifi.conf existiert)."
else
  echo "  SKIP: wifi-fallback.sh oder .service fehlt im SCRIPT_DIR."
fi

# --- WLAN-Setup ueber den Fernseher (wifi-setup/) ---
# Ohne WLAN beim Start: eigenes Setup-WLAN, QR-Code auf dem TV, Eingabe am Handy.
echo "[+] WLAN-Setup ueber den Fernseher installieren..."
if [ -f "$SCRIPT_DIR/wifi-setup/wifi_setup.py" ]; then
  ensure_packages qrencode dnsmasq-base iw
  # Without a Wi-Fi country Raspberry Pi OS keeps the radio blocked (no Wi-Fi in the Imager).
  # In the image build flash.sh sets it on the kernel command line instead.
  if [ "$IN_CHROOT" = "0" ]; then
    WIFI_COUNTRY="$(sudo raspi-config nonint get_wifi_country 2>/dev/null || true)"
    if [ -z "$WIFI_COUNTRY" ] || [ "$WIFI_COUNTRY" = "00" ]; then
      sudo raspi-config nonint do_wifi_country DE || echo "  WARN: WLAN-Land nicht gesetzt."
    fi
  fi
  sudo install -d -m 0755 -o root -g root /usr/local/lib/big-wifi-setup/web
  sudo install -m 0755 -o root -g root "$SCRIPT_DIR/wifi-setup/wifi_setup.py" /usr/local/lib/big-wifi-setup/wifi_setup.py
  sudo install -m 0644 -o root -g root "$SCRIPT_DIR"/wifi-setup/web/* /usr/local/lib/big-wifi-setup/web/
  sudo install -m 0644 -o root -g root "$SCRIPT_DIR/wifi-setup/wifi-setup.service" /etc/systemd/system/big-wifi-setup.service
  # Every name resolves to the Pi while the setup Wi-Fi runs, so phones open the setup page
  # (PROBE_ADDR in wifi_setup.py: not a private address, Samsung ignores those).
  sudo install -d -m 0755 /etc/NetworkManager/dnsmasq-shared.d
  echo "address=/#/198.18.0.1" | sudo tee /etc/NetworkManager/dnsmasq-shared.d/big-setup.conf > /dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable big-wifi-setup.service
  echo "  big-wifi-setup.service enabled (greift beim naechsten Start)."
else
  echo "  SKIP: wifi-setup/ fehlt im SCRIPT_DIR."
fi

# --- Enrollment on the first start of a gold image ---
# Waits for internet (after the Wi-Fi setup), then runs `setup.sh --enroll`. Pis that are
# already enrolled have /var/lib/fleet/enrolled (written below) and skip it.
echo "[+] Anmeldung beim ersten Start (fleet-enroll)..."
ensure_packages wireguard wireguard-tools jq curl iw git ca-certificates
sudo install -m 0755 -o root -g root "$SCRIPT_DIR/fleet-enroll.sh" /usr/local/sbin/fleet-enroll.sh
sudo install -m 0644 -o root -g root "$SCRIPT_DIR/fleet-enroll.service" /etc/systemd/system/fleet-enroll.service
sudo systemctl daemon-reload
sudo systemctl enable fleet-enroll.service

# --- Taeglicher Reboot um 03:00 ---
# Plan-Phase-4: Reboot nimmt Memory-Leaks/X-Drift weg, holt geaenderte
# kiosk.sh aus selfupdate-Pull rein. Cron statt systemd-timer weil simpler.
echo "[+] Daily-Reboot Cron (03:00)..."
sudo tee /etc/cron.d/kiosk-daily-reboot > /dev/null << 'EOF'
# Auto-generiert von setup.sh — Pi rebootet taeglich 03:00 lokal.
# Cron-Jobs ohne abschliessenden Newline werden ignoriert!
SHELL=/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root /sbin/reboot
EOF
sudo chmod 644 /etc/cron.d/kiosk-daily-reboot

# --- unattended-upgrades fuer Sicherheits-Patches ---
# Auto-Reboot deaktivieren — der Daily-Cron erledigt das.
echo "[+] unattended-upgrades..."
ensure_packages unattended-upgrades apt-listchanges
sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-pi.conf > /dev/null << 'EOF'
// Auto-generiert von setup.sh — eigene Origins-Liste fuer Raspberry Pi OS.
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Raspbian,codename=${distro_codename},label=Raspbian";
    "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation";
};
// Reboot uebernimmt Daily-Cron um 03:00 — kein doppelter Reboot.
Unattended-Upgrade::Automatic-Reboot "false";
EOF
# 20auto-upgrades aktivieren (sonst laeuft der Timer nicht).
sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- Self-Update ---
# /opt/kiosk = clone of the PUBLIC pi-runtime repo (only the Pi scripts, no secrets).
# kiosk-selfupdate.sh moves it along the channel in /etc/fleet/channel at 02:00 and runs
# `setup.sh --update`; the 03:00 reboot then starts the new state. root runs these
# scripts, so /opt/kiosk belongs to root and the kiosk user cannot change them.
KIOSK_DIST_REPO="https://github.com/emrullahArkun/pi-runtime.git"
echo "[+] Self-Update Cron (Dist: $KIOSK_DIST_REPO)..."
if [ ! -d /opt/kiosk/.git ]; then
  echo "  -> /opt/kiosk frisch clonen..."
  sudo git clone --depth 1 "$KIOSK_DIST_REPO" /opt/kiosk \
    || echo "  WARN: clone fehlgeschlagen (Netz?) — Cron wird trotzdem installiert, holt's spaeter nach."
else
  echo "  -> /opt/kiosk existiert bereits — uebernehme."
fi
if [ -d /opt/kiosk ]; then
  sudo chown -R root:root /opt/kiosk
  sudo chmod -R go-w /opt/kiosk
fi
sudo install -d -m 0755 /etc/fleet
sudo test -f /etc/fleet/channel || echo stable | sudo tee /etc/fleet/channel > /dev/null
sudo install -m 0755 -o root -g root "$SCRIPT_DIR/kiosk-selfupdate.sh" /usr/local/sbin/kiosk-selfupdate.sh
sudo tee /etc/cron.d/kiosk-selfupdate > /dev/null << 'EOF'
# Auto-generiert von setup.sh — naechtliches Update aus pi-runtime, vor dem Reboot um 03:00.
SHELL=/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root /usr/local/sbin/kiosk-selfupdate.sh
EOF
sudo chmod 644 /etc/cron.d/kiosk-selfupdate
sudo touch /var/log/kiosk-update.log
sudo chmod 644 /var/log/kiosk-update.log
echo "  Cron installiert (02:00 daily, Kanal $(cat /etc/fleet/channel), log: /var/log/kiosk-update.log)."

fi # DO_INSTALL

if [ "$DO_ENROLL" = "1" ]; then

# --- Fleet-Setup ---
# Aufgespaltet in vier idempotente Bloecke, damit Re-Run von setup.sh auf einem
# bereits registrierten Pi NICHT alles weiterreicht (= heutiges Verhalten = bug),
# sondern Heartbeat-Service und Remote-Control sauber neu uebernimmt.
#
# A) Pre-Flight   - FLEET_API_URL + CPU_SERIAL aufloesen, Pakete sicherstellen
# B) Registrierung (one-shot, gated by /etc/wireguard/wg0.conf existiert)
# C) Heartbeat-Timer (immer, ueberschreibt Service-File)
# D) Remote-Control (immer, holt aktuellen ssh_pubkey via /pi/server-info)
echo ""
echo "[9/9] Fleet-Setup..."

# ─── Block A: Pre-Flight ──────────────────────────────────────────────
ENROLLMENT_FILE="/boot/firmware/fleet-enrollment.txt"
PERSISTED_CONFIG="/etc/fleet/config"

# Quellen-Prioritaet: ENV > enrollment-file (Erstinstall) > /etc/fleet/config
# (nach Erstregistrierung gecacht, damit Re-Run die URL wieder findet).
# Wir checken explizit auf "schon gesetzt", damit ein vorhandenes ENV nicht
# vom file-source ueberschrieben wird.
if [ -z "${FLEET_API_URL:-}" ] && [ -f "$ENROLLMENT_FILE" ]; then
  # shellcheck disable=SC1090
  . <(sudo grep -E '^(FLEET_API_URL|FLEET_ENROLLMENT_TOKEN|FLEET_HEARTBEAT_URL|KIOSK_BASE_URL)=' "$ENROLLMENT_FILE")
fi
# Token-Source ist immer enrollment-file ODER ENV — niemals der persisted cache.
if [ -z "${FLEET_ENROLLMENT_TOKEN:-}" ] && [ -f "$ENROLLMENT_FILE" ]; then
  # shellcheck disable=SC1090
  . <(sudo grep -E '^FLEET_ENROLLMENT_TOKEN=' "$ENROLLMENT_FILE")
fi
if [ -z "${FLEET_API_URL:-}" ] && sudo test -f "$PERSISTED_CONFIG"; then
  # shellcheck disable=SC1090
  . <(sudo grep -E '^(FLEET_API_URL|FLEET_HEARTBEAT_URL|KIOSK_BASE_URL)=' "$PERSISTED_CONFIG")
fi

# KIOSK_BASE_URL idempotent in der persistenten Config sicherstellen (falls per
# enrollment-Datei oder ENV bekannt) — damit Re-Runs sie nicht verlieren. kiosk.sh
# liest sie von dort, statt sie hartzukodieren (Info-Minimierung).
if [ -n "${KIOSK_BASE_URL:-}" ] && sudo test -f "$PERSISTED_CONFIG" \
   && ! sudo grep -q "^KIOSK_BASE_URL=${KIOSK_BASE_URL}$" "$PERSISTED_CONFIG"; then
  sudo sed -i '/^KIOSK_BASE_URL=/d' "$PERSISTED_CONFIG"
  echo "KIOSK_BASE_URL=$KIOSK_BASE_URL" | sudo tee -a "$PERSISTED_CONFIG" > /dev/null
fi

CPU_SERIAL="$(awk -F': ' '/^Serial/ {print $2; exit}' /proc/cpuinfo || true)"

if [ -z "${FLEET_API_URL:-}" ]; then
  echo "  SKIP: FLEET_API_URL nicht aufloesbar (weder ENV, $ENROLLMENT_FILE, noch $PERSISTED_CONFIG)."
  echo "        Pi laeuft als reiner Kiosk ohne Fleet-Anbindung."
  [ "$MODE" = "--enroll" ] && exit 1
  FLEET_ENABLED=0
elif [ -z "$CPU_SERIAL" ]; then
  echo "  SKIP: CPU-Serial konnte nicht aus /proc/cpuinfo gelesen werden — kein Fleet-Setup."
  FLEET_ENABLED=0
else
  echo "  Pre-Flight: API=$FLEET_API_URL, CPU-Serial=$CPU_SERIAL"
  echo "  -> Pakete sicherstellen (wireguard, jq, curl, iw)..."
  ensure_packages wireguard wireguard-tools jq curl iw
  FLEET_ENABLED=1
fi

# ─── Block B: Registrierung (ONE-SHOT) ────────────────────────────────
# Greift nur, wenn FLEET_ENABLED + Token vorhanden + wg0.conf noch nicht da.
# Re-Runs nach erfolgreicher Erstregistrierung uebersprungen — aber Block C+D
# laufen trotzdem!
if [ "$FLEET_ENABLED" = "1" ] && [ "$UPDATE" = "0" ]; then
  if sudo test -f /etc/wireguard/wg0.conf; then
    echo "  [B] Registrierung uebersprungen (wg0.conf existiert — Pi ist registriert)."
  elif [ -z "${FLEET_ENROLLMENT_TOKEN:-}" ]; then
    echo "  [B] Registrierung uebersprungen (kein FLEET_ENROLLMENT_TOKEN)."
    echo "        Falls Erst-Onboarding: Token via /boot/firmware/fleet-enrollment.txt nachreichen."
  else
    echo "  [B] Erst-Registrierung..."
    echo "  -> WG-Keypair generieren..."
    sudo mkdir -p /etc/wireguard
    sudo chmod 700 /etc/wireguard
    if [ ! -f /etc/wireguard/private.key ]; then
      wg genkey | sudo tee /etc/wireguard/private.key > /dev/null
      sudo chmod 600 /etc/wireguard/private.key
    fi
    PRIV_KEY="$(sudo cat /etc/wireguard/private.key)"
    PUB_KEY="$(echo "$PRIV_KEY" | wg pubkey)"

    echo "  -> POST $FLEET_API_URL/pi/register"
    REG_PAYLOAD="$(jq -n \
      --arg token "$FLEET_ENROLLMENT_TOKEN" \
      --arg serial "$CPU_SERIAL" \
      --arg pubkey "$PUB_KEY" \
      '{enrollment_token: $token, cpu_serial: $serial, wg_pubkey: $pubkey}')"

    REG_RESP="$(curl -fsS -X POST \
      -H "Content-Type: application/json" \
      -d "$REG_PAYLOAD" \
      "$FLEET_API_URL/pi/register" 2>&1)" || {
        echo "FEHLER: Registrierung fehlgeschlagen:"
        echo "$REG_RESP"
        exit 1
      }

    WG_IP="$(echo "$REG_RESP" | jq -r '.wg_ip')"
    SERVER_PUBKEY="$(echo "$REG_RESP" | jq -r '.server_pubkey')"
    SERVER_ENDPOINT="$(echo "$REG_RESP" | jq -r '.server_endpoint')"

    if [ -z "$WG_IP" ] || [ "$WG_IP" = "null" ] || [ -z "$SERVER_PUBKEY" ] || [ "$SERVER_PUBKEY" = "null" ]; then
      echo "FEHLER: Response ungueltig:"
      echo "$REG_RESP"
      exit 1
    fi

    echo "  wg_ip:           $WG_IP"
    echo "  server_endpoint: $SERVER_ENDPOINT"

    # The kiosk shows a waiting screen until it knows its id (kiosk.sh).
    KIOSK_ID="$(echo "$REG_RESP" | jq -r '.kiosk_id // empty')"
    if [ -n "$KIOSK_ID" ]; then
      sudo install -d -m 0755 /etc/fleet
      echo "$KIOSK_ID" | sudo tee /etc/fleet/kiosk-id > /dev/null
      sudo chmod 0644 /etc/fleet/kiosk-id
      sudo pkill -SIGHUP -x cage || sudo pkill -SIGHUP -x cog || true
    fi

    echo "  -> /etc/wireguard/wg0.conf schreiben..."
    sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
# Auto-generiert von setup.sh — nicht manuell editieren.
[Interface]
Address = ${WG_IP}/32
PrivateKey = ${PRIV_KEY}

[Peer]
PublicKey = ${SERVER_PUBKEY}
Endpoint = ${SERVER_ENDPOINT}
# /16 damit der gesamte WG-Range ueber den Tunnel geht (peer-to-peer Pi-Kommunikation
# laeuft ohnehin ueber den Server, aber die Route muss da sein).
AllowedIPs = 10.10.0.0/16
PersistentKeepalive = 25
EOF
    sudo chmod 600 /etc/wireguard/wg0.conf

    echo "  -> wg-quick@wg0 enable + start..."
    sudo systemctl enable wg-quick@wg0
    sudo systemctl restart wg-quick@wg0

    # API-URL + Heartbeat-URL persistieren — ueberlebt Loeschen der enrollment-Datei.
    HEARTBEAT_URL_PERSIST="${FLEET_HEARTBEAT_URL:-http://10.10.0.1:3000}"
    sudo mkdir -p /etc/fleet
    sudo chmod 755 /etc/fleet
    sudo tee "$PERSISTED_CONFIG" > /dev/null << EOF
# Auto-generiert von setup.sh nach erfolgreicher Erst-Registrierung.
# Wird bei Re-Runs gelesen, damit FLEET_API_URL nicht aus dem Boot-FS geholt
# werden muss (das ist nach Erstinstall ja geloescht).
FLEET_API_URL=$FLEET_API_URL
FLEET_HEARTBEAT_URL=$HEARTBEAT_URL_PERSIST
KIOSK_BASE_URL=${KIOSK_BASE_URL:-}
EOF
    sudo chmod 644 "$PERSISTED_CONFIG"

    # Enrollment-Token-File nach erfolgreicher Registrierung loeschen —
    # wird nicht mehr gebraucht und waere beim SD-Karten-Klonen sonst leakbar.
    if [ -f "$ENROLLMENT_FILE" ]; then
      sudo rm -f "$ENROLLMENT_FILE"
    fi
    echo "  [B] Registrierung erfolgreich, $PERSISTED_CONFIG geschrieben."
  fi
fi

# ─── Block C: Heartbeat-Timer (IDEMPOTENT) ────────────────────────────
# Wird bei jedem Run neu geschrieben → Aenderungen am Heartbeat-Pfad oder
# CPU_SERIAL-Verhalten greifen ohne manuelles Eingreifen.
if [ "$FLEET_ENABLED" = "1" ] && sudo test -f /etc/wireguard/wg0.conf; then
  HEARTBEAT_URL="${FLEET_HEARTBEAT_URL:-http://10.10.0.1:3000}"
  echo "  [C] Heartbeat-Timer (Target: $HEARTBEAT_URL)..."

  # Script-File statt Inline-ExecStart: systemd interpretiert Backslash-Escapes
  # in ExecStart-Strings (\t, \n, \\) und verbiegt damit auch unsere \"-Sequenzen
  # im JSON-Payload. Resultat: server bekommt invalid JSON → 400. Mit eigenem
  # bash-Script umgehen wir das systemd-Escaping komplett.
  sudo install -m 0755 -o root -g root "$SCRIPT_DIR/fleet-heartbeat.sh" /usr/local/sbin/fleet-heartbeat.sh

  sudo tee /etc/systemd/system/fleet-heartbeat.service > /dev/null << EOF
[Unit]
Description=Fleet heartbeat (POST /pi/heartbeat über WG-Tunnel)
After=wg-quick@wg0.service network-online.target
Wants=wg-quick@wg0.service

[Service]
Type=oneshot
Environment=FLEET_HEARTBEAT_URL=${HEARTBEAT_URL}
# CPU-Serial wird im Heartbeat mitgeschickt — die API rejected Mismatches (Schutz
# gegen geklonte WG-Configs auf anderer Hardware).
Environment=CPU_SERIAL=${CPU_SERIAL}
ExecStart=/usr/local/sbin/fleet-heartbeat.sh
EOF
  sudo tee /etc/systemd/system/fleet-heartbeat.timer > /dev/null << 'EOF'
[Unit]
Description=Fleet heartbeat every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
# Persistent: wenn Pi down war, direkt nach Boot senden (nicht warten).
Persistent=true

[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now fleet-heartbeat.timer
  # restart triggert die naechste Iteration sofort (Service-File hat sich evtl. geaendert).
  sudo systemctl restart fleet-heartbeat.timer
  # Einmal synchron ausfuehren, damit /etc/fleet/kiosk-id (server-vergebene
  # kioskId) schon vor dem naechsten Kiosk-Start existiert. No-op wenn der
  # Tunnel gerade nicht steht — der Timer holt es dann spaeter nach.
  sudo systemctl start fleet-heartbeat.service || true
fi

# ─── Block D: Remote-Control (IDEMPOTENT) ─────────────────────────────
# Holt aktuellen ssh_pubkey via /pi/server-info, re-installiert fleet-control,
# sudoers, authorized_keys und gleicht den WG-Endpoint mit dem Server-Stand ab.
# Wenn Server unerreichbar: alter Stand bleibt (kein Brick), Warning ausgeben.
if [ "$FLEET_ENABLED" = "1" ] && sudo test -f /etc/wireguard/wg0.conf && [ -f "$SCRIPT_DIR/fleet-control" ]; then
  echo "  [D] Remote-Control sync..."
  # server-info ueber den WG-Tunnel ziehen (nicht public): das SSH-Key-Material
  # liefert der Server nur noch ueber WG aus (Exposure-Reduktion). WG steht zu
  # diesem Zeitpunkt (Block B hat den Tunnel gestartet). Faellt es aus, bleibt der
  # alte Stand und der Self-Healing-Timer (Block D2) zieht die Keys spaeter ueber
  # WG nach. Der Public-FLEET_API_URL liefert nur noch server_pubkey/endpoint.
  KEYINFO_URL="${FLEET_HEARTBEAT_URL:-http://10.10.0.1:3000}"
  INFO_RESP="$(curl -fsS --max-time 10 "$KEYINFO_URL/pi/server-info" 2>&1)" || INFO_RESP=""
  FLEET_SSH_PUBKEY="$(echo "$INFO_RESP" | jq -r '.ssh_pubkey // empty' 2>/dev/null || true)"
  # admin_shell_pubkey ist optional fuer Backward-Compat — neuer Server liefert
  # ihn fuer das Browser-Terminal-Feature, alter Server liefert ihn nicht.
  ADMIN_SHELL_PUBKEY="$(echo "$INFO_RESP" | jq -r '.admin_shell_pubkey // empty' 2>/dev/null || true)"
  SERVER_ENDPOINT_NEW="$(echo "$INFO_RESP" | jq -r '.server_endpoint // empty' 2>/dev/null || true)"

  if [ -z "$FLEET_SSH_PUBKEY" ]; then
    echo "  WARN: /pi/server-info nicht erreichbar oder kein ssh_pubkey — alter Stand bleibt."
  else
    echo "  -> fleet-control nach /usr/local/sbin/..."
    sudo install -m 0755 -o root -g root "$SCRIPT_DIR/fleet-control" /usr/local/sbin/fleet-control

    echo "  -> sudoers (NOPASSWD reboot/pkill/journalctl)..."
    # Minimaler sudo-Scope fuer fleet-control: nur die drei Befehle, keine Globs.
    # visudo -cf erst pruefen, sonst kann ein Tippfehler sudo brick'n.
    SUDOERS_TMP="$(mktemp)"
    cat > "$SUDOERS_TMP" << EOF
# Auto-generated by setup.sh — fleet-control whitelist
$USERNAME ALL=(root) NOPASSWD: /usr/bin/systemctl reboot
$USERNAME ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff
$USERNAME ALL=(root) NOPASSWD: /usr/bin/pkill -SIGHUP -x cage
$USERNAME ALL=(root) NOPASSWD: /usr/bin/pkill -SIGHUP -x cog
$USERNAME ALL=(root) NOPASSWD: /usr/bin/journalctl -n 200 --no-pager
EOF
    if sudo visudo -cf "$SUDOERS_TMP" > /dev/null; then
      sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/90-fleet-control
    else
      echo "FEHLER: fleet-control sudoers ungueltig — Block uebersprungen."
    fi
    rm -f "$SUDOERS_TMP"

    echo "  -> ~/.ssh/authorized_keys mit ForceCommand + (optional) admin-shell..."
    mkdir -p "$USERHOME/.ssh"
    own "$USERHOME/.ssh"
    chmod 700 "$USERHOME/.ssh"
    AUTH_KEYS="$USERHOME/.ssh/authorized_keys"
    touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    # Idempotent: alte Eintraege rauswerfen, frisch schreiben.
    # ZWEI Marker: '# fleet-api' (ForceCommand-Whitelist) und '# admin-shell'
    # (offene Bash-Session via Browser-Terminal). Beide loeschen, beide
    # neu schreiben — sonst drift bei Server-Key-Rotation.
    if grep -q "# fleet-api$" "$AUTH_KEYS" 2>/dev/null; then
      sed -i '/# fleet-api$/{N;d;}' "$AUTH_KEYS"
    fi
    if grep -q "# admin-shell$" "$AUTH_KEYS" 2>/dev/null; then
      sed -i '/# admin-shell$/{N;d;}' "$AUTH_KEYS"
    fi
    {
      echo "# fleet-api"
      echo "command=\"/usr/local/sbin/fleet-control\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $FLEET_SSH_PUBKEY"
    } >> "$AUTH_KEYS"
    if [ -n "$ADMIN_SHELL_PUBKEY" ]; then
      {
        echo "# admin-shell"
        echo "$ADMIN_SHELL_PUBKEY"
      } >> "$AUTH_KEYS"
      echo "  -> admin-shell Pubkey eingetragen (Browser-Terminal aktiv)"
    else
      echo "  -> kein admin_shell_pubkey vom Server — Browser-Terminal deaktiviert"
    fi
    own "$AUTH_KEYS"

    # WG-Endpoint mit dem Server-Stand abgleichen (z.B. nach Umstellung roher IP ->
    # Domain). NUR die Datei anfassen, KEIN wg-quick-Restart: ein falscher Endpoint
    # wuerde sonst den Tunnel — und damit jede Fernsteuerung — sofort kappen (Brick).
    # Die Aenderung greift beim naechsten Reboot (taeglich 03:00, oder dem reboot am
    # Ende dieses Setups). Bewusst nur hier in Block D (manueller Lauf), NICHT im
    # D2-Timer: Endpoint-Auto-Apply waere als Hintergrund-Job zu gefaehrlich.
    if [ -n "$SERVER_ENDPOINT_NEW" ] && [ "$UPDATE" = "0" ]; then
      CUR_ENDPOINT="$(sudo sed -n 's|^Endpoint = ||p' /etc/wireguard/wg0.conf | head -1 || true)"
      if [ -z "$CUR_ENDPOINT" ]; then
        echo "  WARN: kein Endpoint in wg0.conf gefunden — Endpoint-Abgleich uebersprungen."
      elif [ "$CUR_ENDPOINT" != "$SERVER_ENDPOINT_NEW" ]; then
        sudo sed -i "s|^Endpoint = .*|Endpoint = ${SERVER_ENDPOINT_NEW}|" /etc/wireguard/wg0.conf
        echo "  -> WG-Endpoint aktualisiert: $CUR_ENDPOINT -> $SERVER_ENDPOINT_NEW (greift beim naechsten Reboot)"
      else
        echo "  -> WG-Endpoint aktuell ($CUR_ENDPOINT) — kein Update noetig."
      fi
    fi

    echo "  [D] Remote-Control synced."
  fi

  # ─── Block D2: Self-Healing Key-Resync (IDEMPOTENT) ─────────────────
  # Problem 2 (TROUBLESHOOTING.md): rotiert der VPS seine SSH-Keys oder war der
  # Server beim setup.sh-Lauf unerreichbar, fehlt der admin-shell-Pubkey in
  # authorized_keys → Browser-Terminal bricht. Ein Timer gleicht die Keys alle
  # 30min mit /pi/server-info ab und heilt den Drift selbststaendig. Wird immer
  # installiert (auch wenn der Server oben unerreichbar war), damit er spaeter
  # nachziehen kann. Lauf ueber den WG-Tunnel — der admin-shell-Key wird ohnehin
  # nur ueber den Tunnel gebraucht, und so haengt das Healing nicht am Public-DNS.
  echo "  [D2] Self-Healing Key-Resync (Timer)..."
  KEYSYNC_URL="${FLEET_HEARTBEAT_URL:-http://10.10.0.1:3000}"

  sudo install -m 0755 -o root -g root "$SCRIPT_DIR/fleet-keysync.sh" /usr/local/sbin/fleet-keysync.sh

  sudo tee /etc/systemd/system/fleet-keysync.service > /dev/null << EOF
[Unit]
Description=Fleet SSH key resync (gleicht authorized_keys mit /pi/server-info ab)
After=wg-quick@wg0.service network-online.target
Wants=wg-quick@wg0.service

[Service]
Type=oneshot
User=${USERNAME}
Environment=FLEET_SERVER_URL=${KEYSYNC_URL}
ExecStart=/usr/local/sbin/fleet-keysync.sh
EOF
  sudo tee /etc/systemd/system/fleet-keysync.timer > /dev/null << 'EOF'
[Unit]
Description=Fleet SSH key resync alle 30 Minuten

[Timer]
OnBootSec=3min
OnUnitActiveSec=30min
# Persistent: nach Downtime direkt nach Boot abgleichen (nicht warten).
Persistent=true

[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now fleet-keysync.timer
  sudo systemctl restart fleet-keysync.timer
  # Einmal sofort versuchen — heilt den Key auch wenn der Server oben (Block D)
  # gerade unerreichbar war. No-op wenn weiterhin offline.
  sudo systemctl start fleet-keysync.service || true
  echo "  [D2] Key-Resync-Timer aktiv (alle 30min, Target: $KEYSYNC_URL)."
fi

# --- SSH-Haertung: key-only (Passwort-Login uebers Netz aus) ---
# Schliesst die einzige WLAN-Angriffsflaeche des Pi: Port 22 mit Passwort-Auth.
# Wer im Moschee-WLAN ist, kann sonst das gebetszeiten-app-Passwort brute-forcen.
# Normale Fernwartung laeuft eh VPS->Pi durch den WG-Tunnel mit den oben (Block D)
# installierten Keys; der lokale Konsolen-Login (Tastatur+Monitor) nutzt weiter das
# OS-Passwort und bleibt als Notausgang erhalten — PasswordAuthentication betrifft
# NUR SSH, nicht die physische Konsole.
#
# Safety-Guard: nur deaktivieren, wenn mindestens EIN nutzbarer Key in
# authorized_keys steht. Sonst (z.B. Server war beim Setup nicht erreichbar, Block D
# hat keine Keys geschrieben) wuerde der Remote-SSH-Zugang wegbrechen. Greift dann
# beim naechsten Run, sobald die Keys da sind. Zusaetzlich `sshd -t` vor dem Restart:
# kaputte Config -> Drop-in wieder weg, kein Brick.
echo "[+] SSH-Haertung (key-only)..."
SSH_AUTH_KEYS="$USERHOME/.ssh/authorized_keys"
if [ -f "$SSH_AUTH_KEYS" ] && grep -qE '^(ssh-(ed25519|rsa)|ecdsa-|command=)' "$SSH_AUTH_KEYS"; then
  sudo install -d -m 0755 /etc/ssh/sshd_config.d
  # Prefix 00- => wird zuerst gelesen und gewinnt gegen andere Drop-ins: sshd nimmt
  # fuer die meisten Keywords den ERSTEN Wert (z.B. ein Pi-OS-userconf mit "yes").
  SSHD_CONF=/etc/ssh/sshd_config.d/00-fleet-hardening.conf
  SSHD_TMP="$(mktemp)"
  cat > "$SSHD_TMP" << 'EOF'
# Auto-generiert von setup.sh — key-only SSH (Passwort-Brute-Force ueber WLAN dicht).
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  SSHD_CHANGED=1
  sudo cmp -s "$SSHD_TMP" "$SSHD_CONF" && SSHD_CHANGED=0
  sudo install -m 0644 -o root -g root "$SSHD_TMP" "$SSHD_CONF"
  rm -f "$SSHD_TMP"
  if [ "$SSHD_CHANGED" = "0" ]; then
    echo "  -> key-only unveraendert."
  elif sudo sshd -t 2>/dev/null; then
    sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
    echo "  -> Passwort-Login deaktiviert (key-only). Konsolen-Login bleibt Notausgang."
  else
    echo "  WARN: sshd -t fehlgeschlagen — Drop-in entfernt (kein Brick), Passwort-Login bleibt."
    sudo rm -f /etc/ssh/sshd_config.d/00-fleet-hardening.conf
  fi
else
  echo "  SKIP: kein nutzbarer Key in authorized_keys — Passwort-Login bleibt vorerst an"
  echo "        (Schutz vor Aussperren). Greift beim naechsten Run, sobald Keys da sind."
fi

if sudo test -f /etc/wireguard/wg0.conf; then
  sudo install -d -m 0755 /var/lib/fleet
  sudo touch /var/lib/fleet/enrolled
fi

fi # DO_ENROLL

[ "$MODE" = "all" ] || exit 0

echo ""
echo "=== Setup fertig! ==="
echo ""
echo "Kiosk-Basis-URL: $(sudo grep -E '^KIOSK_BASE_URL=' "$PERSISTED_CONFIG" 2>/dev/null | tail -1 | cut -d= -f2- || echo '(nicht gesetzt)')"
echo ""
echo "WICHTIG: Du musst einmal neu einloggen damit die Gruppenrechte greifen,"
echo "oder direkt rebooten:"
echo ""
echo "  sudo reboot"
echo ""
echo "Danach startet der Pi automatisch im Kiosk-Modus."
echo ""
echo "Debug-Befehle (via SSH):"
echo "  Logs ansehen:   journalctl -b -f"
echo "  Kiosk-Log:      cat /tmp/kiosk.log   (bzw. /tmp/kiosk-cog.log)"
echo "  Kiosk killen:   pkill cage           (bzw. pkill cog)"
echo "  URL aendern:    nano $USERHOME/kiosk.sh && sudo reboot"
echo "  Auf Cog toggle: touch ~/.use-cog && sudo reboot"
echo "  Auf Chromium:   rm ~/.use-cog && sudo reboot"
echo "  RAM pruefen:    free -h"
