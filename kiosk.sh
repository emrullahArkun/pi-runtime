#!/bin/bash
# ============================================
# Kiosk Launcher - wird beim Boot gestartet
# ============================================

exec > >(tee -a /tmp/kiosk.log) 2>&1
echo "=== kiosk.sh started at $(date) ==="

# Toggle: wenn ~/.use-cog existiert, stattdessen Cog/WPE starten
if [ -f "$HOME/.use-cog" ] && [ -x "$HOME/kiosk-cog.sh" ]; then
  echo "Toggle ~/.use-cog aktiv -> starte kiosk-cog.sh"
  exec "$HOME/kiosk-cog.sh"
fi

# Kiosk-URL: Basis kommt aus /etc/fleet/config (KIOSK_BASE_URL, beim Provisioning
# gesetzt) — bewusst NICHT hardcoded, damit dieses oeffentliche Skript keine
# Projekt-URL preisgibt. ?kiosk=1 = Kiosk-Modus (Cursor aus), &kid=<uuid> = die
# server-vergebene kioskId (von fleet-heartbeat.sh nach /etc/fleet/kiosk-id).
KIOSK_BASE_URL=""
[ -r /etc/fleet/config ] && KIOSK_BASE_URL="$(grep -E '^KIOSK_BASE_URL=' /etc/fleet/config 2>/dev/null | tail -1 | cut -d= -f2-)"
KIOSK_BASE_URL="${KIOSK_BASE_URL%/}"   # evtl. Trailing-Slash weg
if [ -z "$KIOSK_BASE_URL" ]; then
  echo "FEHLER: KIOSK_BASE_URL fehlt in /etc/fleet/config — Pi nicht provisioniert?"
  sleep 10
  exit 1
fi
KIOSK_URL="${KIOSK_BASE_URL}/?kiosk=1"
if [ -r /etc/fleet/kiosk-id ]; then
  KID="$(tr -d '[:space:]' < /etc/fleet/kiosk-id 2>/dev/null || true)"
  [ -n "$KID" ] && KIOSK_URL="${KIOSK_BASE_URL}/?kiosk=1&kid=${KID}"
fi

# Wi-Fi setup (wifi-setup/): while it runs the TV shows its local page, which returns
# to the kiosk once connected. Without the service this is the plain kiosk as before.
START_URL="$KIOSK_URL"
if [ -f /etc/systemd/system/big-wifi-setup.service ]; then
  SETUP_STATE=""
  for _ in $(seq 1 30); do
    SETUP_STATE="$(cat /run/big-wifi-setup/state 2>/dev/null || true)"
    [ -n "$SETUP_STATE" ] && [ "$SETUP_STATE" != "checking" ] && break
    sleep 1
  done
  if [ "$SETUP_STATE" = "setup" ]; then
    NEXT="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$KIOSK_URL")"
    START_URL="http://127.0.0.1/tv.html?next=${NEXT}"
    echo "WLAN-Setup aktiv -> $START_URL"
  fi
fi

# Right after boot switch the TV to this HDMI input (if it is on and speaks CEC).
if [ "$(cut -d. -f1 /proc/uptime)" -lt 300 ] && [ -x /usr/local/sbin/fleet-control ]; then
  SSH_ORIGINAL_COMMAND=tv-input /usr/local/sbin/fleet-control >/dev/null 2>&1 &
fi

CHROMIUM_BIN=""
for candidate in /usr/lib/chromium/chromium /usr/lib/chromium-browser/chromium-browser; do
  if [ -x "$candidate" ]; then CHROMIUM_BIN="$candidate"; break; fi
done
if [ -z "$CHROMIUM_BIN" ]; then
  CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser)"
fi
if [ -z "$CHROMIUM_BIN" ]; then
  echo "FEHLER: chromium nicht gefunden"
  sleep 10
  exit 1
fi
echo "Chromium: $CHROMIUM_BIN"

PREFS="$HOME/.config/chromium/Default/Preferences"
if [ -f "$PREFS" ]; then
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$PREFS"
  sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$PREFS"
fi

# Mauszeiger unsichtbar: transparentes XCursor-Theme (von setup.sh installiert).
# cage zeichnet ohne angeschlossene Maus sonst einen Default-Cursor mittig, den
# das Web-CSS (cursor:none) nicht erreicht. XCURSOR_SIZE bleibt klein als Fallback,
# falls das Theme mal nicht aufloest.
export XCURSOR_THEME=fleet-hidden
export XCURSOR_PATH="$HOME/.icons:/usr/share/icons:/usr/share/pixmaps"
export XCURSOR_SIZE=1

exec cage -d -- "$CHROMIUM_BIN" \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --start-fullscreen \
  --disable-translate \
  --disable-features=TranslateUI \
  --disable-session-crashed-bubble \
  --disable-component-update \
  --autoplay-policy=no-user-gesture-required \
  --check-for-update-interval=31536000 \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --use-gl=egl \
  --enable-features=VaapiVideoDecoder,CanvasOopRasterization \
  --ignore-gpu-blocklist \
  --enable-gpu-rasterization \
  --enable-zero-copy \
  --enable-accelerated-2d-canvas \
  --enable-accelerated-video-decode \
  --enable-hardware-overlays \
  --force-device-scale-factor=1 \
  --disable-smooth-scrolling \
  --disable-background-timer-throttling \
  --disable-renderer-backgrounding \
  "$START_URL"
