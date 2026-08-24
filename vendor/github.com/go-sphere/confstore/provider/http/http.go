package http

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var (
	// ErrBodyTooLarge indicates the HTTP response body exceeded the configured max size.
	ErrBodyTooLarge = errors.New("http provider: body too large")
)

// HTTP provides configuration bytes fetched from an HTTP(S) endpoint.
// Required: URL. Optional: headers, timeout, custom client, HTTP method.
type HTTP struct {
	url  string
	opts *options
}

type options struct {
	timeout time.Duration
	client  *http.Client
	method  string
	header  http.Header
	// maxBodySize limits the response body size in bytes. 0 means unlimited.
	maxBodySize int64
}

// Option configures optional behavior for the HTTP provider.
type Option func(*options)

// WithTimeout sets a client-level timeout for requests when using the
// internally created http.Client. Default: no timeout (0). Prefer controlling
// request deadlines with context (e.g., context.WithTimeout). If a custom
// client is supplied via WithClient, this option is ignored.
func WithTimeout(d time.Duration) Option { return func(o *options) { o.timeout = d } }

// WithClient sets a custom HTTP client. When provided, it takes precedence
// over WithTimeout. The provided client will be used as-is.
func WithClient(c *http.Client) Option { return func(o *options) { o.client = c } }

// WithMethod sets the HTTP method. Default: GET.
func WithMethod(m string) Option { return func(o *options) { o.method = m } }

// WithHeader adds or overrides a single request header.
func WithHeader(key, value string) Option {
	return func(o *options) {
		if o.header == nil {
			o.header = make(http.Header)
		}
		o.header.Set(key, value)
	}
}

// WithHeaders merges multiple headers into the request headers.
func WithHeaders(h http.Header) Option {
	return func(o *options) {
		if h == nil {
			return
		}
		if o.header == nil {
			o.header = make(http.Header)
		}
		for k, vs := range h {
			for _, v := range vs {
				o.header.Add(k, v)
			}
		}
	}
}

// WithMaxBodySize limits the maximum response body size in bytes.
// If the response exceeds this size, Read returns ErrBodyTooLarge.
// A non-positive value disables the limit.
func WithMaxBodySize(n int64) Option { return func(o *options) { o.maxBodySize = n } }

func newOptions(opts ...Option) *options {
	o := &options{
		// Default: no client timeout. Prefer caller-provided context.
		timeout: 0,
		method:  http.MethodGet,
	}
	for _, opt := range opts {
		opt(o)
	}
	if o.client == nil {
		o.client = &http.Client{}
		if o.timeout > 0 {
			o.client.Timeout = o.timeout
		}
	}
	return o
}

// New creates an HTTP-backed Provider.
func New(url string, opts ...Option) *HTTP {
	return &HTTP{
		url:  url,
		opts: newOptions(opts...),
	}
}

// Read implements Provider by performing the HTTP request and returning the body bytes.
func (h *HTTP) Read(ctx context.Context) ([]byte, error) {
	// Use caller-provided context for per-request cancellation/deadlines.
	// If WithTimeout was specified without a custom client, client.Timeout
	// is set in newHTTPOptions.
	req, err := http.NewRequestWithContext(ctx, h.opts.method, h.url, nil)
	if err != nil {
		return nil, fmt.Errorf("http provider: build request %s %s: %w", h.opts.method, h.url, err)
	}
	for k, vs := range h.opts.header {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	resp, err := h.opts.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("http provider: do request %s %s: %w", h.opts.method, h.url, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("http provider: %s %s unexpected status %s", h.opts.method, h.url, resp.Status)
	}
	var reader io.Reader = resp.Body
	// Fast-fail when Content-Length is known to exceed the limit.
	if h.opts.maxBodySize > 0 && resp.ContentLength > h.opts.maxBodySize {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("%w: content-length %d exceeds limit %d", ErrBodyTooLarge, resp.ContentLength, h.opts.maxBodySize)
	}
	if h.opts.maxBodySize > 0 {
		// Allow reading up to limit+1 to detect overflow precisely.
		reader = io.LimitReader(resp.Body, h.opts.maxBodySize+1)
	}
	data, err := io.ReadAll(reader)
	if err != nil {
		return nil, fmt.Errorf("http provider: read body %s %s: %w", h.opts.method, h.url, err)
	}
	if h.opts.maxBodySize > 0 && int64(len(data)) > h.opts.maxBodySize {
		// Body exceeded the limit. Best-effort drain any remaining bytes.
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("%w: read %d exceeds limit %d", ErrBodyTooLarge, len(data), h.opts.maxBodySize)
	}
	return data, nil
}

// IsRemoteURL reports whether the given path is a remote HTTP(S) URL.
func IsRemoteURL(path string) bool {
	u, err := url.Parse(path)
	if err != nil {
		return false
	}
	s := strings.ToLower(u.Scheme)
	return (s == "http" || s == "https") && u.Host != ""
}
