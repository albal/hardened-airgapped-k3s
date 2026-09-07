#!/usr/bin/env bash
#
# Self-executing airgapped k3s installer.
#
# This file is a shell script with a compressed Docker image appended to it.
# Running it loads that image and starts the interactive installer, which asks
# for your node IPs and root password and then builds the cluster.
#
#   ./k3s-airgap-installer.run              install interactively
#   ./k3s-airgap-installer.run --help       installer options
#   ./k3s-airgap-installer.run --reset      uninstall k3s from the nodes
#
# Wrapper-only options (consumed here, not passed on):
#   --output DIR    where to write kubeconfig/passwords/logs (default ./k3s-airgap-output)
#   --load-only     load the image into Docker and exit
#   --verify        check the payload checksum before loading
#
set -euo pipefail

IMAGE_REF="@IMAGE_REF@"
PAYLOAD_LINE=@PAYLOAD_LINE@
PAYLOAD_SHA256="@PAYLOAD_SHA256@"
BUNDLE_VERSION="@BUNDLE_VERSION@"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
OUTPUT_DIR="${PWD}/k3s-airgap-output"
LOAD_ONLY=""
VERIFY=""
PASSTHROUGH=()

while (( $# > 0 )); do
  case "$1" in
    --output)     OUTPUT_DIR="${2:?--output needs a directory}"; shift 2 ;;
    --output=*)   OUTPUT_DIR="${1#*=}"; shift ;;
    --load-only)  LOAD_ONLY=1; shift ;;
    --verify)     VERIFY=1; shift ;;
    *)            PASSTHROUGH+=("$1"); shift ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
die()  { printf '\n  ERROR: %s\n\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 \
  || die "docker is not installed. This installer runs as a container on your workstation;
         the cluster nodes themselves do not need Docker."
docker info >/dev/null 2>&1 \
  || die "cannot talk to the Docker daemon. Start it, or add yourself to the 'docker' group."

printf '\n  hardened-airgapped-k3s installer  ·  bundle %s\n\n' "${BUNDLE_VERSION}"

if [[ -n "${VERIFY}" ]]; then
  say "verifying payload checksum (this reads the whole file)..."
  actual="$(tail -n +${PAYLOAD_LINE} "${SELF}" | sha256sum | cut -d' ' -f1)"
  [[ "${actual}" == "${PAYLOAD_SHA256}" ]] \
    || die "payload checksum mismatch - this file is truncated or corrupt.
         expected ${PAYLOAD_SHA256}
         got      ${actual}"
  say "checksum ok"
fi

if docker image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
  say "installer image ${IMAGE_REF} already loaded"
else
  say "loading installer image ${IMAGE_REF} (a few GB, takes a minute)..."
  tail -n +${PAYLOAD_LINE} "${SELF}" | docker load \
    || die "failed to load the embedded image. Is there enough space in /var/lib/docker?"
fi

if [[ -n "${LOAD_ONLY}" ]]; then
  say "image loaded. Run it yourself with:"
  say "  docker run --rm -it --network host -v \"\$PWD/output:/output\" ${IMAGE_REF}"
  exit 0
fi

WANT_HELP=""
for arg in ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}; do
  [[ "${arg}" == "-h" || "${arg}" == "--help" ]] && WANT_HELP=1
done

if [[ -n "${WANT_HELP}" ]]; then
  cat <<'WRAPPER'

Options handled by this wrapper (everything else is passed to the installer):
  --output DIR    where to write kubeconfig/passwords/logs (default ./k3s-airgap-output)
  --load-only     load the image into Docker and exit
  --verify        check the payload checksum before loading
WRAPPER
else
  mkdir -p "${OUTPUT_DIR}"
  say "output directory: ${OUTPUT_DIR}"
fi
printf '\n'

# --network host so the installer can reach the node IPs and the NodePorts it
# publishes without any port mapping. -t only when we actually have a terminal.
TTY_FLAGS=(-i)
[[ -t 0 && -t 1 ]] && TTY_FLAGS=(-i -t)

# Forward the documented non-interactive settings across the docker boundary.
# Without this the K3S_* variables never reach the installer, which then falls
# back to prompting - and simply fails where there is no terminal, such as CI.
# Only variables that are actually set are passed, so an unset one still means
# "ask me".
ENV_FLAGS=()
for _var in K3S_NODE_IPS K3S_SSH_USER K3S_SSH_PORT K3S_SSH_PASSWORD \
            K3S_BECOME_PASSWORD K3S_CLUSTER_NAME K3S_VIP_ADDRESS \
            K3S_VIP_INTERFACE K3S_EXTRA_SERVER_ARGS K3S_EXTRA_AGENT_ARGS \
            ASSUME_YES NO_COLOR; do
  if [[ -n "${!_var:-}" ]]; then
    ENV_FLAGS+=(-e "${_var}=${!_var}")
  fi
done

exec docker run --rm "${TTY_FLAGS[@]}" \
  --network host \
  --tmpfs /run/installer:rw,nosuid,nodev,mode=0700 \
  -v "${OUTPUT_DIR}:/output" \
  -e "TERM=${TERM:-xterm}" \
  -e "INSTALLER_HOST_UID=$(id -u)" \
  -e "INSTALLER_HOST_GID=$(id -g)" \
  ${ENV_FLAGS[@]+"${ENV_FLAGS[@]}"} \
  "${IMAGE_REF}" "${PASSTHROUGH[@]}"

# The payload starts on the line after __PAYLOAD_BELOW__; nothing past here runs.
exit 0
__PAYLOAD_BELOW__
