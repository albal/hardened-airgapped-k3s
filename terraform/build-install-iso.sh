#!/usr/bin/env bash
#
# Turns a stock Debian or Ubuntu Server ISO into one that installs itself.
#
# Which mechanism is used depends on what the ISO is, detected from its
# contents rather than its filename:
#
#   Debian netinst      preseed, injected into the installer's initrd as
#                       /preseed.cfg, which debian-installer reads before it
#                       asks its first question
#   Ubuntu live-server  subiquity autoinstall, served from /nocloud/ on the ISO
#                       via cloud-init's NoCloud datasource
#
# Either way there is no HTTP server, nothing typed at the boot prompt, and the
# boot menu is replaced with a single entry that starts immediately.
#
# One ISO installs every node: a late script matches each machine's MAC address
# against the `nodes` map in terraform.tfvars and sets the hostname (and static
# address, if one is configured) accordingly.
#
# Usage:
#   ./build-install-iso.sh                 build and upload to Proxmox
#   ./build-install-iso.sh --no-upload     build only
#   ./build-install-iso.sh --force         replace an ISO already on the storage
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

TFVARS="terraform.tfvars"
CACHE_DIR=".iso"
PRESEED_DIR="preseed"
AUTOINSTALL_DIR="autoinstall"
ADMIN_USER="${INSTALL_ADMIN_USER:-ubuntu}"   # Ubuntu autoinstall must create one
DO_UPLOAD=1
FORCE=""
SOURCE_ISO=""

# Preseed settings. Overridable from the environment.
LOCALE="${PRESEED_LOCALE:-en_GB.UTF-8}"
LANGUAGE="${PRESEED_LANGUAGE:-en}"
COUNTRY="${PRESEED_COUNTRY:-GB}"
KEYMAP="${PRESEED_KEYMAP:-gb}"
# GMT, not Europe/London: servers should not jump an hour in March. Set
# PRESEED_TIMEZONE=Europe/London if you want local time with BST instead.
TIMEZONE="${PRESEED_TIMEZONE:-Etc/GMT}"
ROOT_PASSWORD="${PRESEED_ROOT_PASSWORD:-password}"
DOMAIN="${PRESEED_DOMAIN:-office.tsew.net}"
# Debian's mirror. Ubuntu needs a different one entirely - different host,
# different path, different suite names - so it gets its own setting rather
# than sharing these.
MIRROR_HOST="${PRESEED_MIRROR_HOST:-deb.debian.org}"
MIRROR_DIR="${PRESEED_MIRROR_DIR:-/debian}"
MIRROR_PROXY="${PRESEED_MIRROR_PROXY:-}"
UBUNTU_MIRROR_URL="${PRESEED_UBUNTU_MIRROR_URL:-http://gb.archive.ubuntu.com/ubuntu}"

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
else
  RED=""; GREEN=""; CYAN=""; DIM=""; BOLD=""; OFF=""
fi
log()  { printf '%s==>%s %s\n' "${CYAN}${BOLD}" "${OFF}" "$*"; }
info() { printf '    %s\n' "$*"; }
dim()  { printf '%s    %s%s\n' "${DIM}" "$*" "${OFF}"; }
ok()   { printf '%s  ok%s %s\n' "${GREEN}" "${OFF}" "$*"; }
die()  { printf '\n%sfail%s %s\n\n' "${RED}${BOLD}" "${OFF}" "$*" >&2; exit 1; }

while (( $# > 0 )); do
  case "$1" in
    --no-upload) DO_UPLOAD=""; shift ;;
    --force)     FORCE=1; shift ;;
    --source)    SOURCE_ISO="${2:?--source needs a path}"; shift 2 ;;
    --tfvars)    TFVARS="${2:?--tfvars needs a path}"; shift 2 ;;
    -h|--help)   sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown option: $1" ;;
  esac
done

for c in xorriso cpio gzip curl terraform; do
  command -v "$c" >/dev/null || die "missing required command: $c"
done
[[ -f "${TFVARS}" ]] || die "no ${TFVARS} - copy terraform.tfvars.example to it first"

tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "${TFVARS}" | head -n1; }

endpoint="$(tfvar pve_endpoint)"; endpoint="${endpoint%/}"
node="$(tfvar pve_node)"
token_id="$(tfvar pve_token_id)"
token_secret="$(tfvar pve_token_secret)"
iso_file_id="$(tfvar iso_file_id)"
[[ -n "${iso_file_id}" ]] || die "iso_file_id is not set in ${TFVARS}"

storage="${iso_file_id%%:*}"
base_iso="$(basename "${iso_file_id#*:}")"          # debian-13.6.0-amd64-netinst.iso

# iso_file_id normally points at the stock image, but once you have switched it
# to the built one, re-running must not produce "...-preseed-preseed.iso" and
# must not try to re-remaster an already-remastered ISO. Work back to the stem.
stem="${base_iso%.iso}"
stem="${stem%-preseed}"
stem="${stem%-autoinstall}"
base_iso="${stem}.iso"
out_iso=""                                          # set once the flavour is known

# ---------------------------------------------------------------------------
# 1. Node table, straight out of terraform.tfvars so there is one source of truth
# ---------------------------------------------------------------------------
log "reading nodes from ${TFVARS}"
# -var-file matters: terraform console auto-loads terraform.tfvars, so without
# it an explicit --tfvars would be silently ignored for the node table.
nodes_json="$(echo 'jsonencode(var.nodes)' \
  | terraform console -no-color -var-file="${TFVARS}" 2>/dev/null \
  | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g')" \
  || die "could not read var.nodes - run 'terraform init' first"

command -v jq >/dev/null || die "missing required command: jq"

# MAC|HOSTNAME|ADDRESS/CIDR|GATEWAY|DNS
node_table="$(printf '%s' "${nodes_json}" | jq -r '
  to_entries[]
  | select(.value.mac_address != null)
  | [ .value.mac_address,
      .key,
      (.value.ip_address  // ""),
      (.value.gateway     // ""),
      (.value.nameservers // "") ]
  | join("|")')"

if [[ -z "${node_table}" ]]; then
  die "no node in ${TFVARS} has a mac_address.

     One ISO has to install every machine, so each node needs a fixed MAC for
     the installer to recognise it by. Add mac_address to each entry in the
     nodes map (terraform.tfvars.example shows the format)."
fi
while IFS='|' read -r mac name addr _gw _dns; do
  info "$(printf '%-14s %s  %s' "${name}" "${mac}" "${addr:-dhcp}")"
done <<< "${node_table}"

# ---------------------------------------------------------------------------
# 2. Source ISO
# ---------------------------------------------------------------------------
mkdir -p "${CACHE_DIR}"
if [[ -z "${SOURCE_ISO}" ]]; then
  SOURCE_ISO="${CACHE_DIR}/${base_iso}"
  if [[ ! -s "${SOURCE_ISO}" ]]; then
    # debian-13.6.0-amd64-netinst.iso -> 13.6.0 / amd64
    url=""
    if [[ "${base_iso}" =~ ^debian-([0-9.]+)-([a-z0-9]+)-netinst\.iso$ ]]; then
      url="https://cdimage.debian.org/debian-cd/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/iso-cd/${base_iso}"
      sums_url="${url%/*}/SHA256SUMS"
    elif [[ "${base_iso}" =~ ^ubuntu-([0-9.]+)-live-server-([a-z0-9]+)\.iso$ ]]; then
      # 26.04.1 lives under releases.ubuntu.com/26.04/
      series="$(cut -d. -f1,2 <<< "${BASH_REMATCH[1]}")"
      url="https://releases.ubuntu.com/${series}/${base_iso}"
      sums_url="https://releases.ubuntu.com/${series}/SHA256SUMS"
    else
      die "cannot work out where to download '${base_iso}' from. Pass --source /path/to/it."
    fi
    log "downloading ${base_iso}"
    dim "${url}"
    curl_progress=(--no-progress-meter)
    [[ -t 2 ]] && curl_progress=(--progress-bar)
    curl -fL "${curl_progress[@]}" --retry 3 -C - -o "${SOURCE_ISO}" "${url}" \
      || die "download failed: ${url}"

    log "verifying checksum"
    want="$(curl -fsSL "${sums_url}" \
            | awk -v f="${base_iso}" '$2 == f || $2 == "*" f || $2 == "./" f { print $1 }')"
    if [[ -n "${want}" ]]; then
      got="$(sha256sum "${SOURCE_ISO}" | cut -d' ' -f1)"
      [[ "${want}" == "${got}" ]] || die "checksum mismatch on ${SOURCE_ISO} - delete it and retry"
      ok "sha256 matches the published SHA256SUMS"
    else
      dim "no published checksum found for ${base_iso}; skipping verification"
    fi
  else
    dim "using cached ${SOURCE_ISO}"
  fi
fi
[[ -s "${SOURCE_ISO}" ]] || die "source ISO not found: ${SOURCE_ISO}"

# ---------------------------------------------------------------------------
# 3. Work out which installer this ISO carries
#
#    By contents, not by filename: a renamed ISO should still build correctly,
#    and getting this wrong produces an ISO that boots straight to a prompt.
# ---------------------------------------------------------------------------
# Match on the directory listing, not on an exit status: xorriso's -lsl exits 0
# whether or not the path exists, so testing it silently mis-detects every ISO.
iso_dirs="$(xorriso -indev "${SOURCE_ISO}" -find / -maxdepth 1 -type d 2>/dev/null | tr -d "'")"
if grep -qx '/install.amd' <<< "${iso_dirs}"; then
  FLAVOUR=debian
elif grep -qx '/casper' <<< "${iso_dirs}"; then
  FLAVOUR=ubuntu
else
  die "$(basename "${SOURCE_ISO}") is neither a Debian netinst (no /install.amd)
     nor an Ubuntu live-server image (no /casper). Top-level directories:
     $(tr '\n' ' ' <<< "${iso_dirs}")"
fi
case "${FLAVOUR}" in
  debian) out_iso="${stem}-preseed.iso" ;;
  ubuntu) out_iso="${stem}-autoinstall.iso" ;;
esac
log "detected ${FLAVOUR} installer -> ${out_iso}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/inject"

render() {
  sed -e "s|@@LOCALE@@|${LOCALE}|g" \
      -e "s|@@LANGUAGE@@|${LANGUAGE}|g" \
      -e "s|@@COUNTRY@@|${COUNTRY}|g" \
      -e "s|@@KEYMAP@@|${KEYMAP}|g" \
      -e "s|@@TIMEZONE@@|${TIMEZONE}|g" \
      -e "s|@@ROOT_PASSWORD@@|${ROOT_PASSWORD}|g" \
      -e "s|@@ADMIN_USER@@|${ADMIN_USER}|g" \
      -e "s|@@DOMAIN@@|${DOMAIN}|g" \
      -e "s|@@MIRROR_HOST@@|${MIRROR_HOST}|g" \
      -e "s|@@MIRROR_DIR@@|${MIRROR_DIR}|g" \
      -e "s|@@MIRROR_PROXY@@|${MIRROR_PROXY}|g" \
      -e "s|@@MIRROR_URL@@|${MIRROR_URL}|g" \
      -e "s|@@PASSWORD_HASH@@|${PASSWORD_HASH}|g" \
      "$1"
}

no_placeholders_left() {
  if grep -q '@@' "$1"; then
    die "unsubstituted placeholder left in $(basename "$1"): $(grep -o '@@[A-Z_]*@@' "$1" | sort -u | tr '\n' ' ')"
  fi
}

MIRROR_URL="http://${MIRROR_HOST}${MIRROR_DIR}"
PASSWORD_HASH=""

xorriso_maps=()

if [[ "${FLAVOUR}" == "debian" ]]; then
  # -------------------------------------------------------------------------
  # 4a. Debian: preseed into the initrd
  #
  #     debian-installer reads /preseed.cfg from the initrd root before it asks
  #     anything, which is why this needs no network-served preseed.
  # -------------------------------------------------------------------------
  log "rendering preseed (${LOCALE}, ${KEYMAP} keyboard, ${TIMEZONE})"
  render "${PRESEED_DIR}/preseed.cfg.tmpl" > "${work}/inject/preseed.cfg"
  render "${PRESEED_DIR}/d-i-finish.sh.tmpl" \
    | awk -v table="${node_table}" '{ gsub(/@@NODE_TABLE@@/, table); print }' \
    > "${work}/inject/d-i-finish.sh"
  chmod 0755 "${work}/inject/d-i-finish.sh"
  no_placeholders_left "${work}/inject/preseed.cfg"
  no_placeholders_left "${work}/inject/d-i-finish.sh"
  sh -n "${work}/inject/d-i-finish.sh" || die "rendered d-i-finish.sh is not valid shell"

  log "injecting into initrd"
  xorriso -osirrox on -indev "${SOURCE_ISO}" \
          -extract /install.amd/initrd.gz "${work}/initrd.gz" 2>/dev/null \
    || die "could not extract /install.amd/initrd.gz from ${SOURCE_ISO}"
  gzip -dc "${work}/initrd.gz" > "${work}/initrd"
  ( cd "${work}/inject" && printf 'preseed.cfg\nd-i-finish.sh\n' \
      | cpio --quiet -H newc -o -A -F "${work}/initrd" )
  gzip -9c "${work}/initrd" > "${work}/initrd.new.gz"
  ok "initrd $(du -h "${work}/initrd.new.gz" | cut -f1) (was $(du -h "${work}/initrd.gz" | cut -f1))"

  KERNEL_ARGS="auto=true priority=critical"
  cat > "${work}/isolinux.cfg" <<CFG
# Replaced by build-install-iso.sh - boots the automated install immediately.
path
prompt 0
timeout 1
default auto
label auto
	kernel /install.amd/vmlinuz
	append initrd=/install.amd/initrd.gz ${KERNEL_ARGS} --- quiet
CFG
  cat > "${work}/grub.cfg" <<CFG
# Replaced by build-install-iso.sh - boots the automated install immediately.
set default=0
set timeout=1

menuentry "Automated Debian install (preseed)" {
	linux	/install.amd/vmlinuz ${KERNEL_ARGS} --- quiet
	initrd	/install.amd/initrd.gz
}
CFG
  xorriso_maps=(
    -map "${work}/initrd.new.gz" /install.amd/initrd.gz
    -map "${work}/isolinux.cfg"  /isolinux/isolinux.cfg
    -map "${work}/grub.cfg"      /boot/grub/grub.cfg
    -chmod 0444 /install.amd/initrd.gz /isolinux/isolinux.cfg /boot/grub/grub.cfg --
  )

else
  # -------------------------------------------------------------------------
  # 4b. Ubuntu: subiquity autoinstall via cloud-init's NoCloud datasource
  # -------------------------------------------------------------------------
  command -v openssl >/dev/null || die "openssl is needed to hash the password for Ubuntu autoinstall"
  PASSWORD_HASH="$(openssl passwd -6 "${ROOT_PASSWORD}")"
  # Point apt at Ubuntu, not at the Debian mirror the preseed path uses: the
  # suite names do not exist there, every apt call 404s, and the install dies
  # part-way through installing packages.
  MIRROR_URL="${UBUNTU_MIRROR_URL}"

  # Static addressing is netplan here, not /etc/network/interfaces, and netplan
  # can match on MAC - so every node's config can live in one file and only the
  # block matching this machine's NIC takes effect.
  network_section=""
  if grep -q '|[^|]*|[^|]\+|' <<< "${node_table}"; then
    network_section="  network:"$'\n'"    version: 2"$'\n'"    ethernets:"$'\n'
    while IFS='|' read -r mac name addr gw ns; do
      [[ -n "${addr}" ]] || continue
      network_section+="      ${name}:"$'\n'
      network_section+="        match:"$'\n'"          macaddress: \"${mac,,}\""$'\n'
      network_section+="        dhcp4: false"$'\n'
      network_section+="        addresses: [${addr}]"$'\n'
      [[ -n "${gw}" ]] && network_section+="        routes: [{to: default, via: ${gw}}]"$'\n'
      [[ -n "${ns}" ]] && network_section+="        nameservers: {addresses: [${ns//,/, }]}"$'\n'
    done <<< "${node_table}"
    network_section+=$'\n'
    info "static addressing for $(grep -c '|[^|]*|[^|]\+|' <<< "${node_table}") node(s) via netplan"
  else
    dim "no static addresses configured - guests will use DHCP"
  fi

  log "rendering autoinstall (${LOCALE}, ${KEYMAP} keyboard, ${TIMEZONE})"
  render "${AUTOINSTALL_DIR}/user-data.tmpl" \
    | awk -v net="${network_section}" '{ gsub(/@@NETWORK_SECTION@@/, net); print }' \
    > "${work}/inject/user-data"
  render "${AUTOINSTALL_DIR}/finish.sh.tmpl" \
    | awk -v table="${node_table}" '{ gsub(/@@NODE_TABLE@@/, table); print }' \
    > "${work}/inject/finish.sh"
  : > "${work}/inject/meta-data"
  no_placeholders_left "${work}/inject/user-data"
  no_placeholders_left "${work}/inject/finish.sh"
  bash -n "${work}/inject/finish.sh" || die "rendered finish.sh is not valid shell"
  python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "${work}/inject/user-data" \
    2>/dev/null || die "rendered user-data is not valid YAML - check the network section indentation"
  ok "autoinstall config rendered"

  # ds=nocloud;s=... - the ';' has to survive GRUB's parser, hence the backslash.
  KERNEL_ARGS='autoinstall ds=nocloud\;s=/cdrom/nocloud/'
  cat > "${work}/grub.cfg" <<CFG
# Replaced by build-install-iso.sh - boots the automated install immediately.
set default=0
set timeout=1

menuentry "Automated Ubuntu install (autoinstall)" {
	set gfxpayload=keep
	linux	/casper/vmlinuz ${KERNEL_ARGS} ---
	initrd	/casper/initrd
}
CFG
  xorriso_maps=(
    -map "${work}/inject/user-data" /nocloud/user-data
    -map "${work}/inject/meta-data" /nocloud/meta-data
    -map "${work}/inject/finish.sh" /nocloud/finish.sh
    -map "${work}/grub.cfg"         /boot/grub/grub.cfg
  )
fi

# ---------------------------------------------------------------------------
# 5. Rebuild the ISO
#
#    'replay' copies the original El Torito boot records across, so the result
#    boots the same ways the original did without having to know whether this
#    image uses isolinux, grub or both.
# ---------------------------------------------------------------------------
log "rebuilding ${out_iso}"
rm -f "${CACHE_DIR}/${out_iso}"
xorriso -indev "${SOURCE_ISO}" \
        -outdev "${CACHE_DIR}/${out_iso}" \
        -boot_image any replay \
        -compliance no_emul_toc \
        -overwrite on \
        "${xorriso_maps[@]}" \
        >"${work}/xorriso.log" 2>&1 \
  || { sed 's/^/      /' "${work}/xorriso.log" >&2; die "xorriso failed"; }
ok "$(du -h "${CACHE_DIR}/${out_iso}" | cut -f1)  ${CACHE_DIR}/${out_iso}"

# ---------------------------------------------------------------------------
# 7. Upload to Proxmox
# ---------------------------------------------------------------------------
if [[ -z "${DO_UPLOAD}" ]]; then
  printf '\n'
  info "built, not uploaded (--no-upload)."
  info "Upload it yourself, or re-run without --no-upload."
  exit 0
fi

[[ -n "${token_secret}" ]] || token_secret="${PROXMOX_VE_API_TOKEN#*=}"
[[ -n "${token_secret}" ]] || die "no API token secret in ${TFVARS} or PROXMOX_VE_API_TOKEN"
auth="Authorization: PVEAPIToken=${token_id}=${token_secret}"

log "uploading to ${node}:${storage}"
existing="$(curl -sk --max-time 20 -H "${auth}" \
  "${endpoint}/api2/json/nodes/${node}/storage/${storage}/content?content=iso" \
  | grep -o "${storage}:iso/${out_iso}" | head -n1 || true)"

if [[ -n "${existing}" ]]; then
  if [[ -z "${FORCE}" ]]; then
    printf '\n'
    info "${storage}:iso/${out_iso} is already on ${node}."
    info "Re-run with --force to replace it."
    printf '\n%s  set this in %s:%s\n' "${BOLD}" "${TFVARS}" "${OFF}"
    printf '    iso_file_id = "%s:iso/%s"\n\n' "${storage}" "${out_iso}"
    exit 0
  fi
  info "removing the existing copy first"
  curl -sk --max-time 60 -X DELETE -H "${auth}" \
    "${endpoint}/api2/json/nodes/${node}/storage/${storage}/content/${storage}:iso/${out_iso}" >/dev/null
fi

upid="$(curl -sk --max-time 1800 -H "${auth}" \
  -F "content=iso" \
  -F "filename=@${CACHE_DIR}/${out_iso};filename=${out_iso}" \
  "${endpoint}/api2/json/nodes/${node}/storage/${storage}/upload" \
  | sed -n 's/.*"data":"\(UPID[^"]*\)".*/\1/p')"
[[ -n "${upid}" ]] || die "upload was rejected by Proxmox (check the token's Datastore.AllocateTemplate permission)"

info "waiting for Proxmox to finish storing it"
deadline=$(( SECONDS + 900 ))
while (( SECONDS < deadline )); do
  status="$(curl -sk --max-time 20 -H "${auth}" \
    "${endpoint}/api2/json/nodes/${node}/tasks/${upid}/status")"
  if grep -q '"status":"stopped"' <<< "${status}"; then break; fi
  sleep 3
done
grep -q '"exitstatus":"OK"' <<< "${status}" \
  || die "Proxmox reported the upload failed: ${status}"

ok "uploaded ${storage}:iso/${out_iso}"
printf '\n%s  set this in %s:%s\n' "${BOLD}" "${TFVARS}" "${OFF}"
printf '    iso_file_id = "%s:iso/%s"\n' "${storage}" "${out_iso}"
printf '\n  then: terraform apply\n\n'
