package metric

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestSnapshotContractShape(t *testing.T) {
	s := New()
	snap, err := s.Snapshot(context.Background(), "fast")
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	if snap.Scope != "fast" {
		t.Fatalf("scope: %s", snap.Scope)
	}
	if snap.SampledAtMs <= 0 {
		t.Fatal("sampledAtMs missing")
	}
	if len(snap.Metrics) == 0 {
		t.Fatal("no metrics")
	}
	seen := map[string]bool{}
	for _, m := range snap.Metrics {
		key := m.ID + "|" + strings.Join(sortedDimValues(m.Dims), ",")
		if seen[key] {
			t.Fatalf("duplicate metric %s with same dimensions", key)
		}
		seen[key] = true
		if m.TsMs <= 0 || m.Provider == "" || m.Unit == "" {
			t.Fatalf("bad metric shape: %+v", m)
		}
		if m.Quality != QualityValid && m.Quality != QualityUnavailable && m.Quality != QualityError {
			t.Fatalf("bad quality: %s", m.Quality)
		}
		if len(m.Dims) > MaxDimsPerMetric {
			t.Fatalf("too many dims on %s", m.ID)
		}
	}
}

func TestCpuUtilizationNeedsBaselineAndThenValid(t *testing.T) {
	s := New()
	first, err := s.Snapshot(context.Background(), "fast")
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	var cpu *Metric
	for i := range first.Metrics {
		if first.Metrics[i].ID == "host.cpu.utilization" {
			cpu = &first.Metrics[i]
		}
	}
	if cpu == nil {
		t.Fatal("no cpu metric")
	}
	if cpu.Quality != QualityUnavailable {
		t.Fatalf("first sample must be unavailable, got %s", cpu.Quality)
	}

	time.Sleep(15 * time.Millisecond)
	second, err := s.Snapshot(context.Background(), "fast")
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	for i := range second.Metrics {
		if second.Metrics[i].ID == "host.cpu.utilization" {
			cpu = &second.Metrics[i]
		}
	}
	if cpu.Quality != QualityValid {
		t.Fatalf("second sample must be valid, got %s", cpu.Quality)
	}
	if cpu.Value == nil {
		t.Fatal("cpu value missing")
	}
	if *cpu.Value < 0 || *cpu.Value > 100 {
		t.Fatalf("cpu utilization out of range: %f", *cpu.Value)
	}
}

func TestCounterResetProducesNoNegativeRateMaterial(t *testing.T) {
	// Raw counters are returned; resets must not manufacture negative material.
	s := New()
	snap, _ := s.Snapshot(context.Background(), "fast")
	for _, m := range snap.Metrics {
		if m.Type == TypeCounter {
			if m.Value == nil {
				t.Fatalf("counter %s must carry a value", m.ID)
			}
			if *m.Value < 0 {
				t.Fatalf("counter %s negative", m.ID)
			}
		}
	}
}

func TestMissingDataNeverZero(t *testing.T) {
	// A provider failure yields error-quality metrics, never zero values.
	s := New()
	snap, _ := s.Snapshot(context.Background(), "fast")
	for _, m := range snap.Metrics {
		if m.Quality == QualityError {
			if m.Value != nil {
				t.Fatalf("error metric %s must not carry a zeroed value", m.ID)
			}
			if m.ErrorCode == "" {
				t.Fatalf("error metric %s must carry a stable code", m.ID)
			}
		}
	}
}

func TestNetworkDimsBounded(t *testing.T) {
	s := New()
	snap, _ := s.Snapshot(context.Background(), "fast")
	for _, m := range snap.Metrics {
		if strings.HasPrefix(m.ID, "host.net.") {
			if len(m.Dims) > 1 {
				t.Fatalf("net metric %s has unexpected dims: %v", m.ID, m.Dims)
			}
		}
	}
}


func sortedDimValues(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	for i := range keys {
		for j := i + 1; j < len(keys); j++ {
			if keys[j] < keys[i] {
				keys[i], keys[j] = keys[j], keys[i]
			}
		}
	}
	sorted := make([]string, 0, len(m))
	for _, k := range keys {
		sorted = append(sorted, k+"="+m[k])
	}
	return sorted
}
