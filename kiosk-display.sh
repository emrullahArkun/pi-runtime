#!/bin/bash
# Runs inside the cage session next to the browser (started by kiosk.sh).
#
# 4K TVs often prefer 4096x2160, wider than 16:9 (the kiosk then gets side borders), and
# make the Pi draw four times the pixels, sometimes at 30 Hz. Every output that offers
# 1920x1080 is kept in that mode. Checking once at start is not enough: cage falls back to
# the TV's preferred mode whenever the TV reconnects (it starts after the Pi following a
# power cut, or wakes from CEC standby in the morning).
#
# Usage: kiosk-display.sh <pid>   ends once that process (the browser) is gone

set -u

OWNER="${1:?pid of the browser}"
INTERVAL="${DISPLAY_CHECK_S:-10}"
LOG="${DISPLAY_LOG:-/tmp/kiosk-display.log}"
WANT=1920x1080

# Outputs that offer WANT but run in another mode. The first WANT mode wlr-randr finds
# has the highest refresh rate (the kernel sorts it first).
outputs_to_switch() {
  wlr-randr 2>/dev/null | awk -v want="$WANT" '
    function flush() { if (out != "" && has && cur != want) print out }
    /^[^ ]/ { flush(); out = $1; has = 0; cur = "" }
    $1 == want { has = 1 }
    /\(current\)/ { cur = $1 }
    END { flush() }'
}

command -v wlr-randr >/dev/null || exit 0

while kill -0 "$OWNER" 2>/dev/null; do
  for out in $(outputs_to_switch); do
    if wlr-randr --output "$out" --mode "$WANT" 2>>"$LOG"; then
      echo "$(date -Is) $out -> $WANT" >> "$LOG"
    fi
  done
  sleep "$INTERVAL"
done
