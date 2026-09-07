#!/usr/bin/env bash
#
# Static checks for the Ansible content: syntax, lint and YAML.
#
# Fast, hermetic and safe to run anywhere - nothing connects to a node. This is
# what CI runs on every pull request.
#
# Needs ansible-playbook, ansible-lint and yamllint on PATH. If they are not
# there but the installer image is built, it re-runs itself inside that image,
# which already carries ansible and the three collections.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
else
  RED=""; GREEN=""; CYAN=""; BOLD=""; OFF=""
fi
log()  { printf '%s==>%s %s\n' "${CYAN}${BOLD}" "${OFF}" "$*"; }
ok()   { printf '%s  ok%s %s\n' "${GREEN}" "${OFF}" "$*"; }
fail() { printf '%sfail%s %s\n' "${RED}${BOLD}" "${OFF}" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Re-run inside the installer image when the tooling is not installed locally
# ---------------------------------------------------------------------------
# `command -v` is not enough: a leftover shim from an uninstalled ansible is on
# PATH and fails with ModuleNotFoundError, so check the tool actually runs.
if [[ -z "${IN_CONTAINER:-}" ]] && ! ansible-playbook --version >/dev/null 2>&1; then
  image="$(sed -n 's/^INSTALLER_IMAGE="\(.*\)"/\1/p' config/versions.env)"
  tag="$(sed -n 's/^INSTALLER_TAG="\(.*\)"/\1/p' config/versions.env)"
  if docker image inspect "${image}:${tag}" >/dev/null 2>&1; then
    log "ansible not on PATH - running inside ${image}:${tag}"
    exec docker run --rm -v "${REPO_ROOT}:/repo:ro" -w /repo \
      -e IN_CONTAINER=1 -e NO_COLOR="${NO_COLOR:-}" \
      --entrypoint bash "${image}:${tag}" \
      -c 'pip install --quiet ansible-lint yamllint >/dev/null 2>&1; exec tests/ansible/run-static.sh'
  fi
  fail "ansible-playbook not found, and the installer image is not built.
     Install ansible-core, or run 'make build' first."
fi

INVENTORY=tests/ansible/fixtures/inventory.yml
PLAYBOOKS=(
  ansible/playbooks/00-preflight.yml
  ansible/playbooks/10-offline-packages.yml
  ansible/playbooks/20-longhorn-node-prep.yml
  ansible/playbooks/30-post-install.yml
)

# ---------------------------------------------------------------------------
# 1. Syntax. Also covers the vendored collection's site.yml, because the
#    installer runs it and a bad submodule bump should fail here, not on a node.
# ---------------------------------------------------------------------------
log "syntax check"
ANSIBLE_CONFIG=tests/ansible/ansible.cfg \
  ansible-playbook --syntax-check -i "${INVENTORY}" \
  "${PLAYBOOKS[@]}" k3s-ansible/playbooks/site.yml >/dev/null \
  || fail "ansible-playbook --syntax-check failed"
ok "$(( ${#PLAYBOOKS[@]} + 1 )) playbooks parse"

# ---------------------------------------------------------------------------
# 2. The shell we hand to nodes
# ---------------------------------------------------------------------------
log "shell syntax"
sh -n ansible/playbooks/files/detect-longhorn-disk.sh \
  || fail "detect-longhorn-disk.sh is not valid POSIX shell"
ok "detect-longhorn-disk.sh"

# ---------------------------------------------------------------------------
# 3. Lint
# ---------------------------------------------------------------------------
if yamllint --version >/dev/null 2>&1; then
  log "yamllint"
  yamllint . || fail "yamllint found problems"
  ok "yaml style"
else
  printf '     yamllint not installed - skipped\n'
fi

if ansible-lint --version >/dev/null 2>&1; then
  log "ansible-lint"
  ansible-lint --nocolor || fail "ansible-lint found problems"
  ok "ansible-lint"
else
  printf '     ansible-lint not installed - skipped\n'
fi

printf '\n%s  all static checks passed%s\n' "${GREEN}${BOLD}" "${OFF}"
