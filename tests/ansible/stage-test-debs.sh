#!/usr/bin/env bash
#
# Stage the offline .debs for one OS release - all the integration tests need
# from the artifact bundle. About thirty seconds, versus two gigabytes for the
# full `make download`.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../config/versions.env
source config/versions.env
# shellcheck source=../../scripts/lib/stage-debs.sh
source scripts/lib/stage-debs.sh

mkdir -p artifacts/debs
stage_debs "${PWD}/artifacts" "${OFFLINE_DEB_PACKAGES}" "${1:-debian:13}"
echo "staged: $(cd artifacts/debs && echo */ | tr -d '/')"
