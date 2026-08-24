package provider

import (
	"bytes"
	"context"
	"os"
)

// ExpandEnv is a Provider adapter that expands environment variables
// present in the underlying provider's raw configuration bytes.
//
// It treats the configuration as UTF-8 text and replaces $var or ${var}
// using os.ExpandEnv rules. Undefined variables expand to an empty string.
// This is useful when your config file or HTTP payload includes placeholders
// like "${PORT}" that should be resolved at runtime.
//
// Note: This adapter is text-oriented. If the underlying data is non-text or
// contains many literal '$' characters, expansion may be undesirable.
type ExpandEnv struct {
	provider Provider
}

// NewExpandEnv wraps an existing Provider and returns a new Provider that
// expands environment variable placeholders in the returned bytes.
func NewExpandEnv(provider Provider) *ExpandEnv {
	return &ExpandEnv{provider: provider}
}

// Read implements Provider. It reads bytes from the wrapped provider and then
// applies os.ExpandEnv to expand environment variables. If there is no '$'
// in the content, the original bytes are returned without allocation.
func (e *ExpandEnv) Read(ctx context.Context) ([]byte, error) {
	data, err := e.provider.Read(ctx)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 || bytes.IndexByte(data, '$') == -1 {
		return data, nil
	}
	expandedData := os.ExpandEnv(string(data))
	return []byte(expandedData), nil
}
