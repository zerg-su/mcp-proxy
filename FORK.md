# About this fork

A fork of [TBXark/mcp-proxy](https://github.com/TBXark/mcp-proxy) (MIT), kept
close to upstream on purpose. It exists so that a reviewed source tree can be
tied to the binary that actually runs, and so that a couple of small defects
could be fixed without waiting on upstream.

Every change here is a candidate for upstream. The delta is deliberately small,
because each commit is a permanent cost on every rebase onto a new upstream tag.

## What was reviewed, and how deeply

Upstream v0.58.0 was read before this fork was created:

| Component | Non-test lines | Depth |
|---|---|---|
| `mcp-proxy` itself | 2,265 | line by line |
| `go-sphere/confstore` | 699 | line by line |
| `mark3labs/mcp-go` | ~24,000 | targeted: telemetry, `init()`, hardcoded endpoints, subprocess environment handling |

Findings worth stating plainly: no telemetry, no phone-home, and no `init()`
function anywhere in those three modules — nothing runs before `main`. Every
hardcoded URL is `example.com`, a loopback address, or a documentation link in a
comment. OpenTelemetry lives in a separate nested module that this binary does
not depend on, so no exporter is linked in. The OAuth implementation enables
PKCE by default, validates `state` twice, restricts the redirect to a loopback
address with an explicit port, and stores tokens `0600` in a `0700` directory.
`govulncheck` reports no vulnerability reachable from this code.

## What the review does NOT cover

Read this part before treating the fork as an audited artifact.

- **The MCP servers this proxy spawns are out of scope.** They are third-party
  programs with their own dependency trees, and nothing here vouches for them.
  The proxy is a transport; auditing it says nothing about what it transports.
- **A stdio child inherits the whole environment of the proxy process.** That is
  upstream `mcp-go` behaviour (`cmd.Env = append(os.Environ(), ...)`) and it is
  a reasonable default for the usual one-user, few-servers deployment. It stops
  being reasonable when one proxy process holds credentials for many servers,
  because every child then sees all of them. If that is your topology, do not
  put secrets in the proxy's environment: render them into the config file
  instead and run with `-expand-env=false`.
- **`-expand-env` defaults to true, and the config can be an http(s) URL.** In
  combination these are an environment-exfiltration primitive: a fetched config
  is expanded against the proxy's environment, so a hostile config server can
  read `${ANY_VARIABLE}` back out through a header or URL it controls, and
  `-insecure` disables certificate verification on that fetch. The remote
  provider is not removed here — it is a deliberate upstream feature with real
  uses — so the mitigation is operational: pass a file path, never a URL.
- **Dependencies are pinned and vendored, not audited in full.** `vendor/` holds
  10 modules and roughly 56,000 lines. Two small ones with no visible community
  were read completely; the rest are trusted on publisher reputation.

## What this fork changes

- Dependencies are vendored, so the binary builds with no network at all
  (`GOFLAGS=-mod=vendor GOPROXY=off`).
- An empty `authTokens` array is rejected instead of silently disabling
  authentication on a route while reading as configured.
- Every build path is reproducible, and each guarantee has a gate that was
  demonstrated to fail when the thing it protects is removed: `make verify`
  covers the toolchain version, `-trimpath`, the goreleaser flag list, and
  byte-identical rebuilds. The release workflow runs it before publishing.
- Release tags use `v<upstream>-h<N>`, and the workflow triggers on nothing
  else, so upstream tags present in this fork cannot publish releases under its
  name.

## Non-goals, with reasons

- **No artifact signing or attestation.** Signing answers "was this artifact
  substituted in transit", for a consumer who cannot check any other way.
  Reproducible builds answer a stronger question — rebuild the tag and compare
  bytes — and registry access control covers publication. Signing would start to
  earn its keep when artifacts go to parties who can neither rebuild them nor
  trust the registry they came from.
- **No image publishing workflow.** Images are built and published from an
  operator's machine by `scripts/build-push.sh`, which takes the registry from
  the environment, refuses to publish from a dirty tree, and hands the version
  stamp to the build. Upstream's `docker.yml` was removed: it ran a third-party
  action pinned to a branch, which is arbitrary future code holding a token with
  write access to packages.

## Working with upstream

`master` tracks upstream untouched. Work lives on `hardening` as a series of
small commits rebased onto each new upstream tag, so `git log <tag>..hardening`
is always the exact delta and stays reviewable.

The Go module path is intentionally still `github.com/tbxark/mcp-proxy`: nothing
imports this as a library, and renaming it would conflict on every rebase.
