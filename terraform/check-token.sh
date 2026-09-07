#!/usr/bin/env bash
#
# Checks the Proxmox API token before `terraform apply`, because the failure
# mode otherwise is an opaque "HTTP 403 - Permission check failed" at VM create
# time, long after Terraform has decided the plan is fine.
#
# Reads terraform.tfvars, or PROXMOX_VE_API_TOKEN if the secret is not in there.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
TFVARS="${1:-terraform.tfvars}"

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
else
  RED=""; GREEN=""; DIM=""; BOLD=""; OFF=""
fi
ok()   { printf '%s  ok%s %s\n' "${GREEN}" "${OFF}" "$*"; }
fail() { printf '\n%sfail%s %s\n\n' "${RED}${BOLD}" "${OFF}" "$*" >&2; exit 1; }

tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "${TFVARS}" | head -n1; }

command -v curl >/dev/null || fail "curl is required"
[[ -f "${TFVARS}" ]] || fail "no ${TFVARS} - copy terraform.tfvars.example to it first"

endpoint="$(tfvar pve_endpoint)"; endpoint="${endpoint%/}"
node="$(tfvar pve_node)"
token_id="$(tfvar pve_token_id)"
token_secret="$(tfvar pve_token_secret)"

if [[ -z "${token_secret}" ]]; then
  # Fall back to the environment variable the provider also understands.
  if [[ -n "${PROXMOX_VE_API_TOKEN:-}" ]]; then
    token_id="${PROXMOX_VE_API_TOKEN%%=*}"
    token_secret="${PROXMOX_VE_API_TOKEN#*=}"
  else
    fail "no token secret in ${TFVARS} and PROXMOX_VE_API_TOKEN is not set"
  fi
fi

auth="Authorization: PVEAPIToken=${token_id}=${token_secret}"
api() { curl -sk --max-time 15 -H "${auth}" "${endpoint}/api2/json$1"; }

printf '%s  %s as %s%s\n\n' "${DIM}" "${endpoint}" "${token_id}" "${OFF}"

# 1. Reachable and the token authenticates at all.
code="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' -H "${auth}" "${endpoint}/api2/json/version" || true)"
case "${code}" in
  200) ok "endpoint reachable, token authenticates" ;;
  000) fail "cannot reach ${endpoint} - check the hostname, the port and any firewall in between" ;;
  401) fail "token rejected (HTTP 401). Check pve_token_id and pve_token_secret.
       The secret is only shown when the token is created; if it was lost, make a new one:
         pveum user token remove ${token_id%%!*} ${token_id##*!}
         pveum user token add    ${token_id%%!*} ${token_id##*!} --privsep 0" ;;
  *)   fail "unexpected HTTP ${code} from ${endpoint}/api2/json/version" ;;
esac

# 2. The token actually carries permissions. A token created with privilege
#    separation left on (the default) authenticates fine and can do nothing.
perms="$(api /access/permissions)"
if [[ "${perms}" =~ \"data\"[[:space:]]*:[[:space:]]*\{\} ]] || [[ "${perms}" == '{"data":{}}' ]]; then
  fail "the token has no permissions at all.

       This is privilege separation: a token created without --privsep 0 inherits
       none of its user's rights, so every call comes back 403 even though the
       token itself is valid.

       Fix it on the PVE host (web UI > ${node} > Shell, or ssh root@<host>):

         ${BOLD}pveum user token modify ${token_id%%!*} ${token_id##*!} --privsep 0${OFF}

       Or, to keep privilege separation on, grant the token rights explicitly:

         pveum acl modify / --tokens '${token_id}' --roles Administrator

       Then re-run this script."
fi
ok "token carries permissions"

# 3. The specific things this configuration needs.
if ! api /nodes | grep -q "\"node\":\"${node}\""; then
  fail "node '${node}' is not visible to this token. Nodes it can see:
       $(api /nodes | sed -n 's/.*"node":"\([^"]*\)".*/\1/p' | tr '\n' ' ')"
fi
ok "node '${node}' visible"

iso="$(tfvar iso_file_id)"
iso_store="${iso%%:*}"
iso_vol="${iso#*:}"
content="$(api "/nodes/${node}/storage/${iso_store}/content")"
if [[ "${content}" == *"${iso_vol}"* ]]; then
  ok "install media present: ${iso}"
elif [[ "${content}" == *"Permission check failed"* ]]; then
  fail "cannot list storage '${iso_store}' - the token lacks Datastore.Audit on it"
else
  fail "install media '${iso}' not found on storage '${iso_store}' of node '${node}'.
       ISOs Proxmox can see there:
       $(printf '%s' "${content}" | sed -n 's/.*"volid":"\([^"]*iso[^"]*\)".*/\1/p' | tr '\n' ' ')
       Upload it, or point iso_file_id at one of the above."
fi

printf '\n%s  ready - run: terraform apply%s\n\n' "${GREEN}${BOLD}" "${OFF}"
