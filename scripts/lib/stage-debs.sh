# shellcheck shell=bash
#
# Download the .deb packages an airgapped node cannot fetch for itself.
#
# Extracted from 01-download-artifacts.sh so CI can stage a single release in
# about thirty seconds instead of downloading the whole two-gigabyte bundle to
# run a four-minute test.
#
# Each release is resolved inside a container of that exact release, so the
# dependency closure matches what the node will actually need.

# stage_debs <artifact_dir> <packages> <image>...
stage_debs() {
  local artifact_dir="$1" packages="$2"; shift 2
  local base release_id out

  for base in "$@"; do
    # shellcheck disable=SC2016  # evaluated inside the container, not here
    release_id="$(docker run --rm "${base}" sh -c '. /etc/os-release; echo "${ID}-${VERSION_ID}"')"
    out="${artifact_dir}/debs/${release_id}"

    if compgen -G "${out}/*.deb" >/dev/null; then
      printf '    cached  debs/%s\n' "${release_id}"
      continue
    fi

    mkdir -p "${out}"
    printf '    stage   debs/%s (%s)\n' "${release_id}" "${base}"
    docker run --rm -v "${out}:/out" "${base}" sh -euc "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --download-only --no-install-recommends ${packages}
        cp /var/cache/apt/archives/*.deb /out/
        chmod 0644 /out/*.deb
      " >/dev/null || return 1
  done
}
