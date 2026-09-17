#!/usr/bin/env bash
# Scan a built image for known vulnerabilities and write its SBOM.
#
#   scripts/scan-image.sh <image>                 # scan, then write build/sbom/
#   scripts/scan-image.sh <image> --sbom-only     # SBOM without the gate
#
# This is the half of the supply chain that `govulncheck` cannot see. That
# covers the Go code and the standard library it is compiled against - which is
# the whole binary, since it is statically linked - and nothing else in the
# image: Debian, Node, npm's own bundled dependencies, Python, uv, git.
# Measured, not assumed: the first scan of this image reported 21 fixable
# HIGH/CRITICAL Debian findings and 4 in npm's bundled modules, none of which
# any Go tool had ever mentioned.
#
# The gate is "HIGH or CRITICAL, and a fixed version exists". Findings with no
# available fix are excluded on purpose: a gate that fails on something nobody
# can act on is a gate that gets switched off, and the pinned bases mean
# exposure does not drift between refreshes anyway. Specific accepted findings
# live in .trivyignore.yaml with a reason and an expiry date, so an exception
# has to be re-argued rather than forgotten.
#
# Trivy runs from a digest-pinned image and reads the image through a tar
# export, so nothing here needs the docker socket inside a container.
#
# Requires: docker, and network for the vulnerability database.
set -euo pipefail

TRIVY="aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969"

IMAGE="${1:-}"
MODE="${2:-}"
if [ -z "${IMAGE}" ]; then
    echo "usage: ${0##*/} <image> [--sbom-only]" >&2
    exit 1
fi

cd "$(git rev-parse --show-toplevel)"

SBOM_DIR="build/sbom"
# One file per image tag, named after it: the point of an SBOM is to answer
# "which builds contain this package" months later, and a file called sbom.json
# answers nothing.
SBOM_NAME="$(echo "${IMAGE}" | tr '/:' '__').cyclonedx.json"
mkdir -p "${SBOM_DIR}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
TAR="${WORK}/image.tar"

echo "==> exporting ${IMAGE}"
docker save -o "${TAR}" "${IMAGE}"

# A named cache volume, so a scan does not re-download the vulnerability
# database every time. It is data, not trust: the database is fetched over the
# network by trivy itself either way.
run_trivy() {
    docker run --name "trivy-$$-${RANDOM}" \
        -v "${WORK}:/work" \
        -v trivy-cache:/root/.cache/trivy \
        -v "${PWD}:/repo:ro" \
        "${TRIVY}" "$@"
}

echo "==> SBOM"
run_trivy image --input /work/image.tar --format cyclonedx --output /work/sbom.json --quiet
cp "${WORK}/sbom.json" "${SBOM_DIR}/${SBOM_NAME}"
echo "    ${SBOM_DIR}/${SBOM_NAME}"

if [ "${MODE}" = "--sbom-only" ]; then
    exit 0
fi

# An exception that is no longer needed is worse than no exception: it stays in
# the file, keeps looking deliberate, and silently covers the day the same CVE
# arrives somewhere else. Trivy does not report unused ignore rules, so the scan
# is run once more without the ignore file and the two id sets are compared.
# This reports; it does not fail. A stale entry is cleanup, not a vulnerability -
# what forces the entries to be revisited is the expiry date inside them, which
# trivy does enforce.
echo "==> exceptions"
run_trivy image --input /work/image.tar \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --scanners vuln \
    --format json --output /work/unfiltered.json --quiet
PRESENT="$(grep -oE '"VulnerabilityID": *"[^"]+"' "${WORK}/unfiltered.json" | cut -d'"' -f4 | sort -u || true)"
# The ignore file is this repository's own, so its shape is known; parsing it
# with grep avoids making a YAML library a prerequisite for scanning an image.
while read -r id; do
    [ -n "${id}" ] || continue
    if printf '%s\n' "${PRESENT}" | grep -qx "${id}"; then
        echo "    still needed: ${id}"
    else
        echo "    STALE: ${id} is accepted in .trivyignore.yaml but no longer found - delete the entry"
    fi
done <<< "$(grep -oE '^  - id: *[A-Za-z0-9.-]+' .trivyignore.yaml | awk '{print $3}')"

echo "==> scan (HIGH,CRITICAL, fixed only)"
# --exit-code 1 is what makes this a gate rather than a report. Without it
# trivy prints findings and exits 0, which is the failure mode where everyone
# believes the pipeline is checking something.
run_trivy image --input /work/image.tar \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --scanners vuln \
    --ignorefile /repo/.trivyignore.yaml \
    --exit-code 1
echo "==> no unaccepted HIGH or CRITICAL findings with a fix available"
