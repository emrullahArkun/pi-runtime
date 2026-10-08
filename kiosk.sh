#!/bin/bash
# ============================================
# Kiosk Launcher - wird beim Boot gestartet
# ============================================

# Only into the log: the TV shows tty1 until the browser is up.
exec >> /tmp/kiosk.log 2>&1
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
for conf in /etc/fleet/config /boot/firmware/fleet-enrollment.txt; do
  # The enrollment file of a fresh gold image carries it until fleet-enroll has run.
  [ -z "$KIOSK_BASE_URL" ] && [ -r "$conf" ] && KIOSK_BASE_URL="$(grep -E '^KIOSK_BASE_URL=' "$conf" 2>/dev/null | tail -1 | cut -d= -f2-)"
done
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
# Not enrolled yet (fresh gold image): a waiting screen instead of a pairing QR code for
# the wrong kiosk; the heartbeat restarts the kiosk once the id is there.
if [ -z "${KID:-}" ] && [ -f /boot/firmware/fleet-enrollment.txt ]; then
  KIOSK_URL="${KIOSK_URL}&enrolling=1"
fi

# Wi-Fi setup (wifi-setup/): while its service decides or runs, the TV shows its local
# page (boot screen, then the setup), which moves on to the kiosk by itself. Without the
# service this is the plain kiosk as before.
START_URL="$KIOSK_URL"
if [ -f /etc/systemd/system/big-wifi-setup.service ]; then
  for _ in $(seq 1 20); do
    [ "$(cat /run/big-wifi-setup/state 2>/dev/null || true)" = "online" ] && break
    if curl -fsS -o /dev/null --max-time 1 http://127.0.0.1/api/state 2>/dev/null; then
      NEXT="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$KIOSK_URL")"
      START_URL="http://127.0.0.1/tv.html?next=${NEXT}"
      echo "WLAN-Setup-Seite -> $START_URL"
      break
    fi
    sleep 1
  done
fi
# A fresh Wi-Fi connection can take a moment before the kiosk is reachable, and Chromium
# never reloads its error page. Offline (no answer within a minute) the service worker
# serves the cached kiosk anyway.
if [ "$START_URL" = "$KIOSK_URL" ]; then
  for _ in $(seq 1 20); do
    curl -fsS -o /dev/null --max-time 3 "$KIOSK_BASE_URL/" 2>/dev/null && break
    sleep 2
  done
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

# HTTP cache in RAM (/tmp is tmpfs) to spare the SD card; the offline copy of the kiosk
# lives in the service worker storage of the profile and survives reboots.
# 4K TVs often prefer 4096x2160, wider than 16:9 (the kiosk then gets side borders), and
# make the Pi draw four times the pixels. Inside cage, every output that offers 1920x1080
# switches to it before the browser starts (the first such mode has the highest refresh
# rate); others keep their mode.
exec cage -d -- /bin/sh -c '
  if command -v wlr-randr >/dev/null; then
    for out in $(wlr-randr 2>/dev/null | sed -n "s/^\([^ ]\+\) .*/\1/p"); do
      wlr-randr --output "$out" --mode 1920x1080 >/dev/null 2>&1 || true
    done
  fi
  exec "$@"' kiosk-output "$CHROMIUM_BIN" \
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
  --disk-cache-dir=/tmp/chromium-cache \
  --disk-cache-size=67108864 \
  "$START_URL"
