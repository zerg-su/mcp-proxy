BUILD_DIR=./build
# One commit must always produce one binary, so the stamp is derived from the
# revision instead of the wall clock. The fallback is mandatory: the Docker
# build has no .git in its context, and an empty stamp would compile in an
# empty -X main.BuildVersion.
BUILD=$(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
CURRENT_OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
CURRENT_ARCH := $(shell uname -m | tr '[:upper:]' '[:lower:]')
SHA256=$(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo shasum -a 256)
LD_FLAGS=-ldflags "-X main.BuildVersion=$(BUILD)"
# -trimpath keeps the build machine's absolute paths out of the binary.
# -buildvcs=false keeps Go from stamping vcs.revision/vcs.modified on its own,
# which would otherwise make a build with .git in the context differ from one
# without it; BuildVersion above stays the single source of the version.
GO_BUILD=CGO_ENABLED=0 go build -trimpath -buildvcs=false $(LD_FLAGS)

.PHONY: build
build:
	$(GO_BUILD) -o $(BUILD_DIR)/ ./...

.PHONY: verify-reproducible
verify-reproducible:
	rm -rf $(BUILD_DIR)/repro-a $(BUILD_DIR)/repro-b
	$(GO_BUILD) -o $(BUILD_DIR)/repro-a/ ./...
	$(GO_BUILD) -o $(BUILD_DIR)/repro-b/ ./...
	@a=`cd $(BUILD_DIR)/repro-a && $(SHA256) * | sort -k2`; \
	b=`cd $(BUILD_DIR)/repro-b && $(SHA256) * | sort -k2`; \
	if [ "$$a" != "$$b" ]; then \
		echo "build is NOT reproducible:"; echo "$$a"; echo "--"; echo "$$b"; exit 1; \
	fi; \
	echo "build is reproducible ($(BUILD)):"; echo "$$a"

.PHONY: buildLinuxX86
buildLinuxX86:
	GOOS=linux GOARCH=amd64 $(GO_BUILD) -o $(BUILD_DIR)/ ./...

.PHONY: buildImage
buildImage:
	docker buildx build --platform=linux/amd64,linux/arm64 -t ghcr.io/tbxark/map-proxy:latest . --push --provenance=false

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