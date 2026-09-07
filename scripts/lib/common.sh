# shellcheck shell=bash
# Shared helpers for the build-side scripts (run on an INTERNET-CONNECTED host).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/artifacts}"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"

# shellcheck source=../../config/versions.env
source "${REPO_ROOT}/config/versions.env"

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

log()  { printf '%s==>%s %s\n' "${C_BLUE}${C_BOLD}" "${C_RESET}" "$*"; }
info() { printf '    %s\n' "$*"; }
dim()  { printf '%s    %s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
ok()   { printf '%s  ok%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '%swarn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2; exit 1; }

require_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "missing required command(s): ${missing[*]}"
}

# fetch <url> <dest> -- skips the download when <dest> already exists.
fetch() {
  local url="$1" dest="$2"
  if [[ -s "$dest" ]]; then
    dim "cached  $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  info "fetch   $(basename "$dest")"
  local progress=(--no-progress-meter)
  [[ -t 2 ]] && progress=(--progress-bar)
  curl -fL "${progress[@]}" --retry 3 --retry-delay 2 --connect-timeout 20 -o "${dest}.part" "$url" \
    || die "download failed: $url"
  mv "${dest}.part" "$dest"
}

# human_size <path>
human_size() { du -sh "$1" 2>/dev/null | cut -f1; }

# compressor picks zstd when available (much faster/smaller for image tarballs),
# otherwise gzip. Both extensions are recognised by k3s' airgap image importer
# and by the k3s-ansible airgap role's file globs.
image_tar_suffix() {
  if command -v zstd >/dev/null 2>&1; then echo "tar.zst"; else echo "tar.gz"; fi
}
compress_stream() {
  if command -v zstd >/dev/null 2>&1; then zstd -T0 -12 -q -o "$1" -; else gzip -6 -c > "$1"; fi
}
