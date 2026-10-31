// WindowsTweaker background worker.
//
// A separate Go module on purpose: the PowerShell module stays usable without a Go
// toolchain, and the worker stays buildable (and testable) without PowerShell.
//
// The worker has third-party requirements (SQLite for the store, the Prometheus client
// for the optional exporter). Every module that ends up linked into the shipped binary is
// listed with its licence in THIRD-PARTY-NOTICES.md, and the verbatim texts live under
// licenses/go-worker/. `go list -m all` and `go mod verify` both see them.
module wintweaker.dev/worker

go 1.26.0

require modernc.org/sqlite v1.34.0

require (
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
	github.com/prometheus/client_model v0.6.3 // indirect
	github.com/prometheus/common v0.72.0 // indirect
	github.com/prometheus/procfs v0.22.0 // indirect
	google.golang.org/protobuf v1.36.12 // indirect
)

require (
	github.com/dustin/go-humanize v1.0.1 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/hashicorp/golang-lru/v2 v2.0.7 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/ncruces/go-strftime v0.1.9 // indirect
	github.com/prometheus/client_golang v1.25.0
	github.com/remyoudompheng/bigfft v0.0.0-20230129092748-24d4a6f8daec // indirect
	golang.org/x/sys v0.48.0 // indirect
	modernc.org/gc/v3 v3.0.0-20240107210532-573471604cb6 // indirect
	modernc.org/libc v1.55.3 // indirect
	modernc.org/mathutil v1.6.0 // indirect
	modernc.org/memory v1.8.0 // indirect
	modernc.org/strutil v1.2.0 // indirect
	modernc.org/token v1.1.0 // indirect
)
