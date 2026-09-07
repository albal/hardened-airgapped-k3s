#!/usr/bin/env bash
#
# Integration tests: run the playbooks against throwaway systemd containers and
# assert on what they actually did.
#
# Not part of the pull-request CI - it needs Docker, privileged containers and a
# few minutes. Run it locally with `make test-integration`, or from the
# integration workflow on demand.
#
# What this can and cannot cover is spelled out in tests/README.md. The short
# version: containers can exercise the package staging and the preflight
# assertions faithfully, but they cannot present a spare /dev/sd*, so disk
# selection is covered by the unit tests instead.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

BASE_IMAGE="${BASE_IMAGE:-debian:13}"
FIXTURE_IMAGE="k3s-airgap-test-node"
NET="k3s-airgap-test-net"
NODE_COUNT="${NODE_COUNT:-2}"
SSH_PASSWORD="testpassword"
WORK="$(mktemp -d)"

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
else
  RED=""; GREEN=""; CYAN=""; DIM=""; BOLD=""; OFF=""
fi
log()  { printf '\n%s==>%s %s\n' "${CYAN}${BOLD}" "${OFF}" "$*"; }
ok()   { printf '%s  ok%s %s\n' "${GREEN}" "${OFF}" "$*"; PASS=$((PASS + 1)); }
bad()  { printf '%sfail%s %s\n' "${RED}${BOLD}" "${OFF}" "$*"; FAIL=$((FAIL + 1)); }
dim()  { printf '%s     %s%s\n' "${DIM}" "$*" "${OFF}"; }
die()  { printf '\n%sfail%s %s\n' "${RED}${BOLD}" "${OFF}" "$*" >&2; exit 1; }

PASS=0
FAIL=0

# The playbooks are driven from a container that has ansible and the three
# collections. The installer image already is one; if it has not been built,
# make a small runner instead rather than demanding a two-gigabyte bundle for a
# four-minute test.
IMAGE="$(sed -n 's/^INSTALLER_IMAGE="\(.*\)"/\1/p' config/versions.env)"
TAG="$(sed -n 's/^INSTALLER_TAG="\(.*\)"/\1/p' config/versions.env)"
if ! docker image inspect "${IMAGE}:${TAG}" >/dev/null 2>&1; then
  IMAGE="k3s-airgap-test-runner"; TAG="local"
  if ! docker image inspect "${IMAGE}:${TAG}" >/dev/null 2>&1; then
    log "installer image not built - building a minimal ansible runner"
    mkdir -p "${WORK}/runner"
    cat > "${WORK}/runner/Dockerfile" <<'RUNNER'
FROM python:3.12-slim-bookworm
RUN apt-get update  && apt-get install -y --no-install-recommends openssh-client sshpass  && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir "ansible-core>=2.17,<2.21" netaddr jmespath
RUN ansible-galaxy collection install community.general ansible.posix ansible.utils       -p /usr/share/ansible/collections
RUNNER
    docker build -q -t "${IMAGE}:${TAG}" "${WORK}/runner" >/dev/null       || die "could not build the test runner image"
  fi
fi

cleanup() {
  local i
  for (( i = 1; i <= NODE_COUNT; i++ )); do
    docker rm -f "k3s-test-node-${i}" >/dev/null 2>&1 || true
  done
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixture: a container close enough to a real node - systemd as PID 1, sshd,
# python3 - but deliberately WITHOUT the packages the offline stage installs.
# ---------------------------------------------------------------------------
log "building the fixture image from ${BASE_IMAGE}"
cat > "${WORK}/Dockerfile" <<EOF
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \\
      systemd systemd-sysv dbus openssh-server python3 iproute2 kmod \\
 && rm -rf /var/lib/apt/lists/* \\
 && apt-get purge -y python3-apt policycoreutils open-iscsi nfs-common cryptsetup 2>/dev/null || true
RUN mkdir -p /run/sshd \\
 && echo 'root:${SSH_PASSWORD}' | chpasswd \\
 && sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \\
 && systemctl enable ssh
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
docker build -q -t "${FIXTURE_IMAGE}" "${WORK}" >/dev/null || die "fixture image build failed"

log "starting ${NODE_COUNT} node(s)"
docker network create "${NET}" >/dev/null 2>&1 || true
NODE_IPS=()
for (( i = 1; i <= NODE_COUNT; i++ )); do
  docker rm -f "k3s-test-node-${i}" >/dev/null 2>&1 || true
  # --cgroupns=private matters: with the host cgroup namespace the containers
  # fight over the same cgroup tree and systemd misbehaves in all of them.
  docker run -d --name "k3s-test-node-${i}" --hostname "k3s-test-node-${i}" \
    --network "${NET}" --privileged --cgroupns=private \
    --tmpfs /run --tmpfs /run/lock \
    "${FIXTURE_IMAGE}" >/dev/null
  NODE_IPS+=("$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "k3s-test-node-${i}")")
done
sleep 6
dim "nodes: ${NODE_IPS[*]}"

# ---------------------------------------------------------------------------
# Drive the playbooks exactly as the installer does: over SSH, with the same
# inventory shape.
# ---------------------------------------------------------------------------
{
  echo "---"
  echo "k3s_cluster:"
  echo "  children:"
  echo "    server:"
  echo "      hosts:"
  for ip in "${NODE_IPS[@]}"; do echo "        ${ip}:"; done
  echo "    agent:"
  echo "      hosts: {}"
  echo "  vars:"
  echo "    ansible_user: root"
  echo "    ansible_password: \"{{ lookup('env', 'INSTALLER_SSH_PASSWORD') }}\""
  echo "    ansible_become: true"
  echo "    ansible_become_method: ansible.builtin.sudo"
  echo "    ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password'"
} > "${WORK}/inventory.yml"

# vars.yml mirrors what write_inventory() generates.
{
  echo "---"
  echo "target_arch: amd64"
  echo "api_endpoint: ${NODE_IPS[0]}"
  echo "vip_address: \"\""
} > "${WORK}/vars.yml"

play() {
  local playbook="$1"; shift
  docker run --rm --network "${NET}" \
    -v "${REPO_ROOT}:/repo:ro" -v "${WORK}:/work" \
    -e INSTALLER_SSH_PASSWORD="${SSH_PASSWORD}" \
    -e ANSIBLE_CONFIG=/repo/tests/ansible/ansible.cfg \
    -e ANSIBLE_STDOUT_CALLBACK=default \
    --entrypoint ansible-playbook "${IMAGE}:${TAG}" \
    -i /work/inventory.yml "/repo/ansible/playbooks/${playbook}" "$@" 2>&1
}

# expect_output <label> <pattern> <playbook> [ansible args...]
#
# Captures the run before matching. Piping straight into grep does not work
# here: `set -o pipefail` is on, most of these playbooks are *expected* to fail,
# and the pipeline would then report the playbook's non-zero status rather than
# whether the pattern matched.
expect_output() {
  local label="$1" pattern="$2"; shift 2
  local out
  out="$(play "$@" 2>&1 || true)"
  if grep -q -- "${pattern}" <<< "${out}"; then
    ok "${label}"
  else
    bad "${label}"
    printf '%s       (last lines of the run)%s\n' "${DIM}" "${OFF}"
    tail -12 <<< "${out}" | sed 's/^/       /'
  fi
}

on_node()  { docker exec "k3s-test-node-$1" sh -c "$2" 2>/dev/null; }
on_nodes() {
  local i
  for (( i = 1; i <= NODE_COUNT; i++ )); do
    docker exec "k3s-test-node-${i}" sh -c "$1" >/dev/null 2>&1 || true
  done
}
purge_offline_packages() {
  on_nodes 'dpkg --purge --force-depends python3-apt policycoreutils open-iscsi nfs-common cryptsetup'
}

# ---------------------------------------------------------------------------
log "00-preflight: a healthy node passes"
expect_output "preflight passes on a healthy node" 'failed=0' \
  00-preflight.yml -e @/work/vars.yml

log "00-preflight: the assertions actually fire"
# Move each threshold rather than faking hardware, and check the message the
# operator would see - not just a non-zero exit code.
expect_output "memory assertion fires with its own message" 'MB RAM' \
  00-preflight.yml -e @/work/vars.yml -e preflight_min_memory_mb=99999999

expect_output "disk-space assertion fires with its own message" 'GB free' \
  00-preflight.yml -e @/work/vars.yml -e preflight_min_free_gb=999999

expect_output "architecture assertion fires with its own message" 'but the bundle' \
  00-preflight.yml -e @/work/vars.yml -e target_arch=arm64

# ---------------------------------------------------------------------------
log "10-offline-packages: installs from the staged .debs, then is idempotent"
release="$(on_node 1 '. /etc/os-release; echo "${ID}-${VERSION_ID}"')"
if [[ ! -d "artifacts/debs/${release}" ]]; then
  dim "no staged .debs for ${release} - skipping (run ./scripts/01-download-artifacts.sh)"
else
  out="$(play 10-offline-packages.yml 2>&1 || true)"
  if grep -q 'failed=0' <<< "${out}"; then
    ok "offline packages installed"
  else
    bad "offline package install failed"
  fi

  missing=""
  for pkg in python3-apt policycoreutils open-iscsi nfs-common cryptsetup; do
    on_node 1 "dpkg-query -W -f='\${Status}' ${pkg} 2>/dev/null | grep -q 'install ok installed'" \
      || missing="${missing} ${pkg}"
  done
  if [[ -z "${missing}" ]]; then
    ok "all five packages present on the node"
  else
    bad "still missing:${missing}"
  fi

  # The second run must change nothing. Idempotency is the property that makes
  # re-running the installer safe.
  expect_output "second run changes nothing" 'changed=0.*failed=0' 10-offline-packages.yml
fi

log "10-offline-packages: an unstaged release fails with a useful message"
# The packages have to be missing for this branch to be reached at all - with
# them already installed the play short-circuits and proves nothing.
purge_offline_packages
on_nodes 'cp /etc/os-release /etc/os-release.bak; sed -i "s/^VERSION_ID=.*/VERSION_ID=\"99\"/" /etc/os-release'
expect_output "unstaged release is reported, not silently skipped" 'no .debs were staged' \
  10-offline-packages.yml
on_nodes 'mv /etc/os-release.bak /etc/os-release'

# ---------------------------------------------------------------------------
log "20-longhorn-node-prep: refuses to run without open-iscsi"
on_nodes 'dpkg --purge --force-depends open-iscsi'
expect_output "missing open-iscsi is caught with an explicit message" 'open-iscsi is not installed' \
  20-longhorn-node-prep.yml -e @/work/vars.yml

log "20-longhorn-node-prep: refuses to guess when there is no spare disk"
# Reinstall open-iscsi first: otherwise the play stops on the iSCSI assertion and
# this test would "pass" without ever reaching the disk logic.
if [[ -d "artifacts/debs/${release}" ]]; then
  play 10-offline-packages.yml >/dev/null 2>&1 || true
  # --skip-tags iscsi: a container has no /lib/modules, so modprobe cannot work
  # there. Those two tasks are covered on real nodes, not here.
  expect_output "stops rather than formatting something it should not" \
    'has no spare disk for Longhorn' 20-longhorn-node-prep.yml -e @/work/vars.yml --skip-tags iscsi
else
  dim "needs staged .debs to restore open-iscsi - skipped"
fi

# ---------------------------------------------------------------------------
printf '\n'
if (( FAIL == 0 )); then
  printf '%s  %d checks passed%s\n\n' "${GREEN}${BOLD}" "${PASS}" "${OFF}"
else
  printf '%s  %d passed, %d failed%s\n\n' "${RED}${BOLD}" "${PASS}" "${FAIL}" "${OFF}"
  exit 1
fi
