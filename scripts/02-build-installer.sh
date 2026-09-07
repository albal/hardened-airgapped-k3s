#!/usr/bin/env bash
#
# STAGE 2 (runs on the INTERNET-CONNECTED build host, after 01-download-artifacts.sh)
#
# Bakes the artifacts, Ansible content and the k3s-ansible submodule into one
# Docker image, then appends that image to a shell header to produce a single
# self-executing file you can carry across the airgap:
#
#   dist/k3s-airgap-installer.run
#
# Running that file on any Linux workstation with Docker prompts for the node
# IPs and root password and builds the cluster.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd docker sha256sum gzip awk
docker info >/dev/null 2>&1 || die "docker daemon is not reachable"

IMAGE_REF="${INSTALLER_IMAGE}:${INSTALLER_TAG}"
RUN_FILE="${DIST_DIR}/k3s-airgap-installer.run"
HEADER="${REPO_ROOT}/docker/selfextract-header.sh"

# ---------------------------------------------------------------------------
# 1. Sanity-check the bundle before spending minutes on a build
# ---------------------------------------------------------------------------
log "checking artifacts"
[[ -d "${ARTIFACT_DIR}" ]] || die "no artifacts directory - run scripts/01-download-artifacts.sh first"
[[ -f "${REPO_ROOT}/k3s-ansible/playbooks/site.yml" ]] \
  || die "the k3s-ansible submodule is empty - run: git submodule update --init"

required=(
  "k3s/k3s-${TARGET_ARCH}"
  "k3s/k3s-install.sh"
  "k3s/k3s-airgap-images-${TARGET_ARCH}.tar.zst"
  "bin/helm"
  "bin/kubectl"
  "harbor/harbor-${HARBOR_CHART_VERSION}.tgz"
  "longhorn/longhorn-${LONGHORN_CHART_VERSION}.tgz"
  "longhorn/images.txt"
  "kube-vip/kube-vip.yaml.tmpl"
  "demo/${DEMO_IMAGE_NAME}.tar"
)
for f in "${required[@]}"; do
  [[ -s "${ARTIFACT_DIR}/${f}" ]] || die "missing artifact: artifacts/${f} - re-run scripts/01-download-artifacts.sh"
done
compgen -G "${ARTIFACT_DIR}/k3s/harbor-images.tar*" >/dev/null \
  || die "missing the Harbor image bundle - re-run scripts/01-download-artifacts.sh"
compgen -G "${ARTIFACT_DIR}/k3s/longhorn-images.tar*" >/dev/null \
  || die "missing the Longhorn image bundle - re-run scripts/01-download-artifacts.sh"
compgen -G "${ARTIFACT_DIR}/k3s/kube-vip-images.tar*" >/dev/null \
  || die "missing the kube-vip image bundle - re-run scripts/01-download-artifacts.sh"
compgen -G "${ARTIFACT_DIR}/debs/*/*.deb" >/dev/null \
  || die "no offline .debs were staged - re-run scripts/01-download-artifacts.sh"

if [[ -f "${ARTIFACT_DIR}/SHA256SUMS" ]]; then
  info "verifying artifact checksums"
  (cd "${ARTIFACT_DIR}" && sha256sum -c --quiet SHA256SUMS) \
    || die "artifact checksums do not match - delete artifacts/ and download again"
fi
ok "artifacts complete ($(human_size "${ARTIFACT_DIR}"))"

# ---------------------------------------------------------------------------
# 2. Build the installer image
# ---------------------------------------------------------------------------
log "building ${IMAGE_REF}"
DOCKER_BUILDKIT=1 docker build \
  --platform linux/amd64 \
  -f "${REPO_ROOT}/docker/Dockerfile.installer" \
  -t "${IMAGE_REF}" \
  "${REPO_ROOT}" || die "docker build failed"

image_size="$(docker image inspect "${IMAGE_REF}" --format '{{.Size}}')"
ok "image built ($(awk -v b="${image_size}" 'BEGIN { printf "%.1f GB", b/1e9 }'))"

# ---------------------------------------------------------------------------
# 3. Assemble the self-executing bundle
# ---------------------------------------------------------------------------
log "assembling ${RUN_FILE##*/}"
mkdir -p "${DIST_DIR}"
payload="${DIST_DIR}/.payload.tar.gz"

info "exporting and compressing the image (several minutes)"
docker save "${IMAGE_REF}" | gzip -1 > "${payload}" || die "docker save failed"

payload_sha="$(sha256sum "${payload}" | cut -d' ' -f1)"
header_lines="$(wc -l < "${HEADER}")"

sed -e "s|@IMAGE_REF@|${IMAGE_REF}|g" \
    -e "s|@PAYLOAD_LINE@|$((header_lines + 1))|g" \
    -e "s|@PAYLOAD_SHA256@|${payload_sha}|g" \
    -e "s|@BUNDLE_VERSION@|${INSTALLER_TAG} (k3s ${K3S_VERSION}, longhorn ${LONGHORN_VERSION}, harbor ${HARBOR_CHART_VERSION}, kube-vip ${KUBE_VIP_VERSION}, ${TARGET_ARCH})|g" \
    "${HEADER}" > "${RUN_FILE}.tmp"

# The substitutions must not have changed the header's line count, or the
# payload offset baked into the file would be wrong.
[[ "$(wc -l < "${RUN_FILE}.tmp")" == "${header_lines}" ]] \
  || die "header line count changed during substitution - payload offset would be wrong"

cat "${payload}" >> "${RUN_FILE}.tmp"
mv "${RUN_FILE}.tmp" "${RUN_FILE}"
chmod 0755 "${RUN_FILE}"
rm -f "${payload}"

(cd "${DIST_DIR}" && sha256sum "$(basename "${RUN_FILE}")" > "$(basename "${RUN_FILE}").sha256")

log "done"
info "bundle:  ${RUN_FILE} ($(human_size "${RUN_FILE}"))"
info "digest:  ${RUN_FILE}.sha256"
printf '\n'
info "Copy both files to the airgapped workstation, then:"
dim  "  sha256sum -c $(basename "${RUN_FILE}").sha256"
dim  "  ./$(basename "${RUN_FILE}")"
