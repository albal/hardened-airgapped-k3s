# shellcheck shell=bash
# Collects the only two things the operator has to know: the node IPs and the
# root password. Everything else has a sensible default or is generated.
#
# Non-interactive overrides (useful in CI):
#   K3S_NODE_IPS=10.0.0.11,10.0.0.12,10.0.0.13
#   K3S_SSH_USER=root  K3S_SSH_PORT=22  K3S_SSH_PASSWORD=...  K3S_BECOME_PASSWORD=...
#   K3S_CLUSTER_NAME=k3s-airgap  ASSUME_YES=1
#   K3S_VIP_ADDRESS=10.0.0.50    K3S_VIP_INTERFACE=ens18

NODE_IPS=()
SSH_USER=""
SSH_PORT=""
SSH_PASSWORD=""
BECOME_PASSWORD=""
CLUSTER_NAME=""
VIP_ADDRESS=""
VIP_INTERFACE=""

valid_ipv4() {
  local ip="$1" o
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a o <<< "${ip}"
  for part in "${o[@]}"; do
    [[ "${part}" =~ ^0[0-9]+$ ]] && return 1        # no leading zeroes
    (( part >= 0 && part <= 255 )) || return 1
  done
  return 0
}

have_tty() { [[ -t 0 || -e /dev/tty ]]; }

collect_inputs() {
  CLUSTER_NAME="${K3S_CLUSTER_NAME:-k3s-airgap}"
  SSH_USER="${K3S_SSH_USER:-root}"
  SSH_PORT="${K3S_SSH_PORT:-22}"

  # ---- non-interactive path ------------------------------------------------
  if [[ -n "${K3S_NODE_IPS:-}" ]]; then
    IFS=',' read -r -a NODE_IPS <<< "${K3S_NODE_IPS// /}"
    [[ -n "${K3S_SSH_PASSWORD:-}" ]] || die "K3S_NODE_IPS was set, so K3S_SSH_PASSWORD is required too"
    SSH_PASSWORD="${K3S_SSH_PASSWORD}"
    BECOME_PASSWORD="${K3S_BECOME_PASSWORD:-${SSH_PASSWORD}}"
    VIP_ADDRESS="${VIP_ADDRESS:-${K3S_VIP_ADDRESS:-}}"
    VIP_INTERFACE="${VIP_INTERFACE:-${K3S_VIP_INTERFACE:-}}"
    validate_nodes
    info "using ${#NODE_IPS[@]} node(s) from K3S_NODE_IPS"
    [[ -n "${VIP_ADDRESS}" ]] && info "virtual IP ${VIP_ADDRESS}"
    return 0
  fi

  if ! have_tty; then
    die "no terminal available. Run the installer interactively, or set K3S_NODE_IPS and K3S_SSH_PASSWORD."
  fi

  # ---- interactive path ----------------------------------------------------
  info "Enter the machines that will form the cluster. They must already be"
  info "running Ubuntu or Debian, be reachable over SSH, and have python3 installed."
  printf '\n'

  local count
  ask count "How many nodes" "3"
  [[ "${count}" =~ ^[0-9]+$ ]] && (( count >= 1 )) || die "node count must be a positive integer"
  (( count % 2 == 1 )) || warn "an even number of servers cannot form an etcd quorum; 3 is recommended"

  local i ip
  for (( i = 1; i <= count; i++ )); do
    while true; do
      ask ip "IP address of node ${i}"
      if ! valid_ipv4 "${ip}"; then
        warn "'${ip}' is not a valid IPv4 address"
      elif [[ " ${NODE_IPS[*]-} " == *" ${ip} "* ]]; then
        warn "${ip} was already entered"
      else
        NODE_IPS+=("${ip}")
        break
      fi
    done
  done

  ask SSH_USER "SSH user" "${SSH_USER}"
  ask SSH_PORT "SSH port" "${SSH_PORT}"
  ask_secret SSH_PASSWORD "Password for ${SSH_USER}@<node>"

  if [[ "${SSH_USER}" != "root" ]]; then
    if confirm "Is the sudo password the same as the SSH password?"; then
      BECOME_PASSWORD="${SSH_PASSWORD}"
    else
      ask_secret BECOME_PASSWORD "sudo password for ${SSH_USER}"
    fi
  else
    # Consumed by write_inventory() in stages.sh.
    # shellcheck disable=SC2034
    BECOME_PASSWORD="${SSH_PASSWORD}"
  fi

  ask CLUSTER_NAME "Cluster name" "${CLUSTER_NAME}"

  # Optional: one floating address for the API, the ingress and the registry,
  # so none of them depend on a single machine staying up.
  if [[ -z "${VIP_ADDRESS}" ]]; then
    printf '\n'
    info "A virtual IP gives the cluster one stable address that moves between"
    info "nodes. It must be free, and on the same subnet as the nodes."
    while true; do
      ask VIP_ADDRESS "Virtual IP for the API and ingress (or 'none')" "none"
      [[ "${VIP_ADDRESS}" == "none" ]] && { VIP_ADDRESS=""; break; }
      if ! valid_ipv4 "${VIP_ADDRESS}"; then
        warn "'${VIP_ADDRESS}' is not a valid IPv4 address"
      elif [[ " ${NODE_IPS[*]} " == *" ${VIP_ADDRESS} "* ]]; then
        warn "${VIP_ADDRESS} is one of the node addresses - the VIP must be free"
      else
        break
      fi
    done
  fi

  validate_nodes

  printf '\n'
  rule
  info "cluster   ${CLUSTER_NAME}"
  info "nodes     ${NODE_IPS[*]}"
  info "ssh       ${SSH_USER}@<node>:${SSH_PORT} (password auth)"
  if [[ -n "${VIP_ADDRESS}" ]]; then
    info "vip       ${VIP_ADDRESS} (api, ingress, registry)"
    info "harbor    http://${VIP_ADDRESS}:${HARBOR_NODEPORT}"
    info "demo      http://${VIP_ADDRESS}/ and http://<node>:${DEMO_NODEPORT}"
  else
    info "vip       none - services are reached per node"
    info "harbor    http://${NODE_IPS[0]}:${HARBOR_NODEPORT}"
    info "demo      http://<node>:${DEMO_NODEPORT}"
  fi
  rule
  printf '\n'

  if [[ -z "${ASSUME_YES:-}" ]]; then
    confirm "k3s will be installed on these machines. Continue?" \
      || die "aborted at operator's request - nothing was changed"
  fi
}

validate_nodes() {
  (( ${#NODE_IPS[@]} > 0 )) || die "no node IP addresses given"
  local ip
  for ip in "${NODE_IPS[@]}"; do
    valid_ipv4 "${ip}" || die "'${ip}' is not a valid IPv4 address"
  done
  [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] && (( SSH_PORT > 0 && SSH_PORT < 65536 )) \
    || die "'${SSH_PORT}' is not a valid TCP port"
  local uniq
  uniq="$(printf '%s\n' "${NODE_IPS[@]}" | sort -u | wc -l)"
  (( uniq == ${#NODE_IPS[@]} )) || die "duplicate node IP addresses were given"

  if [[ -n "${VIP_ADDRESS}" ]]; then
    valid_ipv4 "${VIP_ADDRESS}" || die "'${VIP_ADDRESS}' is not a valid IPv4 address for the VIP"
    if [[ " ${NODE_IPS[*]} " == *" ${VIP_ADDRESS} "* ]]; then
      die "the VIP (${VIP_ADDRESS}) must not be one of the node addresses"
    fi
  fi

  # Explicit success: the function's exit status is the caller's, and a trailing
  # test that happens to be false would otherwise abort the installer under set -e.
  return 0
}
