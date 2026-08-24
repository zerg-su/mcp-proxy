# confstore

Lightweight configuration loader for Go. Combine a `Provider` (file, HTTP, etc.) with a `Codec` (JSON by default) to load typed configs.

## Install

```
go get github.com/go-sphere/confstore
```

## Quick Start

```go
package main

import (
    "fmt"
    "github.com/go-sphere/confstore"
    "github.com/go-sphere/confstore/codec"
    "github.com/go-sphere/confstore/provider/file"
)

type AppConf struct {
    Addr string `json:"addr"`
    Mode string `json:"mode"`
}

func main() {
    // Load from a local JSON file
    p := file.New("./config.json", file.WithTrimBOM())
    cfg, err := confstore.Load[AppConf](p, codec.JsonCodec())
    if err != nil { panic(err) }
    fmt.Printf("%+v\n", *cfg)
}
```

## Providers

- `provider/file` — load from filesystem or a custom `fs.FS`.
  - Options:
    - `file.WithFS(fsys fs.FS)`
    - `file.WithExpandEnv()` — expand env vars in the path
    - `file.WithTrimBOM()` — trim UTF-8 BOM

- `provider/http` — fetch from HTTP(S).
  - Options:
    - `http.WithTimeout(d time.Duration)` — client-level timeout for the internal client
    - `http.WithClient(c *http.Client)`
    - `http.WithMethod(m string)`
    - `http.WithHeader(key, value string)` / `http.WithHeaders(h http.Header)`
    - `http.WithMaxBodySize(n int64)` — limit response body size (bytes)

### HTTP example

```go
srv := httptest.NewServer(nethttp.HandlerFunc(func(w nethttp.ResponseWriter, r *nethttp.Request) {
    w.Header().Set("Content-Type", "application/json")
    _, _ = w.Write([]byte(`{"addr":"0.0.0.0:8080","mode":"prod"}`))
}))
defer srv.Close()

import confhttp "github.com/go-sphere/confstore/provider/http"

p := confhttp.New(srv.URL,
    confhttp.WithHeader("Accept", "application/json"),
    confhttp.WithMaxBodySize(1<<20), // 1MB
)
cfg, err := confstore.Load[AppConf](p, codec.JsonCodec())
```

## ExpandEnv Adapter

Wrap any provider to expand environment variables inside the raw bytes (text configs):

```go
import (
    "github.com/go-sphere/confstore/provider"
    "github.com/go-sphere/confstore/provider/file"
)

wrapped := provider.NewExpandEnv(file.New("./config.json"))
```

## Codecs

- `codec.JsonCodec()` — JSON via stdlib
- `codec.FallbackCodecGroup` — try multiple codecs in order

```go
group := codec.NewCodecGroup(codec.JsonCodec() /*, yamlCodec, tomlCodec, ...*/)
```

## Notes

- Errors from the HTTP provider include method and URL. Non-2xx statuses report the full status string.
- When `WithMaxBodySize` is set, bodies exceeding the limit return `http.ErrBodyTooLarge`.
- Prefer controlling request deadlines with `context.Context` (e.g., `context.WithTimeout`). By default the HTTP client has no timeout; if needed, `provider.WithTimeout` configures a client-level timeout.

## License

**confstore** is released under the MIT license. See [LICENSE](LICENSE) for details.
