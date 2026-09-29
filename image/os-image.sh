#!/bin/bash
# Sourced by provision-pi.sh and image/build.sh: the newest Raspberry Pi OS Lite (64-bit),
# downloaded once into the cache and checked against its published checksum.

OS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"

# Prints the path of the verified image in $1 (the cache directory).
fetch_official_image() {
  local cache="$1" url image
  mkdir -p "$cache"
  url="$(curl -fsIL -o /dev/null -w '%{url_effective}' "$OS_URL")" || return 1
  image="$cache/$(basename "$url")"
  curl -fsL "$url.sha256" -o "$image.sha256" || return 1
  if ! (cd "$cache" && sha256sum -c --quiet "$(basename "$image").sha256" 2>/dev/null); then
    echo "  Lade $(basename "$url") ..." >&2
    curl -fL --progress-bar "$url" -o "$image" >&2 || return 1
    if ! (cd "$cache" && sha256sum -c --quiet "$(basename "$image").sha256"); then
      echo "FEHLER: Pruefsumme stimmt nicht, Download kaputt." >&2
      rm -f "$image"
      return 1
    fi
  fi
  printf '%s\n' "$image"
}
