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
