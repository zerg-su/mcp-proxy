#!/usr/bin/env bash
# Check that every flag .goreleaser.yaml passes to cosign is a flag this cosign
# still accepts.
#
#   scripts/verify-sign-flags.sh
#
# This exists because v1.1.0-h3 spent a release number on the one defect none of
# the other gates can see. `make verify` checks what this repository says about
# itself; the signing step is a contract with an external binary, and that
# binary changed its mind: cosign 3.x defaults to --new-bundle-format, under
# which --output-signature and --output-certificate are *ignored* rather than
# rejected. So the config stayed valid YAML, goreleaser stayed happy, every gate
# stayed green, and the failure arrived after six archives and six SBOMs had
# been built, at the last step before publication, on a tag that cannot be
# reused. A deprecated flag that still parses is invisible to everything except
# the run that needs it.
#
# The check is deliberately narrow: flags only, from the `signs:` block only,
# against `cosign sign-blob --help`. It cannot tell that a flag is ignored - if
# cosign had removed the flags outright this would have caught h3 outright, and
# as it is it catches the next one, since cosign drops deprecated flags
# eventually. What it does catch today is the reverse mistake: writing a flag
# that this cosign has never heard of.
#
# Comment lines are excluded on purpose. FORK.md records the same trap twice:
# verify-release-flags once passed while -trimpath was absent, because the word
# still appeared in a comment two lines above the setting. The block comment
# here names --output-signature while explaining why it is gone, so a naive grep
# over the file would fail against the very config it is meant to bless.
#
# Requires: cosign. Skips, loudly, without it - it is a conformance check
# against an installed tool, and a machine with no cosign has nothing to
# conform to.
set -euo pipefail

CONFIG="${1:-.goreleaser.yaml}"

if ! command -v cosign >/dev/null 2>&1; then
    echo "cosign not found: skipping the sign-flag conformance check"
    echo "(CI installs it; locally, brew install cosign)"
    exit 0
fi

if [ ! -r "${CONFIG}" ]; then
    echo "${CONFIG} is missing or unreadable" >&2
    exit 1
fi

# Only YAML list items inside signs:, never comments. The block runs from
# `signs:` to the next key at column 0.
FLAGS="$(awk '
    /^signs:/                 { in_signs = 1; next }
    in_signs && /^[a-zA-Z]/   { in_signs = 0 }
    in_signs && /^[[:space:]]*#/ { next }
    in_signs && /^[[:space:]]*-[[:space:]]/ { print }
' "${CONFIG}" \
    | sed -E "s/^[[:space:]]*-[[:space:]]*//; s/^['\"]//; s/['\"]$//" \
    | grep -E '^--' \
    | sed -E 's/=.*$//' \
    | sort -u)"

if [ -z "${FLAGS}" ]; then
    echo "no flags found in the signs: block of ${CONFIG}" >&2
    echo "either the block is gone or its shape changed; this gate is now blind" >&2
    exit 1
fi

HELP="$(cosign sign-blob --help 2>&1)"
COSIGN_VERSION="$(cosign version 2>/dev/null | awk -F': *' '/GitVersion/{print $2; exit}')"

unknown=""
for flag in ${FLAGS}; do
    # The help lists flags as "--bundle=''" or "-y, --yes=false", so match the
    # flag followed by a word boundary rather than the whole line.
    if ! printf '%s\n' "${HELP}" | grep -qE -- "(^|[[:space:],])${flag}([=[:space:]]|$)"; then
        unknown="${unknown} ${flag}"
    fi
done

if [ -n "${unknown}" ]; then
    echo "cosign ${COSIGN_VERSION:-(unknown version)} does not accept:${unknown}"
    echo "these are passed by the signs: block in ${CONFIG}, and the release will"
    echo "fail at the signing step - after every archive and SBOM has been built."
    echo "check: cosign sign-blob --help"
    exit 1
fi

echo "cosign ${COSIGN_VERSION:-(unknown version)} accepts every flag in signs:" $(echo ${FLAGS})
