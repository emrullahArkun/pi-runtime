#!/bin/bash
# Nightly update from pi-runtime into /opt/kiosk (cron, as root, before the 03:00 reboot).
# The channel in /etc/fleet/channel picks the commit: "early" takes the newest, "stable"
# (default) the newest one that is at least STABLE_AGE_H hours old, so a bad change shows
# on an early Pi first. The commit is applied with `setup.sh --update`; a failed run is
# retried the next night. A failed fetch leaves the Pi on its current state.

set -uo pipefail

REPO_DIR="${REPO_DIR:-/opt/kiosk}"
LOG_FILE="${LOG_FILE:-/var/log/kiosk-update.log}"
CHANNEL_FILE="${CHANNEL_FILE:-/etc/fleet/channel}"
APPLIED_FILE="${APPLIED_FILE:-/var/lib/kiosk-update/applied}"
LOCK_FILE="${LOCK_FILE:-/run/kiosk-selfupdate.lock}"
STABLE_AGE_H="${STABLE_AGE_H:-24}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }
g() { git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" "$@"; }

exec 9> "$LOCK_FILE"
flock -n 9 || exit 0

if [ ! -d "$REPO_DIR/.git" ]; then
  log "SKIP: $REPO_DIR ist kein Git-Checkout."
  exit 0
fi

# With the read-only root (overlayfs.sh) every change is gone after the 03:00 reboot.
if grep -qE '^overlay / overlay' "${MOUNTS_FILE:-/proc/mounts}" 2>/dev/null; then
  log "SKIP: Schreibschutz (OverlayFS) aktiv, ein Update ginge beim Neustart verloren."
  exit 0
fi

CHANNEL="$(tr -dc 'a-z' 2>/dev/null < "$CHANNEL_FILE" || true)"
[ "$CHANNEL" = "early" ] || CHANNEL="stable"

OLD_HEAD="$(g rev-parse HEAD 2>/dev/null || echo none)"
if ! g fetch -q --depth 50 origin main >> "$LOG_FILE" 2>&1; then
  log "git fetch fehlgeschlagen — Pi laeuft mit Stand $OLD_HEAD weiter."
  exit 0
fi
if [ "$CHANNEL" = "early" ]; then
  TARGET="$(g rev-parse FETCH_HEAD)"
else
  TARGET="$(g rev-list -1 --before="$STABLE_AGE_H hours ago" FETCH_HEAD)"
fi

# Never step back: a Pi that already has TARGET (e.g. freshly cloned, or just moved from
# early to stable) keeps what it has.
if [ -n "$TARGET" ] && ! g merge-base --is-ancestor "$TARGET" HEAD 2>/dev/null; then
  if ! g reset -q --hard "$TARGET" >> "$LOG_FILE" 2>&1; then
    log "git fetch fehlgeschlagen — Stand $TARGET liess sich nicht auschecken."
    exit 0
  fi
fi
NEW_HEAD="$(g rev-parse HEAD)"

if [ "$NEW_HEAD" = "$(cat "$APPLIED_FILE" 2>/dev/null || true)" ]; then
  log "no-op (HEAD: $NEW_HEAD, Kanal $CHANNEL)"
elif bash "$REPO_DIR/setup.sh" --update >> "$LOG_FILE" 2>&1; then
  mkdir -p "$(dirname "$APPLIED_FILE")"
  echo "$NEW_HEAD" > "$APPLIED_FILE"
  log "updated $OLD_HEAD -> $NEW_HEAD (Kanal $CHANNEL)"
else
  log "update fehlgeschlagen: setup.sh --update bei $NEW_HEAD (Kanal $CHANNEL), naechste Nacht neu."
fi

# Keep the log at most 1 MB.
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  tail -c 524288 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi
