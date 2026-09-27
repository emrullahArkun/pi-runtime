#!/bin/bash
# Liest /boot/firmware/wifi.conf (FAT32, von jedem OS schreibbar) und legt
# daraus ein NetworkManager-Profil an. Rettet Setup-Faelle wo das Captive-Portal
# vom Handy weggeschmissen wird (siehe fleet-management-plan.md Phase 3).
#
# Format der wifi.conf:
#   country=DE
#   ssid=MeinWLAN
#   psk=passwort123     # optional fuer offene Netze
#
# Wird per wifi-fallback.service beim Boot gestartet (ConditionPathExists),
# laeuft nur wenn die Datei existiert. Nach Anwendung wird die Datei mit
# Timestamp umbenannt — kein Loeschen, damit der Operator sieht ob/wann
# das Onboarding griff.

set -euo pipefail

WIFI_CONF="/boot/firmware/wifi.conf"
[ -f "$WIFI_CONF" ] || exit 0

log() { echo "[wifi-fallback] $*"; }

SSID=""
PSK=""
COUNTRY=""
while IFS='=' read -r key value; do
  # CR von Windows-Editoren strippen
  key="${key//$'\r'/}"
  value="${value//$'\r'/}"
  # Comments + leere Zeilen ignorieren
  case "$key" in ''|'#'*) continue ;; esac
  case "$key" in
    ssid)    SSID="$value" ;;
    psk)     PSK="$value" ;;
    country) COUNTRY="$value" ;;
  esac
done < "$WIFI_CONF"

if [ -z "$SSID" ]; then
  log "FEHLER: keine ssid= in $WIFI_CONF"
  exit 1
fi

# Country-Code ist regulatorisch wichtig (sonst nutzt der Pi nur 2.4 GHz default-channels).
if [ -n "$COUNTRY" ] && command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_wifi_country "$COUNTRY" || log "WARN: do_wifi_country $COUNTRY fehlgeschlagen"
fi

PROFILE_NAME="wifi-fallback"

# Vorhandenes Profil mit gleichem Namen entfernen — damit Re-Trigger via wifi.conf
# (Operator legt Datei erneut ab) sauber das alte Profil ersetzt.
nmcli con delete "$PROFILE_NAME" 2>/dev/null || true

if [ -n "$PSK" ]; then
  # pmf=2 (optional) deckt sowohl reines WPA2 als auch WPA2+WPA3-Transition
  # auf modernen FritzBoxen ab. Ohne pmf-Setting verweigern manche APs die
  # Assoziation, weil sie Management-Frame-Protection erwarten.
  nmcli con add type wifi ifname '*' con-name "$PROFILE_NAME" ssid "$SSID" \
    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" \
    wifi-sec.pmf 2 \
    connection.autoconnect yes
else
  nmcli con add type wifi ifname '*' con-name "$PROFILE_NAME" ssid "$SSID" \
    connection.autoconnect yes
fi

log "Profil '$PROFILE_NAME' fuer SSID '$SSID' angelegt."

# Direkt verbinden (best-effort — wenn schon online via anderem Profil, ok).
nmcli con up "$PROFILE_NAME" || log "WARN: con up $PROFILE_NAME fehlgeschlagen — vermutlich anderes Netz aktiv."

# Datei mit Timestamp umbenennen (audit trail, kein Re-Trigger beim naechsten Boot).
TS="$(date -u +%Y%m%dT%H%M%SZ)"
mv "$WIFI_CONF" "${WIFI_CONF}.applied.${TS}"
log "wifi.conf -> wifi.conf.applied.${TS}"
