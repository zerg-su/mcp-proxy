package main

import (
	"fmt"
	"sort"
	"strings"
)

// requireAuthTokens reports every route that would be published without any
// authentication in front of it.
//
// Authentication here is opt-in and per route: http.go attaches the bearer
// middleware only when a server's resolved authTokens list is non-empty, so a
// server that names no tokens and inherits none is served openly to whoever
// can reach the address. That is a reasonable default for the single-user case
// this proxy was written for, and the wrong one for a deployment that exposes
// it to a pipeline - where the failure is silent, because an open route
// behaves exactly like a working one.
//
// The check exists as a flag rather than as validation because it is policy,
// not correctness: -require-auth turns "every route is authenticated" into
// something a deployment can assert about a config it did not write, next to
// -check-config in CI, instead of something a reviewer has to notice.
//
// It runs on the config after load(), where per-server options have already
// inherited mcpProxy.options, so it sees the same token lists http.go will.
// Disabled servers are excluded: they mount no route at all. A server whose
// options are missing entirely is reported rather than skipped - load() fills
// them in, so it cannot happen, and a security check that resolves an
// impossible case in the permissive direction is one refactor away from being
// wrong quietly.
func requireAuthTokens(config *Config) error {
	if config == nil {
		return fmt.Errorf("no config to check")
	}
	open := make([]string, 0, len(config.McpServers))
	for name, clientConfig := range config.McpServers {
		if clientConfig != nil && clientConfig.Options != nil {
			if clientConfig.Options.Disabled {
				continue
			}
			if len(clientConfig.Options.AuthTokens) > 0 {
				continue
			}
		}
		open = append(open, name)
	}
	if len(open) == 0 {
		return nil
	}
	// Sorted so that the message is the same on every run: map iteration order
	// would otherwise reorder the names between two runs of the same CI job,
	// and a diffable failure is worth the sort.
	sort.Strings(open)
	// One line, because this is rendered as a slog attribute: a newline in the
	// middle arrives as a literal \n inside a quoted value and makes the
	// remedy harder to read than no remedy at all.
	return fmt.Errorf(
		"-require-auth: %d of %d server(s) would be served without authentication: %s; "+
			"give each one options.authTokens, or set mcpProxy.options.authTokens as the default they inherit",
		len(open), len(config.McpServers), strings.Join(open, ", "))
}
