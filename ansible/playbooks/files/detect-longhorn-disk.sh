#!/bin/sh
# Print the block devices that are safe to hand to Longhorn, one per line.
#
# "Safe" is deliberately strict: a device qualifies only if it carries no
# signature of any kind - no partition table, no filesystem, no LVM or RAID
# metadata - and nothing else is using it. Getting this wrong reformats
# somebody's root disk, so the rule is to skip anything we are not certain
# about rather than to guess.
#
# This lives in its own file rather than inline in the playbook so it can be
# unit-tested against fake sysfs trees, which is the only practical way to cover
# cases like "two empty disks" or "disk claimed by LVM" - a container cannot
# present a spare /dev/sd*, and a VM can only show one arrangement at a time.
#
# Usage: detect-longhorn-disk.sh [MIN_GB]
#
# Test hooks (never set in production):
#   SYSFS_ROOT  directory to scan instead of /sys/block
#   BLKID       blkid command to use instead of the real one
#   DEV_DIR     directory the device nodes live in, instead of /dev

MIN_GB="${1:-${MIN_GB:-16}}"
SYSFS_ROOT="${SYSFS_ROOT:-/sys/block}"
BLKID="${BLKID:-blkid}"
DEV_DIR="${DEV_DIR:-/dev}"

for dev_path in "${SYSFS_ROOT}"/*; do
  [ -d "${dev_path}" ] || continue
  name="$(basename "${dev_path}")"

  # Virtual, removable-media and device-mapper nodes are never data disks.
  case "${name}" in
    loop*|sr*|fd*|dm-*|md*|zram*|ram*|nbd*) continue ;;
  esac

  # Removable: a USB stick someone left plugged in is not storage for a cluster.
  if [ "$(cat "${dev_path}/removable" 2>/dev/null)" = "1" ]; then
    continue
  fi

  # A partition of its own means the disk is already in use for something.
  # Partitions appear in sysfs as a child directory named after the parent,
  # e.g. /sys/block/sda/sda1.
  has_partition=0
  for part in "${dev_path}/${name}"*; do
    if [ -e "${part}" ]; then
      has_partition=1
      break
    fi
  done
  [ "${has_partition}" = "1" ] && continue

  # Claimed by LVM, MD or dm-crypt.
  if [ -n "$(ls -A "${dev_path}/holders" 2>/dev/null)" ]; then
    continue
  fi

  # The decisive check: any filesystem, partition table or RAID/LVM signature at
  # all. blkid -p exits 0 when it finds one.
  if "${BLKID}" -p "${DEV_DIR}/${name}" >/dev/null 2>&1; then
    continue
  fi

  # Too small to be the data disk we are looking for.
  size_sectors="$(cat "${dev_path}/size" 2>/dev/null || echo 0)"
  size_gb=$(( size_sectors * 512 / 1073741824 ))
  [ "${size_gb}" -lt "${MIN_GB}" ] && continue

  echo "${DEV_DIR}/${name}"
done

exit 0
