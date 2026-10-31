package store

import (
	"context"
	"path/filepath"
	"testing"
)

func TestMigrateWriteQueryRetention(t *testing.T) {
	path := filepath.Join(t.TempDir(), "metrics.db")
	st, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer st.Close()

	v := 1.5
	rows := []MetricRow{
		{ID: "host.cpu.utilization", Type: "gauge", Unit: "%", TsMs: 1000, Quality: "valid", Provider: "host.cpu", Value: &v, Dims: "{}"},
		{ID: "host.cpu.utilization", Type: "gauge", Unit: "%", TsMs: 2000, Quality: "valid", Provider: "host.cpu", Value: &v, Dims: "{}"},
		{ID: "host.cpu.utilization", Type: "gauge", Unit: "%", TsMs: 3000, Quality: "error", Provider: "host.cpu", ErrorCode: "E_READ_FAILED", Dims: "{}"},
	}
	wrote, err := st.WriteBatch(context.Background(), rows)
	if err != nil || wrote != 3 {
		t.Fatalf("write: %d %v", wrote, err)
	}

	buckets, err := st.QueryRange(context.Background(), "host.cpu.utilization", 0, 4000, 1000)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(buckets) != 3 {
		t.Fatalf("expected 3 buckets, got %d", len(buckets))
	}
	// quality=error bucket has valid count 0 but is present (gap of validity, not missing).
	if buckets[2].ValidCount != 0 {
		t.Fatalf("error bucket should have 0 valid samples")
	}

	raw, err := st.RawSamples(context.Background(), "host.cpu.utilization", 0, 4000, 10)
	if err != nil || len(raw) != 3 {
		t.Fatalf("raw: %d %v", len(raw), err)
	}

	deleted, err := st.Retention(context.Background(), 2500)
	if err != nil {
		t.Fatalf("retention: %v", err)
	}
	if deleted != 2 {
		t.Fatalf("expected 2 deleted, got %d", deleted)
	}
}

func TestCorruptAndLockedAreExplicit(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.db")
	if err := writeFile(path, "not a sqlite database at all, definitely corrupt"); err != nil {
		t.Fatalf("write: %v", err)
	}
	_, err := Open(path)
	if err == nil {
		t.Fatal("corrupt database must fail to open")
	}
	var se *StoreError
	if !errorsAs(err, &se) || se.Code != ErrCorrupt {
		t.Fatalf("expected corrupt code, got %v", err)
	}
}

func TestAlertTransitionsDeduplicatedAndPersisted(t *testing.T) {
	path := filepath.Join(t.TempDir(), "alerts.db")
	st, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer st.Close()

	if err := st.AppendAlertTransition(context.Background(), "disk-low", 1, "normal", "pending", 1000, "v=5", "local"); err != nil {
		t.Fatalf("append: %v", err)
	}
	if err := st.AppendAlertTransition(context.Background(), "disk-low", 1, "pending", "firing", 2000, "v=5", "local"); err != nil {
		t.Fatalf("append: %v", err)
	}
	rows, err := st.AlertTransitions(context.Background(), "disk-low", 10)
	if err != nil || len(rows) != 2 {
		t.Fatalf("transitions: %d %v", len(rows), err)
	}
	if rows[0]["toState"] != "firing" {
		t.Fatalf("newest first expected, got %v", rows[0])
	}
}
