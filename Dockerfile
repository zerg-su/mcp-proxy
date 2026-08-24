FROM golang:1.25.5 AS builder
# The version stamp is computed on the host and passed in, never derived here:
# .dockerignore removes tracked files from the build context, so git inside this
# stage sees them as deleted and would report a clean tree as dirty.
ARG BUILD_VERSION=dev
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN make build BUILD=$BUILD_VERSION

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
