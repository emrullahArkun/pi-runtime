#!/bin/bash
# Installed by setup.sh — gleicht ~/.ssh/authorized_keys mit dem aktuellen
# Server-Stand (/pi/server-info) ab. Spiegelt die authorized_keys-Logik aus
# setup.sh Block D und schreibt nur bei tatsaechlicher Abweichung.
set -euo pipefail

INFO="$(curl -fsS --max-time 10 "${FLEET_SERVER_URL}/pi/server-info" 2>/dev/null || true)"
if [ -z "$INFO" ]; then
  echo "fleet-keysync: server-info nicht erreichbar — alter Stand bleibt." >&2
  exit 0
fi

FLEET_SSH_PUBKEY="$(echo "$INFO" | jq -r '.ssh_pubkey // empty')"
ADMIN_SHELL_PUBKEY="$(echo "$INFO" | jq -r '.admin_shell_pubkey // empty')"
if [ -z "$FLEET_SSH_PUBKEY" ]; then
  echo "fleet-keysync: kein ssh_pubkey in server-info — Abbruch." >&2
  exit 0
fi

AUTH_KEYS="$HOME/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"

# Fremde Keys (alles ausser unseren zwei Marker-Bloecken) unveraendert behalten.
OTHER="$(sed '/# fleet-api$/{N;d;}; /# admin-shell$/{N;d;}' "$AUTH_KEYS")"

# Soll-Zustand bauen.
{
  if [ -n "$OTHER" ]; then printf '%s\n' "$OTHER"; fi
  echo "# fleet-api"
  echo "command=\"/usr/local/sbin/fleet-control\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $FLEET_SSH_PUBKEY"
  if [ -n "$ADMIN_SHELL_PUBKEY" ]; then
    echo "# admin-shell"
    echo "$ADMIN_SHELL_PUBKEY"
  fi
} > "$AUTH_KEYS.tmp"
chmod 600 "$AUTH_KEYS.tmp"

# Nur ersetzen wenn sich etwas geaendert hat (kein sinnloser Write pro Tick).
if ! cmp -s "$AUTH_KEYS.tmp" "$AUTH_KEYS"; then
  mv "$AUTH_KEYS.tmp" "$AUTH_KEYS"
  echo "fleet-keysync: authorized_keys aktualisiert."
else
  rm -f "$AUTH_KEYS.tmp"
fi
