# Deployment

## Docker

Run with a local config file mounted into the container:

```bash
docker run -d \
  -p 9090:9090 \
  -v /path/to/config.json:/config/config.json \
  ghcr.io/tbxark/mcp-proxy:latest
```

Or reference a remote config URL:

```bash
docker run -d -p 9090:9090 \
  ghcr.io/tbxark/mcp-proxy:latest \
  --config https://example.com/config.json
```

The image supports launching MCP servers via `npx` and `uvx` out of the box.

## Docker Compose

Minimal compose file:

```yaml
services:
  app:
    image: ghcr.io/tbxark/mcp-proxy:latest
    pull_policy: always
    volumes:
      - ./config.json:/config/config.json
    ports:
      - "9090:9090"
    restart: always
```

Serving the config via an internal file server (no host mount into `app`):

```yaml
services:
  caddy:
    image: caddy:latest
    pull_policy: always
    expose:
      - "80"
    volumes:
      - ./config.json:/config/config.json
    command: ["caddy", "file-server", "--root", "/config"]

  app:
    image: ghcr.io/tbxark/mcp-proxy:latest
    pull_policy: always
    ports:
      - "9090:9090"
    restart: always
    depends_on:
      - caddy
    command: ["--config", "http://caddy/config.json"]
```

## Security Notes

- Prefer `authTokens` per downstream server; only use the `mcpProxy` default when appropriate.
- If a downstream server cannot set headers, you can embed a token in the route key (e.g. `fetch/<token>`) and route via that path.
- Set `options.panicIfInvalid: true` for critical servers to fail fast on misconfiguration.

## Running it hardened

Everything below was measured against the image this repository builds, not
inferred from what usually works. The proxy already runs as a non-root user
(uid 10001) with `HOME=/home/mcp`; the rest is what the container runtime has to
be told.

```bash
docker run -d \
  -p 9090:9090 \
  -v /path/to/config.json:/config/config.json:ro \
  --read-only \
  --tmpfs /home/mcp:uid=10001,gid=10001,mode=0700,exec \
  --tmpfs /tmp:uid=10001,gid=10001,mode=1777,exec \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  <your-registry>/mcp-proxy:<tag>
```

- **`exec` on the tmpfs is not optional if any downstream server is fetched at
  run time.** Docker mounts `--tmpfs` `noexec` by default, `npx` and `uvx` write
  executables under `$HOME` and then run them, and the result is a proxy that
  starts, reports `"status":"unavailable"`, and logs only `transport error:
  transport closed`. The actual cause — `Permission denied (os error 13)` from
  the child — is visible only at `-log-level debug`, where a stdio child's
  stderr is drained. Installing the downstream servers into the image at build
  time is the way to keep `noexec`.
- **`--read-only` needs a writable `$HOME`**, which is what the tmpfs above is
  for: the OAuth token store lives in `$HOME/.config/mcp-proxy`, and npm and uv
  keep their caches under `$HOME`. If OAuth tokens have to survive a restart,
  mount a volume there instead of a tmpfs.
- **Overriding the user means providing a home.** `docker run --user`, or
  `runAsUser` in Kubernetes, leaves `HOME=/home/mcp` pointing at a directory
  that uid no longer owns. Set `HOME` to something writable when you override
  the uid.
- The proxy binds 9090, so it needs no capabilities at all, and it never
  escalates, so `no-new-privileges` costs nothing.

## What the proxy cannot enforce for you

The proxy is a transport. These are properties of the config it is handed, and
FORK.md's "what the review does not cover" applies to all of them: the servers
this thing spawns are third-party programs with their own dependency trees.

- **Pin the downstream servers.** `"args": ["-y", "@vendor/mcp-server"]`
  resolves at every container start, so the code that runs inside the container
  changes without anything here changing. Write
  `"args": ["-y", "@vendor/mcp-server@1.4.2"]`, and the same for `uvx`
  (`mcp-server-fetch@2026.8.18`). Pinning the image while leaving these floating
  pins the wrapper and not the payload. Installing the servers into an image at
  build time is stronger still, and lets the runtime keep `noexec`.
- **Prefer `toolFilter` in `allow` mode.** In `block` mode, a tool added by a
  downstream update is exposed the moment it appears; in `allow` mode it is not
  exposed until someone adds it to the list. The filter applies to tools only —
  resources and prompts are always exposed.
- **Keep credentials out of the config file.** The examples put tokens in `env`
  and `url` because they have to show something. Render them from your secret
  store at deploy time and mount the result read-only. Note also that a stdio
  child inherits the proxy's entire environment (upstream `mcp-go` behaviour),
  so putting secrets in the proxy's own environment hands all of them to every
  downstream server it spawns; with `-expand-env=false` and a rendered file,
  neither happens. Use a separate, least-privileged credential per downstream.
- **Do not mix trust levels in one proxy.** One proxy aggregates every
  configured server's tools into a single surface, and a downstream that reads
  attacker-influenced content can return text that a model will act on. A server
  that reads public content and a server that can deploy, write or administer
  something belong in separate instances, with separate tokens and separate
  network egress — not in two entries of one config.
- **Require authentication explicitly.** A server with no `authTokens`, and none
  inherited, is published without any. Run with `-require-auth` (see
  [USAGE.md](USAGE.md)) in the deployment and in whatever validates the config,
  so that state is rejected rather than merely visible in a diff.

