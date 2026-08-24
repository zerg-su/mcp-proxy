#!/usr/bin/env bash
# Build the mcp-proxy image locally and publish it to a container registry.
#
# Runs on the OPERATOR'S MACHINE, not in CI. AWS credentials stay where they
# already are; whatever pulls this image does so through its own path and never
# needs credentials of its own.
#
#   REGISTRY=<account>.dkr.ecr.<region>.amazonaws.com scripts/build-push.sh
#   scripts/build-push.sh --build-only   # build locally, publish nothing
#
# REGISTRY has no default on purpose: this repository is a public fork, and a
# registry host baked in here would publish which account and naming scheme the
# images live under. Set it in your environment or a private wrapper.
#
# Requires: docker with buildx, aws cli with credentials for the registry
# account, and a clean working tree when publishing (the tag is the source).
set -euo pipefail

REPOSITORY="${REPOSITORY:-tools/mcp-proxy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
PLATFORM="${PLATFORM:-linux/amd64}"

BUILD_ONLY=0
[ "${1:-}" = "--build-only" ] && BUILD_ONLY=1

if [ "${BUILD_ONLY}" -eq 0 ] && [ -z "${REGISTRY:-}" ]; then
    echo "REGISTRY is not set; refusing to guess where to publish" >&2
    echo "  REGISTRY=<account>.dkr.ecr.<region>.amazonaws.com $0" >&2
    exit 1
fi
REGISTRY="${REGISTRY:-local}"

cd "$(git rev-parse --show-toplevel)"

# The tag IS the identity of the source tree. A dirty tree would produce an
# image whose tag points at a commit it was not built from, and registry tags
# are immutable, so that mistake would be permanent - hence the hard refusal
# when publishing.
#
# For --build-only the tag never leaves this machine, so a dirty tree is allowed
# and git describe marks it. Marking rather than allowing silently: a local
# image that looks exactly like a published one is how the wrong thing gets
# deployed later.
DIRTY=""
if [ -n "$(git status --porcelain)" ]; then
    if [ "${BUILD_ONLY}" -eq 0 ]; then
        echo "refusing to publish from a dirty working tree: the tag would not match the source" >&2
        git status --short >&2
        exit 1
    fi
    # Marked here rather than left to `git describe --dirty`, which only notices
    # modifications to tracked files. An untracked file changes what the image
    # contains just as much, and a local image that looks exactly like a
    # published one is how the wrong thing gets deployed later.
    DIRTY="-dirty"
    echo "==> dirty tree: building a local-only image tagged ${DIRTY#-}" >&2
fi

# One value serves as the image tag and as the version compiled into the binary,
# so `docker inspect` and `mcp-proxy -version` cannot disagree about which
# source produced the artifact.
IMAGE_TAG="${IMAGE_TAG:-$(git describe --tags --always)${DIRTY}}"
IMAGE="${REGISTRY}/${REPOSITORY}:${IMAGE_TAG}"

echo "==> ${IMAGE} (${PLATFORM})"

if [ "${BUILD_ONLY}" -eq 0 ]; then
    # Tags are immutable, so re-publishing an existing tag fails. Only a
    # confirmed ImageNotFoundException means "not built yet"; any other describe
    # failure (auth, throttling, network) must stop the script rather than be
    # read as absence.
    set +e
    DESCRIBE_OUT="$(aws ecr describe-images --region "${AWS_REGION}" \
        --repository-name "${REPOSITORY}" \
        --image-ids "imageTag=${IMAGE_TAG}" 2>&1)"
    DESCRIBE_RC=$?
    set -e
    if [ "${DESCRIBE_RC}" -eq 0 ]; then
        echo "==> already in the registry, nothing to do"
        exit 0
    elif ! grep -q "ImageNotFoundException" <<< "${DESCRIBE_OUT}"; then
        echo "ecr describe-images failed and it was not ImageNotFound:" >&2
        echo "${DESCRIBE_OUT}" >&2
        exit 1
    fi

    aws ecr get-login-password --region "${AWS_REGION}" \
        | docker login --username AWS --password-stdin "${REGISTRY}"
fi

# BUILD_VERSION is handed to the build rather than derived inside it. The
# Dockerfile cannot compute it: .dockerignore strips tracked files (docs,
# .github, README.md, .gitattributes, config.json, docker-compose.yaml) from the
# context, so git in the builder sees them as deleted and would report every
# clean tree as dirty. See the BUILD comment in the Makefile.
#
# Platform is explicit: a silently arm64 image built on an Apple laptop would
# fail on an x86_64 host at run time instead of here at build time.
BUILD_ARGS=(
    buildx build
    --platform "${PLATFORM}"
    --build-arg "BUILD_VERSION=${IMAGE_TAG}"
    --tag "${IMAGE}"
    --file Dockerfile
    .
)
if [ "${BUILD_ONLY}" -eq 1 ]; then
    BUILD_ARGS+=(--load)
else
    BUILD_ARGS+=(--push)
fi

docker "${BUILD_ARGS[@]}"

echo "==> done: ${IMAGE}"
echo "    the binary inside reports this same string as its -version"
