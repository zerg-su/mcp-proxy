package main

import (
	"context"
	"os"
	"os/exec"
	"strings"

	"github.com/mark3labs/mcp-go/client/transport"
)

// A stdio downstream is a child process, and by default mcp-go gives it
// `append(os.Environ(), configured...)` - the gateway's entire environment plus
// the server's own entries. FORK.md has described that as a deployment problem
// since the fork existed, with the only available mitigation being "do not put
// secrets in the proxy's environment". That mitigation does not survive contact
// with CI, where the environment is where credentials live: a runner that
// exports AWS keys, a registry password and a deploy token hands all of them to
// every third-party MCP server in the config, including the one whose job is to
// read somebody else's web page.
//
// mcp-go exposes transport.WithCommandFunc, which hands construction of the
// exec.Cmd to the caller. That is enough to fix this here rather than in a
// wrapper around the command, and it keeps working across reconnects, because
// the transport calls the same factory every time it respawns the child.
//
// Off by default: turning it on for an existing deployment breaks every
// downstream that quietly depended on an inherited variable, and this is a
// library-shaped repository where that decision belongs to whoever runs it.
type stdioEnvPolicy struct {
	// clean is false for upstream's behaviour: inherit everything.
	clean bool
	// passthrough names the variables copied from the gateway when clean is
	// true. Nothing else crosses.
	passthrough []string
}

// stdioEnv is process-wide because the policy is: it comes from a command-line
// flag, is set once before any client is built, and every stdio child is
// subject to the same one. Threading it through the config types instead would
// touch the schema, which is upstream's to develop.
var stdioEnv stdioEnvPolicy

// newStdioEnvPolicy parses the flag pair. An empty or whitespace-only entry in
// the list is dropped rather than turned into a variable named "", which the
// child's libc would reject in ways that surface far from here.
func newStdioEnvPolicy(clean bool, passthrough string) stdioEnvPolicy {
	policy := stdioEnvPolicy{clean: clean}
	for _, name := range strings.Split(passthrough, ",") {
		if name = strings.TrimSpace(name); name != "" {
			policy.passthrough = append(policy.passthrough, name)
		}
	}
	return policy
}

// stdioClientOptions returns no options at all when the policy is off, so the
// default path stays byte-for-byte upstream's.
func stdioClientOptions() []transport.StdioOption {
	if !stdioEnv.clean {
		return nil
	}
	return []transport.StdioOption{transport.WithCommandFunc(stdioEnv.commandFunc)}
}

func (p stdioEnvPolicy) commandFunc(ctx context.Context, command string, env []string, args []string) (*exec.Cmd, error) {
	cmd := exec.CommandContext(ctx, command, args...)
	cmd.Env = p.childEnv(env)
	return cmd, nil
}

// childEnv builds the child's entire environment: the passthrough variables
// that are actually set, then the server's configured ones.
//
// The order matters and is deliberate. os/exec keeps the last value for a
// duplicated key, so a server that sets PATH in its own `env` overrides the
// inherited one rather than being silently overridden by it - the config is
// more specific than the policy, and should win.
//
// A passthrough name that is not set in the gateway's environment is skipped,
// not exported empty: "PATH=" is not the same as no PATH, and the difference
// decides whether the child can find any executable at all.
func (p stdioEnvPolicy) childEnv(configured []string) []string {
	env := make([]string, 0, len(p.passthrough)+len(configured))
	for _, name := range p.passthrough {
		if value, ok := os.LookupEnv(name); ok {
			env = append(env, name+"="+value)
		}
	}
	return append(env, configured...)
}
