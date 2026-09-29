#!/bin/bash
# Builds the gold image: Raspberry Pi OS Lite (64-bit) with `setup.sh --install` from
# pi-runtime already run, but without any identity (user password, SSH keys, hostname,
# enrollment come from provision-pi.sh). Result in the cache, where provision-pi.sh
# picks it up:  ~/.cache/big-kiosk/big-kiosk-<date>.img.xz (+ .sha256)
#
# Runs on the laptop in Docker (privileged, for the loop devices), 20-40 min.
# Needs ARM emulation once:  docker run --privileged --rm tonistiigi/binfmt --install arm64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/big-kiosk"
BUILDER_IMAGE="debian:trixie-slim"
# shellcheck source=os-image.sh
. "$SCRIPT_DIR/os-image.sh"

if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  echo "FEHLER: ARM-Emulation fehlt. Einmal ausfuehren:"
  echo "  docker run --privileged --rm tonistiigi/binfmt --install arm64"
  exit 1
fi

echo "[1/3] Raspberry Pi OS pruefen..."
BASE="$(fetch_official_image "$CACHE_DIR")"
OUT="big-kiosk-$(date +%Y-%m-%d).img.xz"
echo "  Basis: $(basename "$BASE")"

echo "[2/3] Abbild bauen (Docker, dauert)..."
docker run --rm --privileged --hostname raspberrypi -v /dev:/dev \
  -v "$CACHE_DIR:/cache" -v "$SCRIPT_DIR:/image:ro" \
  -e BASE="$(basename "$BASE")" -e OUT="$OUT" -e OWNER="$(id -u):$(id -g)" \
  "$BUILDER_IMAGE" bash /image/build-inside.sh

echo "[3/3] Fertig: $CACHE_DIR/$OUT"
echo "  provision-pi.sh nimmt ab jetzt dieses Abbild."
