#!/bin/bash
# ============================================
# OverlayFS-Schalter fuer den Kiosk-Pi (read-only Root).
#
# Schuetzt die SD-Karte vor Korruption bei Stromausfall + Verschleiss: der Root
# wird read-only gemountet, alle Schreibzugriffe gehen in eine RAM-Schicht (tmpfs)
# und sind nach einem Reboot weg. Die SD-Karte wird im Betrieb nie beschrieben.
#
# WICHTIG:
#   - Erst AKTIVIEREN, nachdem setup.sh einmal komplett durchlief — alle
#     persistenten Daten (WG-Key, wg0.conf, /etc/fleet, authorized_keys,
#     fleet-control, Cursor-Theme) muessen auf der read-only Basis liegen.
#   - Mit Overlay AN persistieren KEINE Aenderungen mehr (auch keine apt-Updates).
#     Zum Aendern/Patchen: 'disable' -> reboot -> aendern/updaten -> 'enable' -> reboot.
#   - Laufzeit-Writes (Logs, /etc/fleet/kiosk-id, authorized_keys-Drift) gehen ins
#     RAM und werden nach dem Boot vom Heartbeat / fleet-keysync neu geholt
#     (selbstheilend) — das ist gewollt.
#
# Usage: bash overlayfs.sh status|enable|disable
# ============================================

set -euo pipefail

# Aktiv = Root ist gerade als overlay gemountet.
overlay_active() { grep -qE '^overlay / overlay' /proc/mounts; }

CMD="${1:-status}"

case "$CMD" in
  status)
    if overlay_active; then
      echo "OverlayFS: AKTIV — Root read-only, Writes im RAM (tmpfs)."
    else
      echo "OverlayFS: inaktiv — Root ist beschreibbar."
    fi
    echo "RAM:"; free -h | sed -n '1,2p'
    ;;

  enable)
    if overlay_active; then
      echo "OverlayFS ist bereits aktiv — nichts zu tun."
      exit 0
    fi
    # Safety: kein nicht-eingerichtetes System einfrieren.
    if ! sudo test -f /etc/wireguard/wg0.conf; then
      echo "ABBRUCH: /etc/wireguard/wg0.conf fehlt." >&2
      echo "         Erst 'bash setup.sh' komplett laufen lassen, sonst frierst du" >&2
      echo "         ein nicht eingerichtetes System ein." >&2
      exit 1
    fi
    echo "Aktiviere OverlayFS via raspi-config..."
    if sudo raspi-config nonint do_overlayfs 0; then
      echo "OK — wird beim naechsten Reboot read-only."
      echo "  -> sudo reboot"
      echo "Hinweis: Ab dann persistieren keine Aenderungen/Updates mehr."
      echo "         Patchen spaeter: bash overlayfs.sh disable -> reboot -> apt upgrade -> enable -> reboot."
    else
      echo "FEHLER: 'raspi-config nonint do_overlayfs' nicht verfuegbar." >&2
      echo "Manuell: sudo raspi-config -> Performance Options -> Overlay File System -> Enable" >&2
      exit 1
    fi
    ;;

  disable)
    echo "Deaktiviere OverlayFS via raspi-config..."
    if sudo raspi-config nonint do_overlayfs 1; then
      echo "OK — Root ist nach dem naechsten Reboot wieder beschreibbar."
      echo "  -> sudo reboot"
    else
      echo "FEHLER: 'raspi-config nonint do_overlayfs' nicht verfuegbar." >&2
      echo "Manuell: sudo raspi-config -> Performance Options -> Overlay File System -> Disable" >&2
      exit 1
    fi
    ;;

  *)
    echo "Usage: bash overlayfs.sh status|enable|disable" >&2
    exit 2
    ;;
esac
