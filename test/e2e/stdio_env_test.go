package e2e

import (
	"testing"
)

// What a stdio downstream inherits is a property of the proxy process, so it
// can only be observed from outside: these run the real binary with a secret in
// its own environment and ask the fixture, through the proxy, what it can see.
//
// The pair is the point. The first test is the defect - upstream's behaviour,
// still the default - and it must keep passing, or the second one proves
// nothing about the flag.

const (
	secretName  = "MCP_PROXY_TEST_SECRET"
	secretValue = "credential-the-child-must-not-see"
)

func TestStdioChildInheritsEverythingByDefault(t *testing.T) {
	skipShort(t)
	t.Parallel()

	configPath, addr := stdioConfig(t, "streamable-http")
	proxy := launchProxyWith(t, configPath, addr, []string{secretName + "=" + secretValue})
	proxy.waitForReady(t)

	mcpClient := proxy.connect(t, "streamable-http", "fixture")
	if got := callToolText(t, mcpClient, "getenv", map[string]any{"name": secretName}); got != secretValue {
		t.Errorf("getenv(%s) = %q, want %q: the default is still to inherit the whole environment, "+
			"and the -stdio-clean-env test below is only meaningful while that is true", secretName, got, secretValue)
	}
}

func TestStdioCleanEnvKeepsTheGatewaysSecretsFromTheChild(t *testing.T) {
	skipShort(t)
	t.Parallel()

	configPath, addr := stdioConfig(t, "streamable-http")
	proxy := launchProxyWith(t, configPath, addr,
		[]string{secretName + "=" + secretValue},
		"-stdio-clean-env")
	proxy.waitForReady(t)

	mcpClient := proxy.connect(t, "streamable-http", "fixture")

	if got := callToolText(t, mcpClient, "getenv", map[string]any{"name": secretName}); got != "" {
		t.Errorf("getenv(%s) = %q, want empty: a variable outside the passthrough list reached the child", secretName, got)
	}

	// The server's own configured env has to survive, or the flag would only
	// be usable by downstreams that need no configuration at all.
	if got := callToolText(t, mcpClient, "getenv", map[string]any{"name": "MCP_PROXY_TEST_ENV"}); got != testEnvValue {
		t.Errorf("getenv(MCP_PROXY_TEST_ENV) = %q, want %q: mcpServers.<name>.env must still reach the child", got, testEnvValue)
	}

	// And the defaults have to be enough for the child to be a working
	// process. A downstream that cannot see PATH cannot spawn anything, which
	// is how npx and uvx servers fail.
	if got := callToolText(t, mcpClient, "getenv", map[string]any{"name": "PATH"}); got == "" {
		t.Error("getenv(PATH) is empty: the default passthrough list did not reach the child")
	}
}
