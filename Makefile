BUILD_DIR=./build
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
buildLinuxX86:
	GOOS=linux GOARCH=amd64 $(GO_BUILD) -o $(BUILD_DIR)/ ./...

.PHONY: buildImage
buildImage:
	docker buildx build --platform=linux/amd64,linux/arm64 --build-arg BUILD_VERSION=$(BUILD) -t ghcr.io/tbxark/map-proxy:latest . --push --provenance=false

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