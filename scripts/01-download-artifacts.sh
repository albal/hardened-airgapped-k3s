#!/usr/bin/env bash
#
# STAGE 1 (runs on an INTERNET-CONNECTED build host)
#
# Downloads every artifact needed to stand up a 3-node k3s cluster plus a Harbor
# registry on an airgapped network, into ./artifacts. Nothing here runs on the
# airgapped side; stage 2 (02-build-installer.sh) bakes the result into a single
# self-executing installer.
#
# Requires: docker, curl, tar. zstd is used when present.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd docker curl tar awk sed
docker info >/dev/null 2>&1 || die "docker daemon is not reachable (is it running / are you in the docker group?)"

K3S_URL_VERSION="${K3S_VERSION//+/%2B}"      # '+' must be percent-encoded in the release URL
K3S_RELEASE_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_URL_VERSION}"
AIRGAP_DIR="${ARTIFACT_DIR}/k3s"             # this whole directory is shipped to every node
IMG_SUFFIX="$(image_tar_suffix)"

mkdir -p "${AIRGAP_DIR}" "${ARTIFACT_DIR}/bin" "${ARTIFACT_DIR}/harbor" \
         "${ARTIFACT_DIR}/demo" "${ARTIFACT_DIR}/debs"

# ---------------------------------------------------------------------------
# 1. k3s: binary, install script and the base airgap image bundle
# ---------------------------------------------------------------------------
log "k3s ${K3S_VERSION} (${TARGET_ARCH})"

k3s_binary_name="k3s"
[[ "${TARGET_ARCH}" == "amd64" ]] || k3s_binary_name="k3s-${TARGET_ARCH}"

# The airgap role picks up 'k3s-<arch>' before plain 'k3s', so name it that way
# for both architectures.
fetch "${K3S_RELEASE_URL}/${k3s_binary_name}"                          "${AIRGAP_DIR}/k3s-${TARGET_ARCH}"
fetch "${K3S_RELEASE_URL}/k3s-airgap-images-${TARGET_ARCH}.tar.zst"    "${AIRGAP_DIR}/k3s-airgap-images-${TARGET_ARCH}.tar.zst"
fetch "${K3S_RELEASE_URL}/sha256sum-${TARGET_ARCH}.txt"                "${ARTIFACT_DIR}/k3s-sha256sum-${TARGET_ARCH}.txt"
fetch "https://get.k3s.io"                                             "${AIRGAP_DIR}/k3s-install.sh"
chmod +x "${AIRGAP_DIR}/k3s-install.sh"

log "verifying k3s release checksums"
(
  cd "${AIRGAP_DIR}" || exit 1
  # The upstream sums file names the amd64 binary 'k3s'; ours is 'k3s-amd64'.
  awk -v bin="${k3s_binary_name}" -v arch="${TARGET_ARCH}" '
    $2 == bin                                   { print $1 "  k3s-" arch }
    $2 == "k3s-airgap-images-" arch ".tar.zst"  { print $1 "  " $2 }
  ' "${ARTIFACT_DIR}/k3s-sha256sum-${TARGET_ARCH}.txt" > .sums
  [[ -s .sums ]] || die "could not extract checksums for ${TARGET_ARCH} from the k3s release"
  sha256sum -c .sums || die "k3s artifact checksum mismatch - delete artifacts/k3s and retry"
  rm -f .sums
)
ok "k3s artifacts verified"

# ---------------------------------------------------------------------------
# 2. helm + kubectl for the installer image (they drive the cluster over SSH-less
#    kubeconfig once k3s is up)
# ---------------------------------------------------------------------------
log "control-plane tooling"
helm_tgz="${ARTIFACT_DIR}/helm-${HELM_VERSION}-linux-amd64.tar.gz"
fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" "${helm_tgz}"
tar -xzf "${helm_tgz}" -C "${ARTIFACT_DIR}" --strip-components=1 linux-amd64/helm
mv -f "${ARTIFACT_DIR}/helm" "${ARTIFACT_DIR}/bin/helm"
chmod +x "${ARTIFACT_DIR}/bin/helm"

fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" "${ARTIFACT_DIR}/bin/kubectl"
fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" "${ARTIFACT_DIR}/kubectl.sha256"
echo "$(cat "${ARTIFACT_DIR}/kubectl.sha256")  ${ARTIFACT_DIR}/bin/kubectl" | sha256sum -c - >/dev/null \
  || die "kubectl checksum mismatch"
chmod +x "${ARTIFACT_DIR}/bin/kubectl"
ok "helm ${HELM_VERSION} + kubectl ${KUBECTL_VERSION}"

# ---------------------------------------------------------------------------
# 3. Harbor chart + the exact images that chart renders
# ---------------------------------------------------------------------------
log "Harbor chart ${HARBOR_CHART_VERSION}"
harbor_chart="${ARTIFACT_DIR}/harbor/harbor-${HARBOR_CHART_VERSION}.tgz"
fetch "https://helm.goharbor.io/harbor-${HARBOR_CHART_VERSION}.tgz" "${harbor_chart}"

# Render the chart with the same feature toggles the installer uses, so the image
# list is derived from the chart itself rather than hand-maintained here.
mapfile -t harbor_images < <(
  "${ARTIFACT_DIR}/bin/helm" template harbor "${harbor_chart}" \
      --namespace "${HARBOR_NAMESPACE}" \
      -f "${REPO_ROOT}/harbor/values-base.yaml" \
      --set "externalURL=http://127.0.0.1:${HARBOR_NODEPORT}" \
    | sed -nE 's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' \
    | sort -u
)
(( ${#harbor_images[@]} > 0 )) || die "helm template produced no images - chart or values-base.yaml changed?"
info "chart renders ${#harbor_images[@]} images:"
printf '      %s\n' "${harbor_images[@]}"

harbor_bundle="${AIRGAP_DIR}/harbor-images.${IMG_SUFFIX}"
if [[ -s "${harbor_bundle}" ]]; then
  dim "cached  $(basename "${harbor_bundle}")"
else
  for img in "${harbor_images[@]}"; do
    info "pull    ${img}"
    docker pull --platform "linux/${TARGET_ARCH}" -q "${img}" >/dev/null || die "docker pull failed: ${img}"
  done
  info "save    $(basename "${harbor_bundle}")"
  docker save "${harbor_images[@]}" | compress_stream "${harbor_bundle}.part"
  mv "${harbor_bundle}.part" "${harbor_bundle}"
fi
printf '%s\n' "${harbor_images[@]}" > "${ARTIFACT_DIR}/harbor/images.txt"
ok "Harbor images bundled ($(human_size "${harbor_bundle}"))"

# ---------------------------------------------------------------------------
# 3b. Longhorn: chart plus the images the release itself declares.
#
#     Not `helm template` this time. longhorn-manager launches the engine,
#     instance-manager and share-manager images at runtime rather than declaring
#     them in a manifest, so a rendered chart misses them and the cluster then
#     stalls on ImagePullBackOff with no registry to pull from. The release ships
#     deploy/longhorn-images.txt precisely for airgapped installs; use that.
# ---------------------------------------------------------------------------
log "Longhorn ${LONGHORN_VERSION} (chart ${LONGHORN_CHART_VERSION})"
longhorn_chart="${ARTIFACT_DIR}/longhorn/longhorn-${LONGHORN_CHART_VERSION}.tgz"
mkdir -p "${ARTIFACT_DIR}/longhorn"
fetch "https://github.com/longhorn/charts/releases/download/longhorn-${LONGHORN_CHART_VERSION}/longhorn-${LONGHORN_CHART_VERSION}.tgz" \
      "${longhorn_chart}"
fetch "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn-images.txt" \
      "${ARTIFACT_DIR}/longhorn/images.txt"

mapfile -t longhorn_images < <(grep -vE '^\s*(#|$)' "${ARTIFACT_DIR}/longhorn/images.txt" | tr -d '\r')
(( ${#longhorn_images[@]} > 0 )) || die "longhorn-images.txt for ${LONGHORN_VERSION} is empty"
info "release declares ${#longhorn_images[@]} images"

longhorn_bundle="${AIRGAP_DIR}/longhorn-images.${IMG_SUFFIX}"
if [[ -s "${longhorn_bundle}" ]]; then
  dim "cached  $(basename "${longhorn_bundle}")"
else
  for img in "${longhorn_images[@]}"; do
    info "pull    ${img}"
    docker pull --platform "linux/${TARGET_ARCH}" -q "${img}" >/dev/null || die "docker pull failed: ${img}"
  done
  info "save    $(basename "${longhorn_bundle}")"
  docker save "${longhorn_images[@]}" | compress_stream "${longhorn_bundle}.part"
  mv "${longhorn_bundle}.part" "${longhorn_bundle}"
fi
ok "Longhorn images bundled ($(human_size "${longhorn_bundle}"))"

# ---------------------------------------------------------------------------
# 3c. kube-vip, for the optional control-plane VIP.
#
#     The DaemonSet is generated by the pinned image itself rather than kept as
#     a hand-written copy, so the manifest can never drift from the version we
#     ship. The two site-specific literals are then turned into placeholders for
#     the installer to fill in, and the substitution is checked: if a future
#     kube-vip changes its output, this fails the build instead of quietly
#     producing a manifest with a placeholder left in it.
# ---------------------------------------------------------------------------
log "kube-vip ${KUBE_VIP_VERSION}"
kube_vip_ref="${KUBE_VIP_IMAGE}:${KUBE_VIP_VERSION}"
mkdir -p "${ARTIFACT_DIR}/kube-vip"

kube_vip_bundle="${AIRGAP_DIR}/kube-vip-images.${IMG_SUFFIX}"
if [[ -s "${kube_vip_bundle}" ]]; then
  dim "cached  $(basename "${kube_vip_bundle}")"
else
  info "pull    ${kube_vip_ref}"
  docker pull --platform "linux/${TARGET_ARCH}" -q "${kube_vip_ref}" >/dev/null \
    || die "docker pull failed: ${kube_vip_ref}"
  info "save    $(basename "${kube_vip_bundle}")"
  docker save "${kube_vip_ref}" | compress_stream "${kube_vip_bundle}.part"
  mv "${kube_vip_bundle}.part" "${kube_vip_bundle}"
fi

kube_vip_tmpl="${ARTIFACT_DIR}/kube-vip/kube-vip.yaml.tmpl"
# Outside the redirect below: fetch() logs to stdout, and inside the group that
# log line would be captured as the first line of the manifest.
fetch "https://kube-vip.io/manifests/rbac.yaml" "${ARTIFACT_DIR}/kube-vip/rbac.yaml"

info "generate $(basename "${kube_vip_tmpl}")"
{
  cat "${ARTIFACT_DIR}/kube-vip/rbac.yaml"
  echo "---"
  docker run --rm --network none --entrypoint /kube-vip "${kube_vip_ref}" \
    manifest daemonset \
      --interface PLACEHOLDERIFACE \
      --address 203.0.113.254 \
      --inCluster --taint --controlplane --arp --leaderElection
} > "${kube_vip_tmpl}.raw" 2>/dev/null || die "could not generate the kube-vip manifest"

sed -e 's|PLACEHOLDERIFACE|@@VIP_INTERFACE@@|g' \
    -e 's|203\.0\.113\.254|@@VIP_ADDRESS@@|g' \
    "${kube_vip_tmpl}.raw" > "${kube_vip_tmpl}"
rm -f "${kube_vip_tmpl}.raw"

for placeholder in '@@VIP_INTERFACE@@' '@@VIP_ADDRESS@@'; do
  count="$(grep -c -- "${placeholder}" "${kube_vip_tmpl}" || true)"
  (( count == 1 )) || die "expected exactly one ${placeholder} in the kube-vip manifest, found ${count}.
     kube-vip ${KUBE_VIP_VERSION} has probably changed its 'manifest daemonset' output."
done
grep -q "image: ${kube_vip_ref}" "${kube_vip_tmpl}" \
  || die "the generated kube-vip manifest does not reference ${kube_vip_ref}"
ok "kube-vip image bundled ($(human_size "${kube_vip_bundle}")) + manifest templated"

# ---------------------------------------------------------------------------
# 4. The demo workload image.
#    Deliberately NOT placed in the airgap dir: it must be pulled from Harbor so
#    the demo proves the private registry actually works end to end.
# ---------------------------------------------------------------------------
log "demo image ${DEMO_IMAGE_NAME}:${DEMO_IMAGE_TAG} (from ${NGINX_BASE_IMAGE})"
demo_tar="${ARTIFACT_DIR}/demo/${DEMO_IMAGE_NAME}.tar"
if [[ -s "${demo_tar}" ]]; then
  dim "cached  $(basename "${demo_tar}")"
else
  docker build --platform "linux/${TARGET_ARCH}" --pull \
    --build-arg "BASE_IMAGE=${NGINX_BASE_IMAGE}" \
    -t "${DEMO_IMAGE_NAME}:${DEMO_IMAGE_TAG}" \
    "${REPO_ROOT}/demo/nginx" >/dev/null || die "demo image build failed"
  docker save "${DEMO_IMAGE_NAME}:${DEMO_IMAGE_TAG}" -o "${demo_tar}.part"
  mv "${demo_tar}.part" "${demo_tar}"
fi
ok "demo image saved ($(human_size "${demo_tar}"))"

# ---------------------------------------------------------------------------
# 5. Offline .debs.
#    k3s-ansible's prereq role apt-installs policycoreutils on Ubuntu, and an
#    airgapped node has no apt mirror. Stage the packages per OS release.
# ---------------------------------------------------------------------------
log "offline OS packages: ${OFFLINE_DEB_PACKAGES}"
# shellcheck source=lib/stage-debs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage-debs.sh"
# shellcheck disable=SC2086  # OFFLINE_DEB_IMAGES is a deliberate word list
stage_debs "${ARTIFACT_DIR}" "${OFFLINE_DEB_PACKAGES}" ${OFFLINE_DEB_IMAGES} \
  || die "failed to stage the offline .debs"
ok "offline packages staged for: $(cd "${ARTIFACT_DIR}/debs" && echo */ | tr -d '/')"

# ---------------------------------------------------------------------------
# 6. Manifest
# ---------------------------------------------------------------------------
{
  echo "# hardened-airgapped-k3s artifact bundle"
  echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "k3s_version=${K3S_VERSION}"
  echo "target_arch=${TARGET_ARCH}"
  echo "helm_version=${HELM_VERSION}"
  echo "kubectl_version=${KUBECTL_VERSION}"
  echo "harbor_chart_version=${HARBOR_CHART_VERSION}"
  echo "longhorn_version=${LONGHORN_VERSION}"
  echo "longhorn_chart_version=${LONGHORN_CHART_VERSION}"
  echo "kube_vip_version=${KUBE_VIP_VERSION}"
  echo "demo_image=${DEMO_IMAGE_NAME}:${DEMO_IMAGE_TAG}"
  echo "nginx_base_image=${NGINX_BASE_IMAGE}"
} > "${ARTIFACT_DIR}/MANIFEST.txt"

(cd "${ARTIFACT_DIR}" && find . -type f ! -name SHA256SUMS ! -name '*.part' -print0 \
  | sort -z | xargs -0 sha256sum > SHA256SUMS)

log "done"
info "artifacts: ${ARTIFACT_DIR} ($(human_size "${ARTIFACT_DIR}"))"
info "next:      scripts/02-build-installer.sh"
