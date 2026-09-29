#!/bin/bash
# First start of a gold image: waits for internet (the Wi-Fi setup may still be running),
# enrolls the Pi with the token on the boot partition and restarts the kiosk, which then
# knows its kiosk id and shows the pairing QR code. systemd retries a failed run.

set -uo pipefail

ENROLLMENT_FILE="${ENROLLMENT_FILE:-/boot/firmware/fleet-enrollment.txt}"

if [ ! -f "$ENROLLMENT_FILE" ]; then
  echo "Keine Anmeldedatei ($ENROLLMENT_FILE), nichts zu tun."
  exit 0
fi
API_URL="$(grep -E '^FLEET_API_URL=' "$ENROLLMENT_FILE" | tail -1 | cut -d= -f2-)"
if [ -z "$API_URL" ]; then
  echo "FEHLER: FLEET_API_URL fehlt in $ENROLLMENT_FILE."
  exit 1
fi

until curl -fsS --max-time 10 -o /dev/null "$API_URL/health"; do
  sleep 10
done
echo "Server erreichbar, melde an..."

bash /opt/kiosk/setup.sh --enroll || exit 1

pkill -SIGHUP -x cage || pkill -SIGHUP -x cog || true
echo "Angemeldet."
