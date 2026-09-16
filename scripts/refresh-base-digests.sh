#!/usr/bin/env bash
# Re-resolve the base image tags in the Dockerfile and rewrite their digests.
#
#   scripts/refresh-base-digests.sh            # rewrite the Dockerfile in place
#   scripts/refresh-base-digests.sh --check     # report drift, change nothing
#
# A digest pin freezes the base images, which is the point - two builds of one
# commit produce one image - and also its cost: the Debian packages inside
# node and uv stop receiving security updates the moment they are pinned. That
# cost is only acceptable if refreshing is a single command, so this is that
# command. Run it, read the diff, rebuild, commit the new digests as their own
# change with the reason in the message.
#
# --check is what CI would run to notice the pins going stale. It is not wired
# into a workflow: a job that fails whenever a base image is republished fails
# on someone else's schedule, and the repository's own gates would then be red
# for reasons no commit here caused.
#
# Requires: docker with buildx. Reads registries, writes nothing to them.
set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

cd "$(git rev-parse --show-toplevel)"
DOCKERFILE=Dockerfile

# Only FROM lines, and only ones that are already pinned: an unpinned base is a
# separate problem, and silently pinning it here would hide it from the gate
# that exists to catch it (make verify-dockerfile).
refs=$(grep -oE '[a-zA-Z0-9./_-]+:[a-zA-Z0-9._-]+@sha256:[a-f0-9]{64}' "$DOCKERFILE" || true)
if [ -z "${refs}" ]; then
    echo "no digest-pinned FROM lines found in ${DOCKERFILE}" >&2
    exit 1
fi

drift=0
for ref in ${refs}; do
    tagged="${ref%@*}"
    old="${ref#*@}"

    # The manifest list digest, not one platform's image digest. The image is
    # published for two architectures, and pinning a single platform's digest
    # would build both of them from one architecture's base - which fails in a
    # way that looks like a broken program rather than a broken pin.
    new=$(docker buildx imagetools inspect "${tagged}" --format '{{.Manifest.Digest}}')
    if [ -z "${new}" ]; then
        echo "could not resolve ${tagged}" >&2
        exit 1
    fi

    # Both architectures have to still be there. A base that quietly drops one
    # would otherwise be pinned here and only fail at the next release build.
    #
    # grep -c, not grep -q, and the listing captured once rather than piped per
    # platform: -q exits at the first match, docker takes SIGPIPE, and under
    # `set -o pipefail` that failed pipeline reads as "platform missing". The
    # first version of this script rejected golang:1.25.14 for having no
    # linux/amd64 manifest while the same command printed one.
    manifests=$(docker buildx imagetools inspect "${tagged}@${new}")
    for platform in linux/amd64 linux/arm64; do
        found=$(printf '%s\n' "${manifests}" \
            | grep -cE "Platform:[[:space:]]+${platform}(/v[0-9]+)?$" || true)
        if [ "${found}" -eq 0 ]; then
            echo "${tagged}@${new} has no ${platform} manifest; refusing to pin it" >&2
            exit 1
        fi
    done

    if [ "${old}" = "${new}" ]; then
        echo "  unchanged  ${tagged}"
        continue
    fi

    drift=1
    echo "  MOVED      ${tagged}"
    echo "             ${old}"
    echo "          -> ${new}"
    if [ "${CHECK_ONLY}" -eq 0 ]; then
        # The whole ref is replaced rather than the digest alone, so a digest
        # that appears twice for different tags cannot be crossed over.
        tmp=$(mktemp)
        sed "s|${tagged}@${old}|${tagged}@${new}|g" "$DOCKERFILE" > "$tmp"
        mv "$tmp" "$DOCKERFILE"
    fi
done

if [ "${CHECK_ONLY}" -eq 1 ] && [ "${drift}" -eq 1 ]; then
    echo "base image tags have moved; run ${0##*/} without --check to update" >&2
    exit 1
fi

if [ "${drift}" -eq 0 ]; then
    echo "==> every pin still matches its tag"
else
    echo "==> ${DOCKERFILE} updated; rebuild and test before committing"
fi
