# Working in this repository

A fork of `TBXark/mcp-proxy`, kept deliberately close to upstream. Read
[FORK.md](FORK.md) first — it states what the source review covered, what it did
not, and why each non-goal is a non-goal rather than an oversight.

## The one rule that matters most here

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

## Delta discipline

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

## Things that look wrong and are not

- **`--dirty` in the version stamp.** It was removed once, because
  `.dockerignore` strips tracked files so git inside the Docker builder reported
  every clean tree as dirty. That traded a noisy wrong stamp for a silent worse
  one: with `-buildvcs=false` there is no `vcs.modified` either, so a binary from
  a modified tree claimed to be the clean commit. Docker now receives the stamp
  from the host via `BUILD_VERSION`; do not make it derive its own.
- **The toolchain is verified, not pinned.** `GOTOOLCHAIN` with an uninstalled
  version fetches over the network, which breaks the vendored `GOPROXY=off`
  build — measured, not assumed: `toolchain not available`. `verify-toolchain`
  compares against `go.mod` instead. `ALLOW_TOOLCHAIN_DRIFT=1` is for local work
  only; CI takes its version from `go.mod` and must never need it.
- **No `go mod download` in the Dockerfile.** Dependencies are vendored, so that
  layer only fetched modules the compiler never reads, turning an offline build
  into a networked one.
- **The module path is still `github.com/tbxark/mcp-proxy`.** Nothing imports
  this as a library, and renaming it conflicts on every rebase.
- **`REGISTRY` has no default in `scripts/build-push.sh`.** This repository is
  public. A registry host here would advertise the account and naming scheme the
  images live under.

## Before proposing a change

    make verify        # toolchain, -trimpath, release flags, reproducibility
    go test ./...
    go vet ./...

`make verify` needs `ALLOW_TOOLCHAIN_DRIFT=1` unless your Go matches `go.mod`.

Keep this repository free of identifiers belonging to whoever operates it —
registry hosts, account numbers, internal service or team names. Operational
values come from the environment.

## Commit messages

Say why, not what; the diff already says what. When a claim is measurable, give
the measurement — "0 occurrences, against 128 without the flag" is worth more
than "keeps paths out of the binary". If a previous decision is being reversed,
say what was wrong with it, because the next person will otherwise reverse it
back.
