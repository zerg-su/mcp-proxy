# Usage

## CLI

```text
-config string         path to config file or a http(s) url (default "config.json")
-expand-env            expand environment variables in config file (default true)
-http-headers string   optional headers for config URL: 'Key1:Value1;Key2:Value2'
-http-timeout int      timeout (seconds) for remote config fetch (default 10)
-insecure              skip TLS verification for remote config
-authorize string      run a one-time interactive OAuth authorization for the
                        named mcpServers entry, then exit
-check-config          load and validate the config, then exit
-require-auth          refuse to start, or to report a config OK, when any
                        enabled server would be served with no authTokens
-require-tool-allowlist refuse to start, or to report a config OK, when any
                        enabled server exposes every tool its downstream offers
-stdio-clean-env       give stdio servers only the passthrough variables and
                        their own configured env, not this process's environment
-stdio-env-passthrough comma-separated variables copied to stdio children when
                        -stdio-clean-env is set (default "PATH,HOME")
-log-level value       log level: debug, info, warn, or error (default info)
-version               print version and exit
-help                  print help and exit
```

## Validating configuration

Use `-check-config` in CI, init containers, or deployment scripts to validate
the proxy settings and every downstream server without binding the HTTP port:

```bash
mcp-proxy -config config.json -check-config
# Config OK: 3 MCP server(s) configured
```

Validation includes transport requirements, absolute HTTP URLs, OAuth callback
safety, authentication tokens, and tool-filter modes. Invalid configuration
exits non-zero with the affected field or server name.

### Requiring authentication

Authentication is opt-in per route: a server with no `authTokens`, and none
inherited from `mcpProxy.options`, is served to anyone who can reach the
address. That is a valid local setup, so it is not an error — which also means
nothing tells you when a deployment ends up in that state.

`-require-auth` makes it an error. It rejects a config in which any enabled
server would be published without authentication, naming every one it finds,
and it applies to both `-check-config` and a real start:

```bash
mcp-proxy -config config.json -check-config -require-auth
# level=ERROR msg="Config rejected" err="-require-auth: 2 of 3 server(s) would
# be served without authentication: fetch, notes; give each one
# options.authTokens, or set mcpProxy.options.authTokens as the default they
# inherit"
# exit status 1
```

Tokens inherited from `mcpProxy.options.authTokens` count, so a fleet-wide
default declared once satisfies it. Servers with `"disabled": true` are ignored,
because they mount no route. Passing it to the running daemon as well as to the
validation step is the point: a config that loses its tokens later then fails to
start instead of coming back up open.

### Requiring a tool allow list

A downstream decides which tools it offers, and it can offer more of them after
any update. `-require-tool-allowlist` rejects a config in which any enabled
server would publish whatever its downstream happens to expose:

```bash
mcp-proxy -config config.json -check-config -require-tool-allowlist
# level=ERROR msg="Config rejected" err="-require-tool-allowlist: 1 of 3
# server(s) expose every tool their downstream offers, now and after any
# update: fetch; ..."
```

It requires, per server, `options.toolFilter` with `mode: "allow"` and a
non-empty `list`. Three configurations look like restrictions and are not, which
is why the check is that specific:

| Config | What it actually does |
|---|---|
| no `toolFilter` | every tool is exposed |
| `{"mode": "allow", "list": []}` | every tool is exposed (logged as a `WARN`) |
| `toolFilter` on `mcpProxy.options` only | every tool is exposed; it is not inherited |
| `{"mode": "block", "list": [...]}` | everything except the listed tools, including tools added later |

Both policy flags can be combined, and each failure is reported, so one run
lists everything that has to change:

```bash
mcp-proxy -config config.json -check-config -require-auth -require-tool-allowlist
```

### Isolating what stdio servers inherit

By default a stdio downstream is started with the proxy's entire environment
plus its own `env` entries. On a laptop that is convenient. On a CI runner the
environment is where the credentials are, so every third-party MCP server in the
config — including one whose job is to read somebody else's web page — can read
the cloud keys, the registry password and the deploy token.

`-stdio-clean-env` replaces that with an environment built from nothing:

```bash
mcp-proxy -config config.json -stdio-clean-env
# level=INFO msg="Stdio children start from a clean environment" passthrough="[PATH HOME]"
```

A child then sees exactly two things: the variables named by
`-stdio-env-passthrough` (default `PATH,HOME`, both needed for a child to find
and run anything, and for `npx`/`uvx` caches), and whatever that server declares
in its own `mcpServers.<name>.env`. Anything a downstream legitimately needs is
therefore declared per server, where it can be reviewed:

```json
"github": {
  "command": "npx",
  "args": ["-y", "@vendor/mcp-server@1.4.2"],
  "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN_FOR_MCP}"}
}
```

A variable set in a server's `env` overrides an inherited one of the same name.
Names in the passthrough list that are not set in the proxy's environment are
skipped rather than exported empty. Add to the list rather than replacing it —
`SSL_CERT_FILE` behind a TLS-inspecting proxy, `NO_PROXY`, `SystemRoot` on
Windows — since a child with no `PATH` cannot execute anything at all.

The flag applies on reconnect too: a downstream that is respawned after a crash
gets the same environment as the original.

## Endpoints

Given `mcpProxy.baseURL = https://mcp.example.com` and a server key `fetch`:

- For `type: sse`: `https://mcp.example.com/fetch/sse`
- For `type: streamable-http`: `https://mcp.example.com/fetch/mcp`

## Health checks

Two unauthenticated endpoints are always served for liveness/readiness probes
(Docker, reverse proxies, dashboards, monitoring):

- `/_healthz` (liveness) returns `200` as soon as the process serves requests. It
  is about this process only, so it stays `200` even when a downstream is down.
- `/_readyz` (readiness) returns `503` with `"status":"initializing"` until every
  enabled server has finished connecting and mounting its route, then `200`.
- `/_readyz` returns `503` again with `"status":"degraded"` if a downstream that
  had connected later stops answering: each connection is probed every 30s, and
  the servers that failed are listed in `unhealthy`. It takes three failed probes
  in a row, so a busy single-threaded server that misses one probe does not take
  the proxy out of rotation. Servers speaking the modern protocol (2026-07-28,
  which removed ping) are probed with a real `tools/list` request; legacy
  connections are still pinged.
- `/_readyz` returns `503` with `"status":"unavailable"` if no enabled server is
  mounted at all. Nothing can be named as broken in that case, but every MCP
  route would `404`.
- `GET` returns a JSON status document; `HEAD` returns the same code with an
  empty body. `serverCount` counts enabled servers only.

```bash
curl http://127.0.0.1:9090/_healthz
# {"name":"MCP Proxy","serverCount":3,"status":"ok","version":"1.0.0"}

curl http://127.0.0.1:9090/_readyz
# {"name":"MCP Proxy","serverCount":3,"status":"degraded","unhealthy":["notion"],"version":"1.0.0"}
```

A server that never connected at startup is *not* reported as unhealthy: it has
no route, and keeping the whole proxy out of rotation would take the working
servers down with it. Use `-doctor` or the startup logs to find those.

By default a server that is down at startup stays down until the proxy is
restarted, and a connection that drops stays `degraded`. Set `autoReconnect: true`
on a server (or in `mcpProxy.options` for all of them) to have it repair itself:
the proxy retries an unreachable backend every `reconnectInterval` (default `15s`)
and mounts its route once it connects, and it rebuilds a connection that drops.
This trades the external-restart contract for in-process recovery, which suits a
host where the proxy outlives the app it fronts (e.g. started at login).

The two cases use different timings. A backend that was never up is retried on
`reconnectInterval`. A connection that drops after being healthy is noticed by the
keepalive probe instead, so its recovery is governed by `pingInterval` and the
three-consecutive-failure threshold — about 90s with the defaults. Lower
`pingInterval` to detect and rebuild a drop sooner.

These endpoints never require the proxy auth token, which also means the
`unhealthy` list exposes your server names to anyone who can reach the port.
Bind the proxy to an internal address, or keep the health endpoints on an
internal route in your reverse proxy, if those names are sensitive.

## Auth

If `options.authTokens` is set for a server, requests must include the token in
the `Authorization` header. Both forms are accepted, and the scheme name is
case-insensitive:

```
Authorization: Bearer <token>
Authorization: <token>
```

If your client cannot set headers, embed the token in the route key (e.g. `fetch/<token>`) and call that path instead.

## OAuth-authorizing a downstream server

For servers configured with an `oauth` block (see [CONFIGURATION.md](CONFIGURATION.md#oauth)),
run the authorization flow once, by hand, before starting (or restarting)
the daemon:

```bash
mcp-proxy -authorize notion -config path/to/config.json
```

This opens your default browser to the provider's consent screen, waits
for the local redirect callback, exchanges the code for a token, and saves
it to disk. Run it interactively, in a session with a real browser -
never from an unattended service/container, since it requires you to log
in and approve access.

Once authorized, (re)start the daemon. A server's HTTP route is only
mounted on a successful connect at startup, so if the daemon was already
running when you authorized, restart it now - the new token won't be
picked up otherwise. After that, tokens refresh automatically as they
expire with no further restarts needed. Re-run `-authorize` only if the
server reports the token is no longer valid (e.g. access was revoked).
