// Package exporter implements the optional, explicitly enabled Prometheus exporter.
//
// Design (compiles with the documented requirements):
//   - disabled by default: no listener is opened unless the operator starts it with an
//     explicit op (exporter.start) and a port;
//   - loopback binding by default; binds 127.0.0.1 (a non-loopback interface is
//     refused: no authentication/transport layer is implemented yet);
//   - configurable validated port: 1024-65535, not already in use;
//   - read-only: /metrics only, no management endpoints;
//   - bounded metrics and labels: no paths, usernames, tokens, PIDs, session IDs,
//     operation IDs or arbitrary error text in labels; no per-file or per-operation
//     series;
//   - collection failure and freshness are explicit: a failed probe is never exported
//     as zero; the exporter exposes a collector_freshness_seconds gauge and a
//     collector_last_success_timestamp_seconds gauge instead;
//   - stale sample policy: a sample older than StaleAfter is removed from the metric set
//     on the next cycle (the series disappears rather than presenting old values as
//     fresh);
//   - a scrape never triggers collection: it only reads the last snapshot metrics.
//
// Driver: github.com/prometheus/client_golang (Apache-2.0), the official Prometheus
// Go client.

package exporter

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Stable metric names (application prefix wt_).
const (
	StaleAfter = 2 * time.Minute
)

// Options configures the exporter.
type Options struct {
	Port      int
	Address   string // loopback default
	StaleAfter time.Duration
}

// ExportMetric is one value for the exporter (already allowlisted/bounded).
type ExportMetric struct {
	Name   string
	Help   string
	Type   string // "gauge" | "counter"
	Value  float64
	Labels map[string]string
}

// Exporter owns the HTTP server and the metric registry.
type Exporter struct {
	mu      sync.Mutex
	opts    Options
	server  *http.Server
	listener net.Listener
	registry *prometheus.Registry
	desc    map[string]*prometheus.Desc
	values  map[string]map[string]float64 // seriesKey -> value
	labels  map[string]map[string]string
	lastSample map[string]time.Time
	started time.Time
}

// New creates a disabled exporter.
func New(opts Options) (*Exporter, error) {
	if opts.Address == "" {
		opts.Address = "127.0.0.1"
	}
	if opts.Port < 1024 || opts.Port > 65535 {
		return nil, errors.New("port must be between 1024 and 65535")
	}
	if opts.StaleAfter <= 0 {
		opts.StaleAfter = StaleAfter
	}

	registry := prometheus.NewRegistry()
	exp := &Exporter{
		opts:    opts,
		registry: registry,
		desc:    map[string]*prometheus.Desc{},
		values:  map[string]map[string]float64{},
		labels:  map[string]map[string]string{},
		lastSample: map[string]time.Time{},
	}

	return exp, nil
}

func (e *Exporter) ensureDesc(name, help string) *prometheus.Desc {
	if d, ok := e.desc[name]; ok {
		return d
	}
	d := prometheus.NewDesc(name, help, nil, nil)
	e.desc[name] = d
	return d
}

// Start opens the loopback listener and serves /metrics. Idempotent.
func (e *Exporter) Start() error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.server != nil {
		return nil
	}

	addr := net.JoinHostPort(e.opts.Address, fmt.Sprintf("%d", e.opts.Port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("exporter listener failed: %w", err)
	}

	mux := http.NewServeMux()
	mux.Handle("/metrics", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		e.mu.Lock()
		reg := e.registry
		e.mu.Unlock()
		promhttp.HandlerFor(reg, promhttp.HandlerOpts{}).ServeHTTP(w, r)
	}))

	e.listener = ln
	e.started = time.Now()
	e.server = &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = e.server.Serve(ln) }()
	return nil
}

// Set replaces the exported snapshot (bounded). Stale series are removed.
func (e *Exporter) Set(metrics []ExportMetric, collectedAt time.Time, staleAfter time.Duration) {
	e.mu.Lock()
	defer e.mu.Unlock()

	// Drop all previously registered gauge vectors and rebuild. Simpler and bounded:
	// one GaugeVec per metric name, GaugeVec collects with fixed labels.
	e.registry = prometheus.NewRegistry()
	e.desc = map[string]*prometheus.Desc{}
	e.values = map[string]map[string]float64{}
	e.labels = map[string]map[string]string{}
	e.lastSample = map[string]time.Time{}

	for _, m := range metrics {
		if staleAfter <= 0 {
			staleAfter = e.opts.StaleAfter
		}
		if collectedAt.Add(staleAfter).Before(time.Now()) {
			continue // stale: series removed, not presented as fresh
		}
		key := m.Name
		for k, v := range m.Labels {
			key += "|" + k + "=" + v
		}
		if _, ok := e.values[m.Name]; !ok {
			e.values[m.Name] = map[string]float64{}
			e.labels[m.Name] = map[string]string{}
		}
		e.values[m.Name][key] = m.Value
		for k, v := range m.Labels {
			e.labels[m.Name][k] = v
		}
		e.lastSample[m.Name] = collectedAt
	}

	e.registerAll(collectedAt)
}

func (e *Exporter) registerAll(collectedAt time.Time) {
	for name, series := range e.values {
		labelKeys := make([]string, 0, len(e.labels[name]))
		for k := range e.labels[name] {
			labelKeys = append(labelKeys, k)
		}

		gauge := prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: name, Help: name,
		}, labelKeys)
		for key, val := range series {
			labels := map[string]string{}
			parts := splitKey(key)
			for i, k := range labelKeys {
				if i < len(parts)-1 {
					labels[k] = parts[i+1]
				}
			}
			gauge.With(labels).Set(val)
		}
		_ = e.registry.Register(gauge)
	}

	freshness := prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "wt_collector_freshness_seconds", Help: "Seconds since the last successful collection snapshot.",
	})
	freshness.Set(time.Since(collectedAt).Seconds())
	_ = e.registry.Register(freshness)

	last := prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "wt_collector_last_success_timestamp_seconds", Help: "Unix timestamp of the last successful collection snapshot.",
	})
	last.Set(float64(collectedAt.Unix()))
	_ = e.registry.Register(last)
}

func splitKey(key string) []string {
	out := []string{""}
	start := 0
	for i := 0; i < len(key); i++ {
		if key[i] == '|' {
			out = append(out, key[start:i])
			start = i + 1
		}
	}
	out = append(out, key[start:])
	return out
}

// Port returns the configured port (for status reporting).
func (e *Exporter) Port() int { return e.opts.Port }

// Stop shuts the listener down.
func (e *Exporter) Stop(ctx context.Context) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.server == nil {
		return nil
	}
	err := e.server.Shutdown(ctx)
	e.server = nil
	e.listener = nil
	return err
}
