#!/usr/bin/env bash
#
# Shellcheck, at the version pinned in config/versions.env.
#
# One definition of "the shell check", used by both `make lint` and CI. The
# version matters: shellcheck 0.11 dropped a warning that 0.9 and 0.10 still
# emit, so an unpinned CI once failed on a file that had passed locally.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../config/versions.env
source config/versions.env

FILES=(
  scripts/*.sh scripts/lib/*.sh
  installer/*.sh installer/lib/*.sh
  docker/*.sh
  terraform/*.sh
  tests/ansible/*.sh tests/ansible/unit/*.sh tests/shell/*.sh
)

# --external-sources follows `source` between our own library files;
# --severity=warning keeps style notes from drowning real findings.
ARGS=(--external-sources --severity=warning)

want="${SHELLCHECK_VERSION#v}"
have=""
if command -v shellcheck >/dev/null 2>&1; then
  have="$(shellcheck --version | awk '/^version:/{print $2}')"
fi

if [[ "${have}" == "${want}" ]]; then
  exec shellcheck "${ARGS[@]}" "${FILES[@]}"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if [[ -n "${have}" ]]; then
    printf '     local shellcheck is %s; using the pinned %s via docker\n' "${have}" "${want}"
  fi
  exec docker run --rm -v "${PWD}:/mnt:ro" -w /mnt \
    "koalaman/shellcheck:${SHELLCHECK_VERSION}" "${ARGS[@]}" "${FILES[@]}"
elif [[ -n "${have}" ]]; then
  printf '     warning: shellcheck %s found but %s is pinned - results may differ\n' \
    "${have}" "${want}" >&2
  exec shellcheck "${ARGS[@]}" "${FILES[@]}"
else
  printf 'fail shellcheck is not installed and docker is unavailable\n' >&2
  exit 1
fi
