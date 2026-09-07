#!/usr/bin/env bash
#
# The self-executing airgapped installer.
#
# Everything it needs - k3s, its container images, the Harbor chart and images,
# the demo image, Ansible, helm, kubectl and skopeo - is baked into this
# container image. It never touches the internet; it only talks SSH to the nodes
# you name and HTTP to the cluster it just built.
set -euo pipefail

INSTALLER_HOME=/opt/installer
# shellcheck source=/dev/null
source "${INSTALLER_HOME}/versions.env"
# shellcheck source=lib/ui.sh
source "${INSTALLER_HOME}/lib/ui.sh"
# shellcheck source=lib/prompt.sh
source "${INSTALLER_HOME}/lib/prompt.sh"
# shellcheck source=lib/stages.sh
source "${INSTALLER_HOME}/lib/stages.sh"

MODE=install
SKIP_HARBOR=""
SKIP_DEMO=""
SKIP_LONGHORN=""
NO_VIP=""

usage() {
  cat <<USAGE
Usage: k3s-airgap-installer.run [OPTIONS]

Builds a k3s cluster on already-provisioned Ubuntu/Debian machines that have no
internet access, installs Harbor as a private registry, and deploys a per-node
nginx page as a worked example.

Options:
  --reset          uninstall k3s from the nodes and exit
  --vip ADDRESS    floating IP for the API, ingress and registry (kube-vip)
  --vip-interface NIC
                   NIC the VIP binds to (default: each node's default route)
  --no-vip         do not configure a VIP, without being asked
  --skip-longhorn  do not format the data disks or install Longhorn
  --skip-harbor    do not install Harbor (implies --skip-demo)
  --skip-demo      do not deploy the example workload
  -y, --yes        do not ask for confirmation
  -h, --help       show this message

Non-interactive use (all four are required together):
  K3S_NODE_IPS=10.0.0.11,10.0.0.12,10.0.0.13 K3S_SSH_USER=root \\
  K3S_SSH_PASSWORD=... ASSUME_YES=1 ./k3s-airgap-installer.run

Bundle contents: k3s ${K3S_VERSION} (${TARGET_ARCH}), Longhorn
${LONGHORN_VERSION}, Harbor chart ${HARBOR_CHART_VERSION}, kube-vip
${KUBE_VIP_VERSION}, ${DEMO_IMAGE_NAME}:${DEMO_IMAGE_TAG}.
USAGE
}

# K3S_VIP_ADDRESS, K3S_VIP_INTERFACE and ASSUME_YES are read by prompt.sh and
# stages.sh after this file sources them, which shellcheck cannot see.
# shellcheck disable=SC2034
while (( $# > 0 )); do
  case "$1" in
    --reset)       MODE=reset ;;
    --vip)         K3S_VIP_ADDRESS="${2:?--vip needs an address}"; shift ;;
    --vip=*)       K3S_VIP_ADDRESS="${1#*=}" ;;
    --vip-interface)   K3S_VIP_INTERFACE="${2:?--vip-interface needs a NIC}"; shift ;;
    --vip-interface=*) K3S_VIP_INTERFACE="${1#*=}" ;;
    --no-vip)      K3S_VIP_ADDRESS=""; NO_VIP=1 ;;
    --skip-longhorn) SKIP_LONGHORN=1 ;;
    --skip-harbor) SKIP_HARBOR=1; SKIP_DEMO=1 ;;
    --skip-demo)   SKIP_DEMO=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "${OUTPUT_DIR}/logs"
LOG_FILE="${OUTPUT_DIR}/logs/${MODE}-$(date -u +%Y%m%d-%H%M%S).log"
: > "${LOG_FILE}"

on_exit() {
  local rc=$?
  # Everything in /output is written as root inside the container; hand it back
  # to the user who launched the installer so they can actually read it.
  if [[ -n "${INSTALLER_HOST_UID:-}" ]] && (( INSTALLER_HOST_UID != 0 )); then
    chown -R "${INSTALLER_HOST_UID}:${INSTALLER_HOST_GID:-${INSTALLER_HOST_UID}}" \
      "${OUTPUT_DIR}" 2>/dev/null || true
  fi
  (( rc == 0 )) && return 0
  printf '\n%s      full log: %s%s\n' "${C_DIM}" "${LOG_FILE}" "${C_RESET}" >&2
}
trap on_exit EXIT

banner

if ! mountpoint -q "${OUTPUT_DIR}" 2>/dev/null; then
  warn "${OUTPUT_DIR} is not a mounted volume - the kubeconfig, passwords and logs"
  warn "will be lost when this container exits. Run the .run wrapper instead of"
  warn "'docker run' directly, or add: -v \"\$PWD/output:${OUTPUT_DIR}\""
fi

if [[ "${MODE}" == "reset" ]]; then
  STEP_TOTAL=3
  step "Collecting connection details";  collect_inputs
  step "Preparing inventory";            write_inventory
  step "Removing k3s";                   check_connectivity; run_reset
  printf '\n'
  exit 0
fi

# 7 core steps, plus 2 for the VIP, 2 for Longhorn, 1 for Harbor, 2 for the demo.
#
# Whether there is a VIP may not be known until collect_inputs has asked, so the
# count is taken twice: once from the flags for the very first line, then again
# once the answer is in.
compute_step_total() {
  STEP_TOTAL=7
  [[ -z "${NO_VIP}" && -n "${VIP_ADDRESS:-${K3S_VIP_ADDRESS:-}}" ]] && STEP_TOTAL=$((STEP_TOTAL + 2))
  [[ -z "${SKIP_LONGHORN}" ]] && STEP_TOTAL=$((STEP_TOTAL + 2))
  [[ -z "${SKIP_HARBOR}" ]]   && STEP_TOTAL=$((STEP_TOTAL + 1))
  [[ -z "${SKIP_HARBOR}" && -z "${SKIP_DEMO}" ]] && STEP_TOTAL=$((STEP_TOTAL + 2))
  return 0
}

compute_step_total
step "Collecting connection details";        collect_inputs
[[ -n "${NO_VIP}" ]] && VIP_ADDRESS=""
compute_step_total

step "Preparing inventory and credentials";  write_inventory
step "Checking SSH connectivity";            check_connectivity
step "Running preflight checks";             run_preflight

if [[ -n "${VIP_ADDRESS}" ]]; then
  step "Rendering the kube-vip manifest";    render_kube_vip
fi

step "Satisfying OS prerequisites offline";  run_offline_packages
step "Installing k3s ${K3S_VERSION}";        run_k3s_install
step "Retrieving cluster access";            fetch_cluster_access

if [[ -n "${VIP_ADDRESS}" ]]; then
  step "Verifying the virtual IP";           verify_vip
fi

if [[ -z "${SKIP_LONGHORN}" ]]; then
  step "Preparing data disks for Longhorn";           prepare_longhorn_nodes
  step "Installing Longhorn ${LONGHORN_VERSION}";     install_longhorn
fi

if [[ -z "${SKIP_HARBOR}" ]]; then
  step "Installing Harbor ${HARBOR_CHART_VERSION}"; install_harbor
  if [[ -z "${SKIP_DEMO}" ]]; then
    step "Loading the demo image into Harbor";      push_demo_image
    step "Deploying the per-node demo workload";    deploy_demo; verify_demo
  fi
fi

write_summary
