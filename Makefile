BUILD_DIR=./build
MODULE := github.com/tbxark/mcp-proxy
# One commit must always produce one binary, so the stamp is derived from the
# revision instead of the wall clock. --dirty stays: with -buildvcs=false there
# is no vcs.modified either, so a binary built from a modified tree would carry
# no trace of it at all and would claim to be the clean commit - incident triage
# would then audit the wrong source with nothing in the artifact to contradict
# it. The Docker build must not compute this itself: .dockerignore removes
# tracked files (docs, .github, README.md, .gitattributes, config.json,
# docker-compose.yaml) from the context, so git inside the builder sees them as
# deleted and would mark every clean-tree image dirty. It receives the stamp
# from the host instead, see buildImage. The fallback matters for a context with
# no usable .git at all, where an empty stamp would compile in an empty
# -X main.BuildVersion.
BUILD=$(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
CURRENT_OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
CURRENT_ARCH := $(shell uname -m | tr '[:upper:]' '[:lower:]')
SHA256=$(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo shasum -a 256)
# The toolchain is a build input: two Go versions produce different bytes from
# identical source. It is verified rather than pinned, because GOTOOLCHAIN with
# an uninstalled version fetches over the network, which breaks the vendored
# GOPROXY=off build this repository depends on (measured: "toolchain not
# available"). So the expected version is read from go.mod and compared.
GO_VERSION_EXPECTED=go$(shell awk '/^go /{print $$2; exit}' go.mod)
GO_VERSION_ACTUAL=$(shell go env GOVERSION)
# Only verify-vendor uses this, and it is set explicitly rather than inherited:
# the documented build environment for this repository is GOPROXY=off, and a
# developer with that exported and a warm module cache would re-vendor from the
# cache - the hashes are still checked against go.sum, but nothing is fetched,
# so the gate would silently stop asking the proxy anything.
VENDOR_PROXY ?= https://proxy.golang.org,direct
LD_FLAGS=-ldflags "-X main.BuildVersion=$(BUILD)"
# -trimpath keeps the build machine's absolute paths out of the binary.
# -buildvcs=false keeps Go from stamping vcs.revision/vcs.modified on its own,
# which would otherwise make a build with .git in the context differ from one
# without it; BuildVersion above stays the single source of the version.
GO_BUILD=CGO_ENABLED=0 go build -trimpath -buildvcs=false $(LD_FLAGS)

.PHONY: build
build: verify-toolchain
	$(GO_BUILD) -o $(BUILD_DIR)/ ./...

.PHONY: verify-toolchain
verify-toolchain:
	@if [ "$(GO_VERSION_ACTUAL)" != "$(GO_VERSION_EXPECTED)" ]; then \
		echo "toolchain mismatch: building with $(GO_VERSION_ACTUAL), go.mod expects $(GO_VERSION_EXPECTED)."; \
		echo "Builds on this machine are self-consistent but will not match a release built by CI."; \
		echo "Install $(GO_VERSION_EXPECTED), or set ALLOW_TOOLCHAIN_DRIFT=1 to accept same-machine checking only."; \
		[ -n "$(ALLOW_TOOLCHAIN_DRIFT)" ] || exit 1; \
		echo "ALLOW_TOOLCHAIN_DRIFT is set, continuing."; \
	fi

# Without this, dropping -trimpath would go unnoticed: verify-reproducible runs
# both builds on one machine from one directory, so embedded absolute paths are
# identical in both and the hashes still match. CURDIR is exactly the prefix that
# leaks when -trimpath is absent, and it is correct inside the Docker builder too
# (/app), unlike $$HOME.
.PHONY: verify-trimpath
verify-trimpath: build
	@if [ ! -r "$(BUILD_DIR)/mcp-proxy" ]; then \
		echo "$(BUILD_DIR)/mcp-proxy is missing or unreadable, nothing to check"; exit 1; \
	fi; \
	n=`LC_ALL=C grep -acF "$(CURDIR)" $(BUILD_DIR)/mcp-proxy || true`; \
	if [ "$$n" != "0" ]; then \
		echo "binary embeds the build directory $(CURDIR) ($$n matches): -trimpath is not in effect"; \
		exit 1; \
	fi; \
	echo "no build-directory paths in the binary"

# The gates above only ever look at what make builds. goreleaser builds the
# artifacts people actually download, from its own flag list, so deleting
# -trimpath there would ship every release binary full of runner paths while
# every gate here stayed green. This checks the two lists have not drifted
# apart. It compares flags rather than bytes: the two paths are deliberately
# not byte-identical (goreleaser adds -s -w).
.PHONY: verify-release-flags
verify-release-flags:
	@missing=""; \
	for flag in -trimpath -buildvcs=false CGO_ENABLED=0; do \
		grep -qE "^[[:space:]]*-[[:space:]]+$$flag[[:space:]]*$$" .goreleaser.yaml \
			|| missing="$$missing $$flag"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo ".goreleaser.yaml is missing:$$missing"; \
		echo "release binaries would not match what the Makefile gates guarantee"; \
		exit 1; \
	fi; \
	echo "release flags match the build flags"

# Two properties of the image that nothing else would notice losing, both
# checked statically because both are literally properties of this file.
#
# The digest pins: reproducibility is gated by two builds made a second apart,
# which resolve a moving tag to the same thing every time, so that gate cannot
# see an unpinned base at all. Without this one, deleting a digest passes
# everything.
#
# The USER instruction: it is the last line of a long file, the kind that
# survives a rebase as a deletion nobody reads. Losing it silently returns the
# proxy - and every stdio child it spawns, which inherits its identity - to
# root inside the container. Checking that some USER exists is not enough;
# `USER root` reads as compliance, so the value is checked too.
#
# Demonstrated against both defects: removing the digest from one FROM line
# fails the first check with that line printed, and replacing the final `USER
# mcp:mcp` with either nothing or `USER root` fails the second.
.PHONY: verify-dockerfile
verify-dockerfile:
	@unpinned=`grep -E '^[[:space:]]*FROM[[:space:]]' Dockerfile | grep -vE '@sha256:[a-f0-9]{64}' || true`; \
	if [ -n "$$unpinned" ]; then \
		echo "base image not pinned by digest:"; \
		echo "$$unpinned"; \
		echo "a tag is a pointer its publisher can move; scripts/refresh-base-digests.sh resolves digests"; \
		exit 1; \
	fi; \
	echo "every FROM is pinned by digest"
	@awk '/^[[:space:]]*FROM[[:space:]]/ {u=""} \
	      /^[[:space:]]*USER[[:space:]]/ {u=$$2} \
	      END {if (u == "" || u ~ /^(root|0)(:|$$)/) exit 1}' Dockerfile || { \
		echo "the final stage does not drop to a non-root user:"; \
		echo "the proxy, and every stdio server it spawns, would run as root in the container"; \
		exit 1; \
	}
	@echo "the final stage runs as a non-root user"

.PHONY: verify
verify: verify-toolchain verify-trimpath verify-release-flags verify-dockerfile verify-reproducible

# Split from `verify` because of what they need, not what they check: both reach
# the network - one to re-download the dependencies, one for the vulnerability
# database - and `verify` has to stay runnable on the offline vendored path it
# exists to protect. Anything that publishes an artifact runs both.
.PHONY: verify-supply-chain
verify-supply-chain: verify-vendor verify-vuln

# `go mod verify` is vacuous in this repository: it checks the module download
# cache against go.sum, and a vendored build downloads nothing, so it passes on
# any machine with an empty cache - which is every CI runner, every time. The
# question worth asking about a vendored fork is the other one: does vendor/
# still hold what go.mod and go.sum attest? Re-materialising it answers that,
# because `go mod vendor` verifies every module against go.sum as it downloads,
# and git says whether the result differs from what is committed.
#
# Demonstrated against the defect it targets: one character changed inside
# vendor/github.com/mark3labs/mcp-go/client/stdio.go makes this fail, and
# `go build ./...` does not notice at all - vendor/modules.txt consistency is
# all the toolchain checks.
#
# Pinned with GOTOOLCHAIN for the same reason verify-vuln is: vendor/ should
# reproduce under the toolchain that compiles it, not under whichever Go the
# machine running the gate happens to have. It keeps a future `go mod vendor`
# format change from reading as a tampered dependency, which is the false
# positive that would get this gate switched off.
#
# It deliberately does not restore the tree on failure. The diff is the finding.
.PHONY: verify-vendor
verify-vendor:
	@if [ -n "`git status --porcelain vendor go.mod go.sum`" ]; then \
		echo "vendor/, go.mod or go.sum are already modified - commit or stash first,"; \
		echo "otherwise this gate cannot tell your edit from a tampered dependency."; \
		git status --short vendor go.mod go.sum; \
		exit 1; \
	fi
	GOFLAGS= GOPROXY=$(VENDOR_PROXY) GOTOOLCHAIN=$(GO_VERSION_EXPECTED) go mod vendor
	@if [ -n "`git status --porcelain vendor go.mod go.sum`" ]; then \
		echo "vendor/ does not match what go.mod and go.sum attest:"; \
		git status --short vendor go.mod go.sum; \
		echo "the working tree is left as-is on purpose; the diff is the finding."; \
		echo "restore with: git checkout -- vendor go.mod go.sum"; \
		exit 1; \
	fi; \
	echo "vendor/ matches go.mod and go.sum"

# govulncheck reports standard-library vulnerabilities for the toolchain it runs
# under, which makes the scanning version part of the answer: this tree scans
# clean under go1.27.0 and reports 17 reachable stdlib vulnerabilities under the
# go1.25.5 it pinned until recently. A maintainer on a newer local Go would
# therefore get a clean report for a release that ships a vulnerable one - the
# failure mode where the gate is green and wrong.
#
# GOTOOLCHAIN removes the question instead of documenting it: the scan runs
# under exactly the version go.mod pins, whatever the host has installed, and
# Go fetches that toolchain if it is missing. This is the one place where
# GOTOOLCHAIN is right - the build path deliberately avoids it, because a fetch
# there would break the offline GOPROXY=off build, and this target is already
# online for the vulnerability database.
#
# Note the tool itself cannot be installed by the pinned toolchain
# (golang.org/x/vuln v1.8.0 requires go >= 1.26.0, measured inside
# golang:1.25.14); it is built by whatever Go is on the host, and only the
# packages it loads come from GOTOOLCHAIN. That separation is what makes this
# work at all.
.PHONY: verify-vuln
verify-vuln:
	@command -v govulncheck >/dev/null 2>&1 || { \
		echo "govulncheck not found: go install golang.org/x/vuln/cmd/govulncheck@v1.8.0"; \
		exit 1; \
	}
	@echo "scanning the standard library of $(GO_VERSION_EXPECTED), the toolchain go.mod pins"
	GOTOOLCHAIN=$(GO_VERSION_EXPECTED) govulncheck ./...

.PHONY: verify-reproducible
verify-reproducible: verify-toolchain
	rm -rf $(BUILD_DIR)/repro-a $(BUILD_DIR)/repro-b
	@# Each build is its own make invocation on purpose. Make expands an entire
	@# recipe before running any of it, so a $(shell date +%s) stamp inside one
	@# recipe is evaluated once and substituted into both builds identically -
	@# this gate would then pass against the very defect it exists to catch, no
	@# matter how long it slept. Separate invocations re-evaluate the stamp, and
	@# the sleep is what makes a time-derived one actually differ between them.
	$(MAKE) --no-print-directory build BUILD_DIR=$(BUILD_DIR)/repro-a
	sleep 1
	$(MAKE) --no-print-directory build BUILD_DIR=$(BUILD_DIR)/repro-b
	@a=`cd $(BUILD_DIR)/repro-a && $(SHA256) * | sort -k2`; \
	b=`cd $(BUILD_DIR)/repro-b && $(SHA256) * | sort -k2`; \
	if [ "$$a" != "$$b" ]; then \
		echo "build is NOT reproducible:"; echo "$$a"; echo "--"; echo "$$b"; exit 1; \
	fi; \
	echo "build is reproducible ($(BUILD), $(GO_VERSION_ACTUAL)):"; echo "$$a"

.PHONY: buildLinuxX86
buildLinuxX86: verify-toolchain
	GOOS=linux GOARCH=amd64 $(GO_BUILD) -o $(BUILD_DIR)/ ./...

# The upstream buildImage target is gone. It published to a namespace this fork
# cannot write to, so it could only ever fail or, worse, succeed against someone
# else's registry. Image builds go through scripts/build-push.sh, which takes
# the registry from the environment, refuses to publish a dirty tree, and hands
# the version stamp to the build instead of letting Docker derive it.

.PHONY: format
format:
	go fix ./...
	go fmt ./...
	go vet ./...
	go get ./...
	go test ./...
	go mod tidy
	golangci-lint fmt --no-config --enable gofmt,goimports
	golangci-lint run --no-config --fix
	nilaway -include-pkgs="$(MODULE)" ./...