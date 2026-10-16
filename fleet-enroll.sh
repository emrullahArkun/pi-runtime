#!/bin/bash
# First start of a gold image: waits for internet (the Wi-Fi setup may still be running)
# and enrolls the Pi with the token on the boot partition. Its first heartbeat brings the
# kiosk id and restarts the kiosk, which then shows the pairing QR code. systemd retries
# a failed run.

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
echo "Server erreichbar."

# The stable channel picks its commit by age, so the clock must be right first (no RTC).
for _ in $(seq 1 "${CLOCK_WAIT_TRIES:-60}"); do
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && break
  sleep 5
done

# An older image first takes the current scripts of its channel (like every night).
/usr/local/sbin/kiosk-selfupdate.sh || true

echo "Melde an..."
bash /opt/kiosk/setup.sh --enroll || exit 1
echo "Angemeldet."
