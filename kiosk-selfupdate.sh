#!/bin/bash
# Nightly pull of pi-runtime into /opt/kiosk (cron, as root), only fast-forward. What
# takes effect when:
#   - fleet-heartbeat.sh: right away (it only reads and reports)
#   - kiosk.sh / kiosk-cog.sh: at the next reboot (daily 03:00)
#   - fleet-control, sudoers and the rest: only with a manual `bash setup.sh`
# A failed pull leaves the Pi on its current state and still exits 0.

set -uo pipefail

REPO_DIR="${REPO_DIR:-/opt/kiosk}"
LOG_FILE="${LOG_FILE:-/var/log/kiosk-update.log}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }

if [ ! -d "$REPO_DIR/.git" ]; then
  log "SKIP: $REPO_DIR ist kein Git-Checkout."
  exit 0
fi

# git als root operiert auf einem Verzeichnis das u.U. einem anderen User gehoert
# → "dubious ownership" Fehler. safe.directory einmalig setzen.
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

OLD_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo none)"

if ! git -C "$REPO_DIR" pull --ff-only >> "$LOG_FILE" 2>&1; then
  log "git pull fehlgeschlagen — Pi laeuft mit Stand $OLD_HEAD weiter."
  exit 0
fi

NEW_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo none)"

if [ "$OLD_HEAD" = "$NEW_HEAD" ]; then
  log "no-op (HEAD: $NEW_HEAD)"
else
  log "updated $OLD_HEAD -> $NEW_HEAD"

  # kiosk.sh / kiosk-cog.sh ins User-Home synchronisieren — dort liegen die
  # Kopien die per .bash_profile-Hook beim Autologin gestartet werden.
  # Owner aus /home/$USER/.bash_profile ableiten (hartes Hardcoding waere
  # broken wenn jemand den Default-User aendert).
  for HOME_DIR in /home/*; do
    [ -d "$HOME_DIR" ] || continue
    [ -f "$HOME_DIR/.bash_profile" ] || continue
    grep -q "kiosk-autostart" "$HOME_DIR/.bash_profile" || continue
    OWNER="$(stat -c '%U' "$HOME_DIR")"
    GROUP="$(stat -c '%G' "$HOME_DIR")"
    for SCRIPT in kiosk.sh kiosk-cog.sh; do
      # Dist-Repo ist flach (Root = raspberry-Inhalt), daher direkt $REPO_DIR/$SCRIPT.
      SRC="$REPO_DIR/$SCRIPT"
      [ -f "$SRC" ] || continue
      if ! cmp -s "$SRC" "$HOME_DIR/$SCRIPT"; then
        install -m 0755 -o "$OWNER" -g "$GROUP" "$SRC" "$HOME_DIR/$SCRIPT"
        log "  $SCRIPT -> $HOME_DIR/ (owner $OWNER)"
      fi
    done
  done
fi

HEARTBEAT_SRC="$REPO_DIR/fleet-heartbeat.sh"
HEARTBEAT_DST=/usr/local/sbin/fleet-heartbeat.sh
if [ -f "$HEARTBEAT_SRC" ] && ! cmp -s "$HEARTBEAT_SRC" "$HEARTBEAT_DST"; then
  install -m 0755 -o root -g root "$HEARTBEAT_SRC" "$HEARTBEAT_DST" && log "  fleet-heartbeat.sh -> $HEARTBEAT_DST"
fi

# Log rotieren — vermeiden dass die Datei ewig waechst (1 MB cap).
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  tail -c 524288 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi
