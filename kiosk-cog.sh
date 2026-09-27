#!/bin/bash
# ============================================
# Kiosk-Alternative: Cog + WPE WebKit (leichter als Chromium)
# Stufe 2 aus TEST-PLAN.md
# ============================================

exec > >(tee -a /tmp/kiosk-cog.log) 2>&1
echo "=== kiosk-cog.sh started at $(date) ==="

# Kiosk-URL aus /etc/fleet/config (KIOSK_BASE_URL, Provisioning — nicht hardcoded,
# siehe kiosk.sh). ?kiosk=1 = Kiosk-Modus, &kid=<uuid> = server-vergebene kioskId.
KIOSK_BASE_URL=""
[ -r /etc/fleet/config ] && KIOSK_BASE_URL="$(grep -E '^KIOSK_BASE_URL=' /etc/fleet/config 2>/dev/null | tail -1 | cut -d= -f2-)"
KIOSK_BASE_URL="${KIOSK_BASE_URL%/}"
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

COG_BIN="$(command -v cog)"
if [ -z "$COG_BIN" ]; then
  echo "FEHLER: cog nicht gefunden."
  echo "Installieren mit: sudo apt install -y cog libwpebackend-fdo-1.0-1"
  sleep 10
  exit 1
fi
echo "Cog: $COG_BIN"

# Mauszeiger unsichtbar: transparentes XCursor-Theme (von setup.sh installiert) —
# gleiche Begruendung wie in kiosk.sh.
export XCURSOR_THEME=fleet-hidden
export XCURSOR_PATH="$HOME/.icons:/usr/share/icons:/usr/share/pixmaps"
export XCURSOR_SIZE=1

exec "$COG_BIN" \
  --platform=drm \
  "$KIOSK_URL"
