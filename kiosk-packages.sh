#!/bin/bash
# Nightly package updates (cron 02:15, as root, between the self-update and the 03:00
# reboot, which waits for LOCK_FILE). Debian security updates every night via
# unattended-upgrade; everything else (Raspberry Pi packages, Chromium, kernel, Debian
# point releases) along the channel: early every night, stable in the first night after
# a new signed stable release (the tag kiosk-selfupdate.sh found valid).

set -uo pipefail

LOG_FILE="${LOG_FILE:-/var/log/kiosk-packages.log}"
LOCK_FILE="${LOCK_FILE:-/run/fleet-packages.lock}"
CHANNEL_FILE="${CHANNEL_FILE:-/etc/fleet/channel}"
RELEASE_FILE="${RELEASE_FILE:-/var/lib/kiosk-update/release}"
# "<ok|failed> <epoch>" of the last run, and "<epoch> <release>" of the last full upgrade.
RESULT_FILE="${RESULT_FILE:-/var/lib/kiosk-update/packages}"
FULL_FILE="${FULL_FILE:-/var/lib/kiosk-update/packages-full}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }
run() { "$@" >> "$LOG_FILE" 2>&1; }

APT=(env DEBIAN_FRONTEND=noninteractive apt-get -q -y -o DPkg::Lock::Timeout=600
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

exec 9> "$LOCK_FILE"
flock -n 9 || exit 0

# With the read-only root (overlayfs.sh) every change is gone after the 03:00 reboot.
if grep -qE '^overlay / overlay' "${MOUNTS_FILE:-/proc/mounts}" 2>/dev/null; then
  log "SKIP: Schreibschutz (OverlayFS) aktiv."
  exit 0
fi

CHANNEL="$(tr -dc 'a-z' 2>/dev/null < "$CHANNEL_FILE" || true)"
[ "$CHANNEL" = "early" ] || CHANNEL="stable"

# The release a full upgrade belongs to: early follows every night, stable its newest
# valid release tag.
if [ "$CHANNEL" = early ]; then
  RELEASE="early-$(date -u +%Y%m%d)"
else
  read -r _ RELEASE < "$RELEASE_FILE" 2>/dev/null || RELEASE=""
fi
LAST_FULL="$(cut -d' ' -f2 "$FULL_FILE" 2>/dev/null || true)"

result=ok
# An install cut short (power loss, an old reboot) is finished first.
run dpkg --configure -a || result=failed
if ! run "${APT[@]}" update; then
  result=failed
else
  run unattended-upgrade || result=failed
  if [ -n "${RELEASE:-}" ] && [ "$RELEASE" != "$LAST_FULL" ]; then
    if run "${APT[@]}" --with-new-pkgs upgrade; then
      mkdir -p "$(dirname "$FULL_FILE")"
      echo "$(date +%s) $RELEASE" > "$FULL_FILE"
      log "alles aktualisiert ($RELEASE, Kanal $CHANNEL)"
    else
      result=failed
    fi
  fi
fi

mkdir -p "$(dirname "$RESULT_FILE")"
echo "$result $(date +%s)" > "$RESULT_FILE"
log "Pakete: $result (Kanal $CHANNEL)"

if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  tail -c 524288 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi
