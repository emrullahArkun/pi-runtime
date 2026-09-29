#!/bin/bash
# Runs in the builder container of build.sh: grows the official image, runs
# `setup.sh --install` from pi-runtime in an ARM chroot, removes everything that
# identifies a machine, shrinks the root partition and packs the result.

set -euo pipefail

RUNTIME_REPO="https://github.com/emrullahArkun/pi-runtime.git"
WORK=/cache/build
IMG="$WORK/image.img"
MNT="$WORK/root"
ROOT_LOOP=""
BOOT_LOOP=""

cleanup() {
  set +e
  for dir in dev/pts dev sys proc boot/firmware ""; do
    mountpoint -q "$MNT/$dir" && umount -l "$MNT/$dir"
  done
  [ -n "$BOOT_LOOP" ] && losetup -d "$BOOT_LOOP" 2>/dev/null
  [ -n "$ROOT_LOOP" ] && losetup -d "$ROOT_LOOP" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

apt-get -qq update
apt-get -qq install -y --no-install-recommends xz-utils e2fsprogs fdisk git ca-certificates > /dev/null

# "start size" of partition $1 in sectors.
partition() {
  sfdisk -d "$IMG" | awk -v p="$IMG$1" '$1 == p { gsub(/[^0-9]/, "", $4); gsub(/[^0-9]/, "", $6); print $4, $6 }'
}
attach() {
  local start size
  read -r start size <<< "$(partition "$1")"
  losetup -f --show -o $((start * 512)) --sizelimit $((size * 512)) "$IMG"
}

rm -rf "$WORK"
mkdir -p "$MNT"
echo "  Entpacken..."
xz -dc -T0 "/cache/$BASE" > "$IMG"

# Room for Chromium and the rest; shrunk again at the end.
truncate -s +3G "$IMG"
echo ",+" | sfdisk -q --no-reread -N 2 "$IMG"
ROOT_LOOP="$(attach 2)"
BOOT_LOOP="$(attach 1)"
e2fsck -fy "$ROOT_LOOP" > /dev/null || [ $? -le 1 ]
resize2fs "$ROOT_LOOP" > /dev/null

mount "$ROOT_LOOP" "$MNT"
mount "$BOOT_LOOP" "$MNT/boot/firmware"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"

RESOLV_BACKUP=""
if [ -e "$MNT/etc/resolv.conf" ] || [ -L "$MNT/etc/resolv.conf" ]; then
  RESOLV_BACKUP="$WORK/resolv.conf.orig"
  mv "$MNT/etc/resolv.conf" "$RESOLV_BACKUP"
fi
cp /etc/resolv.conf "$MNT/etc/resolv.conf"
# No service may start inside the chroot.
printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"
chmod 0755 "$MNT/usr/sbin/policy-rc.d"

echo "  pi-runtime holen..."
git clone -q --depth 1 "$RUNTIME_REPO" "$MNT/opt/kiosk"
RUNTIME_COMMIT="$(git -C "$MNT/opt/kiosk" rev-parse HEAD)"
echo "  Stand $(git -C "$MNT/opt/kiosk" log -1 --format=%s)"

echo "  setup.sh --install (ARM-Emulation, dauert)..."
chroot "$MNT" /usr/bin/env -i HOME=/root LANG=C.UTF-8 \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  PI_MODEL="Raspberry Pi 4 Model B" \
  bash /opt/kiosk/setup.sh --install < /dev/null > "$WORK/setup.log" 2>&1 \
  || { tail -40 "$WORK/setup.log"; cp "$WORK/setup.log" /cache/build-failed.log; exit 1; }
cp "$WORK/setup.log" "/cache/${OUT%.img.xz}.setup.log"
install -d "$MNT/var/lib/kiosk-update"
echo "$RUNTIME_COMMIT" > "$MNT/var/lib/kiosk-update/applied"

echo "  Identitaet entfernen, aufraeumen..."
chroot "$MNT" apt-get clean
rm -f "$MNT/usr/sbin/policy-rc.d" "$MNT/etc/resolv.conf"
[ -n "$RESOLV_BACKUP" ] && mv "$RESOLV_BACKUP" "$MNT/etc/resolv.conf"
rm -rf "$MNT"/var/lib/apt/lists/* "$MNT"/tmp/* "$MNT"/var/tmp/* "$MNT"/root/.bash_history
rm -f "$MNT"/etc/ssh/ssh_host_*
# Empty, not "uninitialized": that would make the first start a systemd first boot,
# whose preset-all re-enables units setup.sh disabled (the user rename wizard).
: > "$MNT/etc/machine-id"
# Without a real-time clock the Pi starts with this time until it reaches NTP; much older
# and HTTPS certificates would not be valid yet.
install -d "$MNT/var/lib/systemd/timesync"
touch "$MNT/var/lib/systemd/timesync/clock"
[ -L "$MNT/var/lib/dbus/machine-id" ] || rm -f "$MNT/var/lib/dbus/machine-id"
find "$MNT/var/log" -type f -exec truncate -s 0 {} +
fstrim "$MNT" 2>/dev/null || true

for dir in dev/pts dev sys proc boot/firmware ""; do umount "$MNT/$dir"; done
losetup -d "$BOOT_LOOP"; BOOT_LOOP=""

echo "  Verkleinern..."
e2fsck -fy "$ROOT_LOOP" > /dev/null || [ $? -le 1 ]
resize2fs -M "$ROOT_LOOP" > /dev/null 2>&1
BLOCKS="$(dumpe2fs -h "$ROOT_LOOP" 2>/dev/null | awk -F: '/^Block count/ { gsub(/ /, "", $2); print $2 }')"
BLOCK_SIZE="$(dumpe2fs -h "$ROOT_LOOP" 2>/dev/null | awk -F: '/^Block size/ { gsub(/ /, "", $2); print $2 }')"
losetup -d "$ROOT_LOOP"; ROOT_LOOP=""
read -r ROOT_START _ <<< "$(partition 2)"
# The first start grows partition and file system to the whole card.
ROOT_SECTORS=$(( (BLOCKS * BLOCK_SIZE + 64 * 1024 * 1024) / 512 ))
echo "$ROOT_START,$ROOT_SECTORS" | sfdisk -q --no-reread -N 2 "$IMG"
truncate -s $(( (ROOT_START + ROOT_SECTORS) * 512 )) "$IMG"

echo "  Packen ($(( $(stat -c %s "$IMG") / 1024 / 1024 )) MB)..."
xz -T0 -6 -c "$IMG" > "/cache/$OUT.tmp"
mv "/cache/$OUT.tmp" "/cache/$OUT"
(cd /cache && sha256sum "$OUT" > "$OUT.sha256")
chown "$OWNER" "/cache/$OUT" "/cache/$OUT.sha256" "/cache/${OUT%.img.xz}.setup.log"
echo "  pi-runtime $RUNTIME_COMMIT"
