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
- **A stdio child inherits the whole environment of the proxy process, unless
  you say otherwise.** That is upstream `mcp-go` behaviour
  (`cmd.Env = append(os.Environ(), ...)`) and it is a reasonable default for the
  usual one-user, few-servers deployment. It stops being reasonable when one
  proxy process holds credentials for many servers, because every child then
  sees all of them — and it stops being avoidable by care alone on a CI runner,
  where the environment is where the credentials are. `-stdio-clean-env` builds
  the child's environment instead of inheriting it: the variables named by
  `-stdio-env-passthrough` plus that server's own `env`, nothing else. It is off
  by default, because turning it on breaks any downstream that quietly relied on
  an inherited variable, and that is the operator's call to make. The older
  advice still applies underneath it: render secrets into the config file and
  run with `-expand-env=false`.
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
  authentication on a route while reading as configured. `-require-auth` covers
  the other half of the same failure — the key simply being absent — by refusing
  a config in which any enabled server would be published with no
  authentication. It is off by default, because an open route is a valid local
  setup; it exists so that a deployment can state that it is not one here.
- `-require-tool-allowlist` does the same for tool exposure. Upstream's filter
  semantics are kept exactly as they are — an empty `allow` list exposes
  everything, a proxy-level filter is not inherited, both deliberate, both
  verified against a running proxy — and this makes a config that relies on
  either fail instead of reading as a restriction it is not.
- Every build path is reproducible, and each guarantee has a gate that was
  demonstrated to fail when the thing it protects is removed: `make verify`
  covers the toolchain version, `-trimpath`, the goreleaser flag list, the
  Dockerfile's digest pins and non-root runtime, and byte-identical rebuilds.
  The release workflow runs it before publishing.
- `golang.org/x/text` is held at a fixed version rather than at whatever
  upstream's go.mod resolves to. The v1.1.0 review recorded GO-2026-5970 in
  v0.14.0 as unreachable and upstream's to bump; "unreachable" is a statement
  about today's call graph, and this repository vendors the code either way, so
  it is bumped here. Expect this to be one of the conflicts at the next rebase,
  resolved by taking whichever version is higher.
- The dependencies are gated too, not only the way they are compiled.
  `make verify-vendor` re-materialises `vendor/` and diffs it against what is
  committed — the only check here that notices a tampered dependency, since
  `go build` compiles one without complaint and `go mod verify` is vacuous in a
  vendored repository. `make verify-vuln` runs `govulncheck` under the toolchain
  `go.mod` pins rather than whichever Go is installed, because the scanning
  version is part of the answer. Both need the network and are therefore kept
  out of `verify`.
- The checks run on the commits, and before anything is published. Until
  `checks.yml` existed, the only workflow triggered on a release tag, so every
  check first ran after the decision to release had already been made — and the
  image, the artifact this fork mostly exists to produce, went through none of
  them.
- The runtime image pins every base by digest and does not run as root. Neither
  is visible to the other gates: reproducibility compares two builds made a
  second apart, which resolve a moving tag identically, and nothing else here
  ever runs the image. `scripts/refresh-base-digests.sh` keeps the pins from
  rotting.
- The image itself is scanned before it is published, and ships an SBOM.
  `scripts/scan-image.sh` fails the publish on a HIGH or CRITICAL finding that
  has a fix available, anywhere in the image — Debian, Node, npm's own bundled
  modules, Python, the Go binary. That is the half of the supply chain no Go
  tool sees: the first scan reported 21 fixable Debian findings and 4 in npm's
  bundled modules, and the image now has none of them — `apt-get upgrade` for
  the Debian side, a pinned npm 11.19.1 for the other. Nothing is excused:
  `.trivyignore.yaml` is empty, and carries the rules for the day something has
  to be.
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
- **No second source-dependency scanner** (osv-scanner, and similar). It looked
  worth adding until the image scan landed: trivy reads the compiled binary's
  module list and reports vulnerable dependencies whether or not anything calls
  them — it found x/text v0.14.0 in an image while govulncheck, correctly,
  reported nothing reachable. So the coverage a second scanner was wanted for
  already exists, from a tool that also covers everything govulncheck cannot
  see. A third database would mean a third failure mode for the same answer.
- **No image scan in CI, only on the publishing path.** A scan fails when
  someone else discloses a vulnerability, not when this repository changes, so a
  scan on every pull request would turn unrelated work red on a schedule nobody
  here controls. Blocking a *release* on the same finding is correct, because a
  release is when those bytes start being shipped. `scripts/scan-image.sh` runs
  on demand for everything in between.
- **The image still carries Node, npm, uv, Python and git.** A deployment whose
  downstreams are all remote HTTP needs none of them, and one that spawns two
  known stdio servers would be better served by an image with exactly those two
  installed at build time — which also lets the runtime keep `noexec`, see
  docs/DEPLOYMENT.md. Both are the right shape for a *deployment's* image, built
  from this one; stripping the general image here would break the case upstream
  supports, and guessing which downstreams a given deployment spawns is not
  something this repository can do.

## Working with upstream

`master` tracks upstream untouched. Work lives on `hardening` as a series of
small commits rebased onto each new upstream tag, so `git log <tag>..hardening`
is always the exact delta and stays reviewable.

The Go module path is intentionally still `github.com/tbxark/mcp-proxy`: nothing
imports this as a library, and renaming it would conflict on every rebase.

## Upstream bases

| Base | Rebased | Upstream delta from the previous base | Review depth of that delta |
|---|---|---|---|
| v0.58.0 | fork created | — | as described above |
| v1.1.0 | 2026-09-16 | 16 commits, 29 files, +3319/-343; `mcp-go` 0.58.0 → 1.1.0 (vendor +5432/-280, 44 files, all under `mcp-go`) | proxy delta (`client.go`, `http.go`, `config.go`, `oauth.go`, `oauth_store.go`, `doctor.go`, `main.go`) line by line; `mcp-go` targeted as for the original base: stdio transport (subprocess, environment, stderr) line by line, the new protocol-2026-07-28 files (`discover`, `mrtr`, `headers`, `streamable_http_modern`) by purpose and surface, greps for `init()`, telemetry, hardcoded endpoints and environment access over the whole delta; `govulncheck` clean for reachable code (GO-2026-5970 in `x/text` 0.14.0 is not reachable and is upstream's to bump) |

The v1.1.0 rebase resolved four conflicts, none in behaviour: the empty-`authTokens`
check now sits after upstream's new `reconnectInterval` validation; `Makefile`
keeps upstream's `MODULE` line above the reproducible stamp; the docs bullet was
appended; and upstream's new `CLAUDE.md` is kept verbatim with a pointer here,
which is why the fork rules moved into this file.

Deployment notes from the v1.1.0 review, none of them defects in the proxy:

- Stdio children still inherit the gateway's whole environment
  (`cmd.Env = append(os.Environ(), c.env...)` in `mcp-go`), unchanged since v0.58.0.
  A deployment that keeps secrets out of the gateway's own environment keeps
  them out of every child's.
- A stdio child's stderr is now drained and logged at `debug`. Anything a child
  prints - a traceback with a token in it, say - reaches the gateway log when it
  runs with `-log-level debug`. `info` and above discard it.
- The `mcp-go` client now probes `server/discover` before falling back to
  `initialize`, bounded at 5 s. A stdio server that ignores unknown methods
  instead of answering "method not found" delays its own mount by that much.
- `autoReconnect` (off by default) rebuilds a stdio child with the same command
  and environment; a wrapper in the command (uid drop, sandboxing) is re-applied
  on every respawn because it *is* the command.

## Working in this fork

A fork of `TBXark/mcp-proxy`, kept deliberately close to upstream. Read
[FORK.md](FORK.md) first — it states what the source review covered, what it did
not, and why each non-goal is a non-goal rather than an oversight.

### The one rule that matters most here

**A gate you add must be shown to fail when the defect it targets is present.**
Not reasoned about — executed. Construct the defect, run the check, watch it
fail, then put it back.

This is written first because it has been violated twice in this repo, both
times by someone who had just finished explaining why the gate was correct:

- `verify-reproducible` slept one second between two builds to make a wall-clock
  stamp differ. Make expands a whole recipe before running any of it, so the
  stamp was substituted into both builds identically and the gate passed against
  the exact defect it existed to catch.
- `verify-release-flags` grepped `.goreleaser.yaml` for `-trimpath` and passed
  while `-trimpath` was removed, because the word still appeared in a comment
  two lines above the flag list.

Both looked obviously correct. Neither was. Assume yours is in the same category
until you have watched it fail.

### Delta discipline

`master` tracks upstream untouched. Work lives on `hardening` as small commits
rebased onto each new upstream tag, so `git log <tag>..hardening` is always the
exact reviewable delta.

Every commit here is paid for again at every rebase. Before adding one, ask
whether the problem is upstream's or ours — three candidate patches were dropped
during the original review precisely because the answer was "ours", and the fix
belonged in our deployment rather than in this code. New *files* are cheap
(they cannot conflict); edits to files upstream actively develops are not.

Prefer changes that are upstreamable as-is. Two commits here are meant to become
upstream pull requests.

### Things that look wrong and are not

- **`--dirty` in the version stamp.** It was removed once, because
  `.dockerignore` strips tracked files so git inside the Docker builder reported
  every clean tree as dirty. That traded a noisy wrong stamp for a silent worse
  one: with `-buildvcs=false` there is no `vcs.modified` either, so a binary from
  a modified tree claimed to be the clean commit. Docker now receives the stamp
  from the host via `BUILD_VERSION`; do not make it derive its own.
- **The toolchain is verified, not pinned by `GOTOOLCHAIN`.** Setting
  `GOTOOLCHAIN` to an uninstalled version fetches over the network, which breaks
  the vendored `GOPROXY=off` build — measured, not assumed: `toolchain not
  available`. `verify-toolchain` compares against `go.mod` instead.
  `ALLOW_TOOLCHAIN_DRIFT=1` is for local work only; CI takes its version from
  `go.mod` and must never need it. Note what the `go` directive does on its own:
  it names a full patch version, so a machine with an older Go downloads that
  toolchain once and every later command reports it — which is why local builds
  match CI exactly and `ALLOW_TOOLCHAIN_DRIFT` is normally not needed at all.
  The first such command needs the network; after it, the toolchain is in the
  module cache and the offline build works as before. `make verify-vuln` sets
  `GOTOOLCHAIN` deliberately, for a different reason: see the Makefile.
- **`apt-get upgrade` in an image whose bases are pinned by digest.** These look
  contradictory and are not. The digests pin which Debian the image starts from,
  so two builds of one commit start identically; they cannot pin what Debian has
  since fixed inside it, and the scan measured what that costs — 21 fixable
  HIGH/CRITICAL findings, in openssl, gnutls, pcre2 and libcap. The layer is
  therefore current rather than frozen, which was already true of the
  `apt-get install` next to it, since package versions were never pinned. The
  price is about 13 MB compressed and a layer that differs between builds months
  apart.
- **No `go mod download` in the Dockerfile.** Dependencies are vendored, so that
  layer only fetched modules the compiler never reads, turning an offline build
  into a networked one.
- **The module path is still `github.com/tbxark/mcp-proxy`.** Nothing imports
  this as a library, and renaming it conflicts on every rebase.
- **`REGISTRY` has no default in `scripts/build-push.sh`.** This repository is
  public. A registry host here would advertise the account and naming scheme the
  images live under.
- **The builder stage is pinned to `$BUILDPLATFORM` while the runtime stage is
  not.** The image is published as a two-platform manifest list, and an
  unpinned builder would be emulated under QEMU once per target to compile Go
  that cross-compiles for free. The runtime stage must stay per-target: it
  carries node, uv and the binary itself.

### Before proposing a change

    make verify               # toolchain, -trimpath, release flags, Dockerfile, reproducibility
    go test ./...
    go vet ./...
    make verify-supply-chain  # vendor/ against go.sum, govulncheck; needs the network

`make verify` needs `ALLOW_TOOLCHAIN_DRIFT=1` only if your Go somehow does not
match `go.mod` — normally it does, because the `go` directive names a full patch
version and the `go` command switches to it by itself (downloading it once).
`make verify-supply-chain` does not care either way: it pins the toolchain
itself, for both halves. It does need `govulncheck` installed, and a clean `vendor/`, `go.mod`
and `go.sum` — it cannot tell your uncommitted edit from a tampered dependency,
and says so rather than guessing.

CI runs all four on every push to `master` and `hardening*`, on pull requests,
and again before a release publishes anything.

Keep this repository free of identifiers belonging to whoever operates it —
registry hosts, account numbers, internal service or team names. Operational
values come from the environment.

### Commit messages

Say why, not what; the diff already says what. When a claim is measurable, give
the measurement — "0 occurrences, against 128 without the flag" is worth more
than "keeps paths out of the binary". If a previous decision is being reversed,
say what was wrong with it, because the next person will otherwise reverse it
back.
