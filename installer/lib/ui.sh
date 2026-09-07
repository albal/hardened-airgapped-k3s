# shellcheck shell=bash
# Terminal output helpers for the airgapped installer.

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

STEP_INDEX=0
STEP_TOTAL="${STEP_TOTAL:-10}"

banner() {
  printf '%s\n' "${C_CYAN}${C_BOLD}"
  cat <<'ART'
  ┌───────────────────────────────────────────────────────────┐
  │   hardened airgapped k3s  ·  offline cluster installer     │
  │   k3s + Harbor registry + per-node demo workload           │
  └───────────────────────────────────────────────────────────┘
ART
  printf '%s' "${C_RESET}"
}

step() {
  STEP_INDEX=$((STEP_INDEX + 1))
  printf '\n%s[%d/%d]%s %s%s%s\n' \
    "${C_CYAN}${C_BOLD}" "${STEP_INDEX}" "${STEP_TOTAL}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}"
}
info() { printf '      %s\n' "$*"; }
dim()  { printf '%s      %s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
ok()   { printf '%s   ok%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '%s warn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die()  { printf '\n%s fail%s %s\n\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2; exit 1; }

rule() { printf '%s      %s%s\n' "${C_DIM}" "------------------------------------------------------------" "${C_RESET}"; }

# ask <varname> <prompt> [default]
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
  local __suffix=""
  [[ -n "${__default}" ]] && __suffix=" ${C_DIM}[${__default}]${C_RESET}"
  while true; do
    printf '%s   ?%s %s%s: ' "${C_CYAN}" "${C_RESET}" "${__prompt}" "${__suffix}" > /dev/tty
    IFS= read -r __reply < /dev/tty || die "input stream closed"
    [[ -z "${__reply}" ]] && __reply="${__default}"
    [[ -n "${__reply}" ]] && break
    warn "a value is required"
  done
  printf -v "${__var}" '%s' "${__reply}"
}

# ask_secret <varname> <prompt>
ask_secret() {
  local __var="$1" __prompt="$2" __reply=""
  while true; do
    printf '%s   ?%s %s: ' "${C_CYAN}" "${C_RESET}" "${__prompt}" > /dev/tty
    IFS= read -rs __reply < /dev/tty || die "input stream closed"
    printf '\n' > /dev/tty
    [[ -n "${__reply}" ]] && break
    warn "a value is required"
  done
  printf -v "${__var}" '%s' "${__reply}"
}

# confirm <prompt> -- returns 0 for yes
confirm() {
  local reply
  while true; do
    printf '%s   ?%s %s [y/N]: ' "${C_CYAN}" "${C_RESET}" "$1" > /dev/tty
    IFS= read -r reply < /dev/tty || return 1
    case "${reply,,}" in
      y|yes) return 0 ;;
      ""|n|no) return 1 ;;
      *) warn "answer y or n" ;;
    esac
  done
}
