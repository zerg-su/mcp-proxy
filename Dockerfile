# The builder stays on the BUILD machine's own architecture and cross-compiles,
# instead of being emulated once per target. Go needs no cross toolchain here -
# CGO_ENABLED=0 in the Makefile - so the only thing a QEMU-emulated builder
# would add is minutes of compile time per platform.
#
# Every base is pinned by digest as well as by tag. A tag is a pointer its
# publisher can move: `golang:1.25.14` is stable by convention, `node:lts` and
# the uv image are not stable even in principle - they are meant to move. Two
# builds of one commit would then produce different images, which is exactly
# what the reproducibility gates exist to prevent, and they cannot see this
# because they compare two builds made minutes apart. The digest is of the
# manifest list, not of one platform's image, so the multi-architecture build
# still selects per target; all three were confirmed to carry linux/amd64 and
# linux/arm64 at pinning time.
#
# The tag is kept alongside the digest because the digest alone says nothing
# about what it is. scripts/refresh-base-digests.sh re-resolves the tags and
# rewrites these lines: a digest pin stops receiving base-image security
# updates, so it has to be cheap to refresh, or it rots.
FROM --platform=$BUILDPLATFORM golang:1.25.14@sha256:699337d620559a59b4a2bb298ad59611e535d2ee755a34cf2d2a98f37578dc80 AS builder
# The version stamp is computed on the host and passed in, never derived here:
# .dockerignore removes tracked files from the build context, so git inside this
# stage sees them as deleted and would report a clean tree as dirty.
ARG BUILD_VERSION=dev
# Set by buildx for each platform in the manifest list. go build reads GOOS and
# GOARCH from the environment, so the Makefile needs no knowledge of any of
# this and one recipe still serves the plain host build.
ARG TARGETOS
ARG TARGETARCH
WORKDIR /app
# No `go mod download` layer: the repository vendors its dependencies, so the
# compiler reads vendor/ and that download would fetch modules it never uses -
# turning an otherwise offline build into one that needs the network, which is
# exactly what vendoring was committed to avoid.
COPY . .
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} make build BUILD=$BUILD_VERSION

FROM node:lts-bookworm-slim@sha256:2fe369e969550cde8e867afc3fe370b260140cab4a23d467074295b42163d553 AS node

FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim@sha256:531f855bda2c73cd6ef67d56b733b357cea384185b3022bd09f05e002cd144ca

COPY --from=node /usr/local/bin/node /usr/local/bin/node
#COPY --from=node /usr/local/include/node /usr/local/include/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    ln -s /usr/local/bin/node /usr/local/bin/nodejs

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/build/mcp-proxy /main

# Everything above this line needs root; nothing below it does. The proxy binds
# :9090, reads a config and spawns downstream servers, and none of that needs
# uid 0 - while a stdio child inherits the identity of the process that spawned
# it, so running as root hands root inside this container to every third-party
# MCP server the config names. That is the same reasoning FORK.md already
# applies to the environment those children inherit.
#
# One home holds everything written at run time: the OAuth token store
# (os.UserConfigDir, so $HOME/.config/mcp-proxy, 0700 with 0600 tokens), npm and
# npx caches under $HOME/.npm, uv's under $HOME/.cache/uv. HOME is set as an
# explicit ENV because Docker does not derive it from the passwd entry - it
# stays "/" for a non-root USER, which is not writable, and a downstream server
# fetched by npx would fail at startup with an error that reads like a network
# problem rather than a permission one.
#
# The uid is fixed and high so that a volume written here keeps its ownership
# across rebuilds and cannot collide with a distribution's system accounts. A
# deployment that overrides the user (docker run --user, runAsUser) has to
# provide a writable HOME of its own; see docs/DEPLOYMENT.md.
RUN useradd --create-home --uid 10001 --user-group mcp
ENV HOME=/home/mcp
USER mcp:mcp

ENTRYPOINT ["/main"]
CMD ["--config", "/config/config.json"]
