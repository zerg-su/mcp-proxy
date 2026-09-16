package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"
)

var BuildVersion = "dev"

func main() {
	conf := flag.String("config", "config.json", "path to config file or a http(s) url")
	insecure := flag.Bool("insecure", false, "allow insecure HTTPS connections by skipping TLS certificate verification")
	expandEnv := flag.Bool("expand-env", true, "expand environment variables in config file")
	httpHeaders := flag.String("http-headers", "", "optional HTTP headers for config URL, format: 'Key1:Value1;Key2:Value2'")
	httpTimeout := flag.Int("http-timeout", 10, "HTTP timeout in seconds when fetching config from URL")
	authorize := flag.String("authorize", "", "run a one-time interactive OAuth authorization for the named mcpServers entry, then exit. Opens a browser; run this by hand, not from the daemon/service.")
	checkConfig := flag.Bool("check-config", false, "load and validate the config, then exit without starting the server")
	requireAuth := flag.Bool("require-auth", false, "refuse to start, or to report a config OK, when any enabled server would be served with no authTokens in front of it. Off by default: an unauthenticated route is a valid local setup. Turn it on wherever the proxy is reachable by anything other than you.")
	authStatus := flag.Bool("auth-status", false, "list every configured MCP server with its transport and authentication state, then exit. Local-only: reads config.json and cached OAuth token expiry, makes no network calls.")
	doctor := flag.Bool("doctor", false, "like -auth-status, but also connects to each remote server to confirm its credentials are accepted right now (may refresh an expired OAuth token via its refresh token; never opens a browser)")
	var logLevel slog.Level
	flag.TextVar(&logLevel, "log-level", slog.LevelInfo, "log level (debug, info, warn, error)")

	version := flag.Bool("version", false, "print version and exit")
	help := flag.Bool("help", false, "print help and exit")
	flag.Parse()
	if *help {
		flag.Usage()
		return
	}
	if *version {
		fmt.Println(BuildVersion)
		return
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: logLevel})))
	if *authorize != "" {
		if err := runAuthorize(*conf, *authorize, *insecure, *expandEnv, *httpHeaders, *httpTimeout); err != nil {
			slog.Error("Failed to authorize server", "server", *authorize, "err", redactURLCredentials(err))
			os.Exit(1)
		}
		return
	}
	if *authStatus || *doctor {
		ok, err := runDoctor(*conf, *insecure, *expandEnv, *httpHeaders, *httpTimeout, *doctor)
		if err != nil {
			slog.Error("Failed to run doctor", "err", redactURLCredentials(err))
			os.Exit(1)
		}
		if !ok {
			os.Exit(1)
		}
		return
	}
	config, err := load(*conf, *insecure, *expandEnv, *httpHeaders, *httpTimeout)
	if err != nil {
		slog.Error("Failed to load config", "err", redactURLCredentials(err))
		os.Exit(1)
	}
	// Before -check-config reports OK, so that the same command a deployment
	// runs to validate a config also enforces this, and before the server
	// starts, so that a config which loses its tokens does not come back up
	// serving them openly.
	if *requireAuth {
		if err := requireAuthTokens(config); err != nil {
			slog.Error("Config rejected", "err", err)
			os.Exit(1)
		}
	}
	if *checkConfig {
		fmt.Printf("Config OK: %d MCP server(s) configured\n", len(config.McpServers))
		return
	}
	err = startHTTPServer(config)
	if err != nil {
		slog.Error("Failed to start server", "err", redactURLCredentials(err))
		os.Exit(1)
	}
}
