package main

import (
	"slices"
	"testing"
)

func TestNewStdioEnvPolicy(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		passthrough string
		want        []string
	}{
		{name: "defaults", passthrough: "PATH,HOME", want: []string{"PATH", "HOME"}},
		{name: "spaces are trimmed", passthrough: " PATH , HOME ", want: []string{"PATH", "HOME"}},
		{name: "empty entries are dropped", passthrough: "PATH,,HOME,", want: []string{"PATH", "HOME"}},
		{name: "nothing at all", passthrough: "", want: nil},
		{name: "commas only", passthrough: ",,,", want: nil},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got := newStdioEnvPolicy(true, tt.passthrough)
			if !slices.Equal(got.passthrough, tt.want) {
				t.Errorf("passthrough = %v, want %v", got.passthrough, tt.want)
			}
		})
	}
}

func TestStdioEnvPolicyChildEnv(t *testing.T) {
	t.Setenv("MCP_PROXY_PASS_ME", "inherited")
	t.Setenv("MCP_PROXY_SECRET", "must-not-cross")

	policy := newStdioEnvPolicy(true, "MCP_PROXY_PASS_ME,MCP_PROXY_NOT_SET")
	env := policy.childEnv([]string{"CONFIGURED=yes"})

	want := []string{"MCP_PROXY_PASS_ME=inherited", "CONFIGURED=yes"}
	if !slices.Equal(env, want) {
		t.Fatalf("childEnv = %v, want %v", env, want)
	}
	// Named separately from the equality check above, because this is the
	// property the flag exists for and it should fail with its own message.
	if slices.Contains(env, "MCP_PROXY_SECRET=must-not-cross") {
		t.Error("a variable outside the passthrough list reached the child")
	}
}

// A name that is set in the gateway must not be exported to the child as an
// empty value when it is absent: "PATH=" and no PATH are different, and the
// difference decides whether the child can execute anything.
func TestStdioEnvPolicySkipsUnsetNames(t *testing.T) {
	policy := newStdioEnvPolicy(true, "MCP_PROXY_DEFINITELY_NOT_SET")
	if env := policy.childEnv(nil); len(env) != 0 {
		t.Errorf("childEnv = %v, want nothing for an unset passthrough name", env)
	}
}

// The config is more specific than the policy, so a server that sets a variable
// itself must win over the inherited one. os/exec keeps the last duplicate.
func TestStdioEnvPolicyConfiguredValueWins(t *testing.T) {
	t.Setenv("MCP_PROXY_OVERRIDE_ME", "from-gateway")

	policy := newStdioEnvPolicy(true, "MCP_PROXY_OVERRIDE_ME")
	env := policy.childEnv([]string{"MCP_PROXY_OVERRIDE_ME=from-config"})

	if len(env) == 0 || env[len(env)-1] != "MCP_PROXY_OVERRIDE_ME=from-config" {
		t.Errorf("childEnv = %v, want the configured value last so it takes effect", env)
	}
}

// With the policy off, nothing is installed at all: the transport keeps
// upstream's behaviour rather than going through a factory that reproduces it.
func TestStdioClientOptionsEmptyUnlessClean(t *testing.T) {
	stdioEnv = newStdioEnvPolicy(false, "PATH,HOME")
	if opts := stdioClientOptions(); len(opts) != 0 {
		t.Errorf("stdioClientOptions() returned %d option(s) with the policy off, want none", len(opts))
	}

	stdioEnv = newStdioEnvPolicy(true, "PATH,HOME")
	if opts := stdioClientOptions(); len(opts) != 1 {
		t.Errorf("stdioClientOptions() returned %d option(s) with the policy on, want 1", len(opts))
	}
	stdioEnv = stdioEnvPolicy{}
}
