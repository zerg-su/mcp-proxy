package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRequireAuthTokens(t *testing.T) {
	t.Parallel()

	server := func(opts *OptionsV2) *MCPClientConfigV2 {
		return &MCPClientConfigV2{Command: "server", Options: opts}
	}

	tests := []struct {
		name    string
		servers map[string]*MCPClientConfigV2
		// wantErr is a substring; empty means the config must be accepted.
		wantErr string
	}{
		{
			name:    "server with its own token",
			servers: map[string]*MCPClientConfigV2{"a": server(&OptionsV2{AuthTokens: []string{"t"}})},
		},
		{
			name:    "server with no token at all",
			servers: map[string]*MCPClientConfigV2{"a": server(&OptionsV2{})},
			wantErr: "1 of 1 server(s) would be served without authentication: a",
		},
		{
			name: "disabled servers mount no route, so they are not reported",
			servers: map[string]*MCPClientConfigV2{
				"off": server(&OptionsV2{Disabled: true}),
				"on":  server(&OptionsV2{AuthTokens: []string{"t"}}),
			},
		},
		{
			name: "every unauthenticated server is named, in a stable order",
			servers: map[string]*MCPClientConfigV2{
				"zulu":  server(&OptionsV2{}),
				"alpha": server(&OptionsV2{}),
				"mike":  server(&OptionsV2{AuthTokens: []string{"t"}}),
			},
			wantErr: "2 of 3 server(s) would be served without authentication: alpha, zulu",
		},
		{
			// load() always fills Options in; this asserts the direction the
			// check fails in if that ever stops being true.
			name:    "missing options are reported, not skipped",
			servers: map[string]*MCPClientConfigV2{"a": {Command: "server"}},
			wantErr: "without authentication: a",
		},
		{
			name:    "nil server entry is reported too",
			servers: map[string]*MCPClientConfigV2{"a": nil},
			wantErr: "without authentication: a",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			config := validTestConfig()
			config.McpServers = tt.servers
			err := requireAuthTokens(config)
			switch {
			case tt.wantErr == "" && err != nil:
				t.Fatalf("expected the config to be accepted, got %v", err)
			case tt.wantErr != "" && err == nil:
				t.Fatalf("expected an error containing %q, got none", tt.wantErr)
			case tt.wantErr != "" && !strings.Contains(err.Error(), tt.wantErr):
				t.Fatalf("expected an error containing %q, got %v", tt.wantErr, err)
			}
		})
	}
}

// The tokens a server is checked against are the ones it ends up with, not the
// ones its own entry spells out: load() copies mcpProxy.options.authTokens into
// every server that omits the key. Checking the raw file instead would report
// a fleet-wide default as if it were an open route.
func TestRequireAuthTokensSeesInheritedTokens(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "config.json")
	data := []byte(`{
		"mcpProxy": {
			"baseURL": "http://localhost:9090",
			"addr": ":9090",
			"name": "p",
			"version": "1",
			"options": {"authTokens": ["inherited"]}
		},
		"mcpServers": {
			"inherits": {"command": "server"},
			"explicit": {"command": "server", "options": {"authTokens": ["own"]}}
		}
	}`)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	config, err := load(path, false, true, "", 10)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if err := requireAuthTokens(config); err != nil {
		t.Fatalf("expected inherited tokens to count as authentication, got %v", err)
	}
}

func TestRequireToolAllowlist(t *testing.T) {
	t.Parallel()

	server := func(opts *OptionsV2) *MCPClientConfigV2 {
		return &MCPClientConfigV2{Command: "server", Options: opts}
	}
	allow := func(list ...string) *OptionsV2 {
		return &OptionsV2{ToolFilter: &ToolFilterConfig{Mode: ToolFilterModeAllow, List: list}}
	}

	tests := []struct {
		name    string
		servers map[string]*MCPClientConfigV2
		wantErr string
	}{
		{
			name:    "allow list with entries",
			servers: map[string]*MCPClientConfigV2{"a": server(allow("read"))},
		},
		{
			// client.go lowercases the mode before applying the filter, so this
			// really does restrict tools and must not be reported.
			name: "mode casing follows the enforcement",
			servers: map[string]*MCPClientConfigV2{
				"a": server(&OptionsV2{ToolFilter: &ToolFilterConfig{Mode: ToolFilterMode("ALLOW"), List: []string{"read"}}}),
			},
		},
		{
			name:    "no filter at all",
			servers: map[string]*MCPClientConfigV2{"a": server(&OptionsV2{})},
			wantErr: "1 of 1 server(s) expose every tool",
		},
		{
			// The trap: reads as a restriction, exposes everything.
			name:    "allow mode with an empty list",
			servers: map[string]*MCPClientConfigV2{"a": server(allow())},
			wantErr: "expose every tool their downstream offers, now and after any update: a",
		},
		{
			// The other trap: a block list is what a new tool walks straight
			// past, which is the whole reason for this check.
			name: "block list",
			servers: map[string]*MCPClientConfigV2{
				"a": server(&OptionsV2{ToolFilter: &ToolFilterConfig{Mode: ToolFilterModeBlock, List: []string{"dangerous"}}}),
			},
			wantErr: "expose every tool",
		},
		{
			name: "disabled servers mount no route",
			servers: map[string]*MCPClientConfigV2{
				"off": server(&OptionsV2{Disabled: true}),
				"on":  server(allow("read")),
			},
		},
		{
			name: "unrestricted servers are named in a stable order",
			servers: map[string]*MCPClientConfigV2{
				"zulu":  server(&OptionsV2{}),
				"alpha": server(allow()),
				"mike":  server(allow("read")),
			},
			wantErr: "2 of 3 server(s) expose every tool their downstream offers, now and after any update: alpha, zulu",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			config := validTestConfig()
			config.McpServers = tt.servers
			err := requireToolAllowlist(config)
			switch {
			case tt.wantErr == "" && err != nil:
				t.Fatalf("expected the config to be accepted, got %v", err)
			case tt.wantErr != "" && err == nil:
				t.Fatalf("expected an error containing %q, got none", tt.wantErr)
			case tt.wantErr != "" && !strings.Contains(err.Error(), tt.wantErr):
				t.Fatalf("expected an error containing %q, got %v", tt.wantErr, err)
			}
		})
	}
}

// A filter declared once on mcpProxy.options is not inherited by servers -
// TestGlobalToolFilterIsNotInherited pins that - so the policy must report a
// server that has none of its own, however restrictive the proxy-level one
// looks. This is the case a reader of the old documentation would have written.
func TestRequireToolAllowlistIgnoresTheProxyLevelFilter(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "config.json")
	data := []byte(`{
		"mcpProxy": {
			"baseURL": "http://localhost:9090",
			"addr": ":9090",
			"name": "p",
			"version": "1",
			"options": {"toolFilter": {"mode": "allow", "list": ["echo"]}}
		},
		"mcpServers": {"inherits": {"command": "server"}}
	}`)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	config, err := load(path, false, true, "", 10)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	err = requireToolAllowlist(config)
	if err == nil {
		t.Fatal("a server with no filter of its own was accepted because the proxy declares one")
	}
	if !strings.Contains(err.Error(), "inherits") {
		t.Errorf("error = %v, want the unrestricted server named", err)
	}
}

// Both policies report in one run, so a production config does not have to be
// fixed one deploy at a time.
func TestCheckPoliciesReportsEveryFailure(t *testing.T) {
	t.Parallel()

	config := validTestConfig()
	config.McpServers = map[string]*MCPClientConfigV2{"a": {Command: "server", Options: &OptionsV2{}}}

	if errs := checkPolicies(config, false, false); len(errs) != 0 {
		t.Errorf("checkPolicies with nothing enabled returned %v, want no errors", errs)
	}
	errs := checkPolicies(config, true, true)
	if len(errs) != 2 {
		t.Fatalf("checkPolicies returned %d error(s), want one per enabled policy: %v", len(errs), errs)
	}
}
