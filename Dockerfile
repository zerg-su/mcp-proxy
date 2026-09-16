# The builder stays on the BUILD machine's own architecture and cross-compiles,
# instead of being emulated once per target. Go needs no cross toolchain here -
# CGO_ENABLED=0 in the Makefile - so the only thing a QEMU-emulated builder
# would add is minutes of compile time per platform.
FROM --platform=$BUILDPLATFORM golang:1.25.14 AS builder
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

FROM node:lts-bookworm-slim AS node

FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim

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
ENTRYPOINT ["/main"]
CMD ["--config", "/config/config.json"]
