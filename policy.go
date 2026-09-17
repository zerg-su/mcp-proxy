package main

import (
	"fmt"
	"sort"
	"strings"
)

// Deployment policies: checks that are not about whether a config is valid, but
// about whether it is acceptable where it is being deployed. Each is a flag,
// because the same config is right on a laptop and wrong in a pipeline, and
// only the deployment knows which one it is. They run against the config after
// load(), so they see what the proxy will actually do rather than what the file
// appears to say.

// checkPolicies runs the enabled policies and returns every failure, not just
// the first: someone fixing a production config should learn about both
// problems in one run rather than in two deploys.
func checkPolicies(config *Config, requireAuth, requireAllowlist bool) []error {
	checks := make([]func(*Config) error, 0, 2)
	if requireAuth {
		checks = append(checks, requireAuthTokens)
	}
	if requireAllowlist {
		checks = append(checks, requireToolAllowlist)
	}
	errs := make([]error, 0, len(checks))
	for _, check := range checks {
		if err := check(config); err != nil {
			errs = append(errs, err)
		}
	}
	return errs
}

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

// requireToolAllowlist reports every enabled server whose tools are not
// restricted to a list someone wrote down.
//
// The point is what happens on the day a downstream ships a new tool. Under a
// block list, or no filter at all, that tool is exposed to the model the moment
// the server is updated, with nothing in this repository or in the config
// changing. Under an allow list it is not exposed until a human adds it.
//
// "Has an allow list" is deliberately stricter than "says allow", because two
// configurations say allow and restrict nothing - both verified against a
// running proxy, both documented in docs/CONFIGURATION.md:
//
//   - mode "allow" with an empty list exposes every tool. The filter is inert
//     until its list is non-empty; the proxy logs a warning and carries on.
//   - a filter on mcpProxy.options is not inherited. A server that omits its
//     own toolFilter is unfiltered, however restrictive the proxy-level one
//     looks.
//
// Those are the states this check exists to catch. A config that "looks
// restricted" is exactly the one nobody re-reads.
//
// The mode is lowercased before comparison because that is what client.go does
// when it applies the filter: a policy that disagreed with the enforcement
// about whether "Allow" counts would be worse than no policy.
func requireToolAllowlist(config *Config) error {
	unrestricted := make([]string, 0, len(config.McpServers))
	for name, clientConfig := range config.McpServers {
		if clientConfig != nil && clientConfig.Options != nil {
			if clientConfig.Options.Disabled {
				continue
			}
			if filter := clientConfig.Options.ToolFilter; filter != nil &&
				ToolFilterMode(strings.ToLower(string(filter.Mode))) == ToolFilterModeAllow &&
				len(filter.List) > 0 {
				continue
			}
		}
		unrestricted = append(unrestricted, name)
	}
	if len(unrestricted) == 0 {
		return nil
	}
	sort.Strings(unrestricted)
	return fmt.Errorf(
		"-require-tool-allowlist: %d of %d server(s) expose every tool their downstream offers, now and after any update: %s; "+
			"give each one options.toolFilter with mode \"allow\" and a non-empty list - an empty list, a block list, "+
			"and a filter set only on mcpProxy.options all leave the server unrestricted",
		len(unrestricted), len(config.McpServers), strings.Join(unrestricted, ", "))
}
