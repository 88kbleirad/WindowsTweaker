package exporter

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestDisabledByDefaultAndLoopback(t *testing.T) {
	e, err := New(Options{Port: 39091})
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	// Before Start: no listener. No scrape possible.
	if e.server != nil {
		t.Fatal("exporter must be disabled by default")
	}
	if err := e.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer e.Stop(context.Background())

	e.Set([]ExportMetric{
		{Name: "wt_cpu_utilization_percent", Type: "gauge", Value: 42.0, Labels: map[string]string{"host": "h1"}},
	}, time.Now(), 10*time.Second)

	resp, err := http.Get("http://127.0.0.1:39091/metrics")
	if err != nil {
		t.Fatalf("scrape: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	text := string(body)

	// Bounded sample present.
	if !strings.Contains(text, "wt_collector_freshness_seconds") {
		t.Fatalf("freshness metric missing: %s", text)
	}
	for _, bad := range []string{"/home/", "token", "operationId", "sessionId"} {
		if strings.Contains(text, bad) {
			t.Fatalf("exposed forbidden label/value: %s", bad)
		}
	}
}

func TestSetAndStaleRemoval(t *testing.T) {
	e, _ := New(Options{Port: 39092})
	_ = e.Start()
	defer e.Stop(context.Background())

	now := time.Now()
	e.Set([]ExportMetric{
		{Name: "wt_cpu_utilization_percent", Type: "gauge", Value: 42.0, Labels: map[string]string{"host": "h1"}},
		{Name: "wt_ops_total", Type: "counter", Value: 7.0, Labels: map[string]string{}},
	}, now, 10*time.Second)

	resp, _ := http.Get("http://127.0.0.1:39092/metrics")
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	text := string(body)
	if !strings.Contains(text, "wt_cpu_utilization_percent") || !strings.Contains(text, "wt_ops_total 7") {
		t.Fatalf("expected metrics in scrape:\n%s", text)
	}

	// Stale: set with old timestamp beyond staleAfter; series must disappear.
	e.Set([]ExportMetric{
		{Name: "wt_cpu_utilization_percent", Type: "gauge", Value: 99.0, Labels: map[string]string{"host": "h1"}},
	}, now.Add(-2*time.Minute), 10*time.Second)

	resp2, _ := http.Get("http://127.0.0.1:39092/metrics")
	body2, _ := io.ReadAll(resp2.Body)
	resp2.Body.Close()
	if strings.Contains(string(body2), "wt_cpu_utilization_percent") {
		t.Fatal("stale series must be removed, not presented as fresh")
	}
}

func TestPortConflictReported(t *testing.T) {
	a, err := New(Options{Port: 39093})
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	if err := a.Start(); err != nil {
		t.Fatalf("start a: %v", err)
	}
	defer a.Stop(context.Background())

	b, err := New(Options{Port: 39093})
	if err != nil {
		t.Fatalf("new b: %v", err)
	}
	if err := b.Start(); err == nil {
		t.Fatal("same port must fail to bind")
	} else if !strings.Contains(err.Error(), "listener failed") {
		t.Fatalf("unexpected error: %v", err)
	}
}
