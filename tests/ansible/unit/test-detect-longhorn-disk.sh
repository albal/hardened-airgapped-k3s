#!/usr/bin/env bash
#
# Unit tests for ansible/playbooks/files/detect-longhorn-disk.sh.
#
# That script decides which block device gets reformatted for Longhorn, so the
# cost of it being wrong is somebody's root filesystem. These tests build fake
# /sys/block trees and stub blkid, which is the only practical way to cover the
# arrangements that matter - a container cannot present a spare /dev/sd*, and a
# real VM can only be in one state at a time.
#
# No root, no Docker, no network. Runs in well under a second.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../.." && pwd)"
SCRIPT="${REPO_ROOT}/ansible/playbooks/files/detect-longhorn-disk.sh"

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  RED=""; GREEN=""; DIM=""; OFF=""
fi

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# make_disk <tree> <name> <size_gb> [partitions|holders|removable]
make_disk() {
  local tree="$1" name="$2" gb="$3" flag="${4:-}"
  local d="${tree}/${name}"
  mkdir -p "${d}/holders"
  # sysfs reports size in 512-byte sectors.
  echo $(( gb * 1073741824 / 512 )) > "${d}/size"
  echo 0 > "${d}/removable"
  case "${flag}" in
    partitions) mkdir -p "${d}/${name}1" ;;
    holders)    mkdir -p "${d}/holders/dm-0" ;;
    removable)  echo 1 > "${d}/removable" ;;
  esac
}

# run_detect <tree> <blkid-should-find-signature-on...> -- returns stdout
run_detect() {
  local tree="$1"; shift
  local stub="${WORK}/blkid-stub"
  {
    echo '#!/bin/sh'
    echo '# stub: exit 0 (signature found) only for the named devices'
    echo 'dev="$2"'
    echo 'case "${dev##*/}" in'
    for dev in "$@"; do echo "  ${dev}) exit 0 ;;"; done
    echo '  *) exit 2 ;;'
    echo 'esac'
  } > "${stub}"
  chmod +x "${stub}"
  SYSFS_ROOT="${tree}" BLKID="${stub}" DEV_DIR=/dev sh "${SCRIPT}" 16
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    printf '%s  ok%s %s\n' "${GREEN}" "${OFF}" "${name}"
    PASS=$((PASS + 1))
  else
    printf '%sfail%s %s\n' "${RED}" "${OFF}" "${name}"
    printf '       expected: [%s]\n       actual:   [%s]\n' "${expected}" "${actual}"
    FAIL=$((FAIL + 1))
  fi
}

printf '%sdetect-longhorn-disk.sh%s\n' "${DIM}" "${OFF}"

# --- the normal case: one empty disk beside the boot disk -------------------
t="${WORK}/t1"; mkdir -p "$t"
make_disk "$t" sda 40 partitions      # boot disk: has a partition
make_disk "$t" sdb 128                # the spare
check "picks the one empty disk" "/dev/sdb" "$(run_detect "$t" sda)"

# --- the arrangement that actually bit us on Proxmox ------------------------
# A hot-plugged disk can enumerate ahead of the boot disk, so the empty one is
# sda and root is on sdb. Anything keying off device letters gets this wrong.
t="${WORK}/t2"; mkdir -p "$t"
make_disk "$t" sda 128                # the spare, enumerated first
make_disk "$t" sdb 40 partitions      # boot disk
check "ignores device letters, not just sdb" "/dev/sda" "$(run_detect "$t" sdb)"

# --- refuse to guess between two candidates --------------------------------
t="${WORK}/t3"; mkdir -p "$t"
make_disk "$t" sda 40 partitions
make_disk "$t" sdb 128
make_disk "$t" sdc 128
check "reports both when two disks are empty" "/dev/sdb
/dev/sdc" "$(run_detect "$t" sda)"

# --- every reason to skip a disk -------------------------------------------
t="${WORK}/t4"; mkdir -p "$t"
make_disk "$t" sda 128 partitions
check "skips a disk with a partition" "" "$(run_detect "$t")"

t="${WORK}/t5"; mkdir -p "$t"
make_disk "$t" sda 128 holders
check "skips a disk claimed by LVM or RAID" "" "$(run_detect "$t")"

t="${WORK}/t6"; mkdir -p "$t"
make_disk "$t" sda 128 removable
check "skips removable media" "" "$(run_detect "$t")"

t="${WORK}/t7"; mkdir -p "$t"
make_disk "$t" sda 128
check "skips a disk carrying a filesystem signature" "" "$(run_detect "$t" sda)"

t="${WORK}/t8"; mkdir -p "$t"
make_disk "$t" sda 8
check "skips a disk below the size floor" "" "$(run_detect "$t")"

# --- virtual devices are never candidates ----------------------------------
t="${WORK}/t9"; mkdir -p "$t"
for virt in loop0 sr0 dm-0 md0 zram0 ram0 nbd0; do make_disk "$t" "${virt}" 128; done
make_disk "$t" sdb 128
check "skips loop/sr/dm/md/zram/ram/nbd devices" "/dev/sdb" "$(run_detect "$t")"

# --- nothing at all --------------------------------------------------------
t="${WORK}/t10"; mkdir -p "$t"
make_disk "$t" sda 40 partitions
check "reports nothing when there is no spare disk" "" "$(run_detect "$t" sda)"

# --- other disk naming schemes ---------------------------------------------
t="${WORK}/t11"; mkdir -p "$t"
make_disk "$t" vda 40 partitions
make_disk "$t" vdb 128
check "works for virtio (vd*) names too" "/dev/vdb" "$(run_detect "$t" vda)"

t="${WORK}/t12"; mkdir -p "$t"
make_disk "$t" nvme0n1 40 partitions
make_disk "$t" nvme1n1 512
check "works for NVMe names too" "/dev/nvme1n1" "$(run_detect "$t" nvme0n1)"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 )) || exit 1
