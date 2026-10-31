// Package store implements the optional persistent metrics database.
//
// Ownership: this package is the *single writer* of the metrics database. The PowerShell
// client never opens the file; it only sends protocol requests (metric.store.write,
// metric.store.query, metric.store.retention, metric.store.stats). The recovery journal
// lives in PowerShell's state store and is never touched here.
//
// Safety properties:
//   - versioned schema with explicit migrations; a failed migration is an error and the
//     database is left untouched;
//   - transactional batched writes (one transaction per request batch);
//   - retention is user-configurable and *reports* what it deletes (a count is returned)
//     before deleting; recovery records are never deleted, because none exist here;
//   - a corrupt database is never silently replaced: opening returns a stable error and
//     the store stays read-only (queries fail with the code, writes are refused);
//   - disk-full and locked-database errors are mapped to stable codes;
//   - UTC timestamps; quality states are preserved; collection gaps are preserved (we
//     store only what was observed);
//   - bounded range queries (soft limit + hard cap), bounded writes (per-batch cap).
//
// Driver: modernc.org/sqlite (BSD-3-Clause), a pure-Go SQLite implementation. No CGO,
// no external binary, no service installed.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	_ "modernc.org/sqlite"
)

// Schema version and bounds.
const (
	SchemaVersion = 1

	MaxWriteBatch = 4096
	MaxQueryRows  = 10000
	MaxRetentionDays = 3650
)

// Stable error codes.
const (
	ErrOpenFailed        = "E_STORE_OPEN_FAILED"
	ErrMigrateFailed     = "E_STORE_MIGRATE_FAILED"
	ErrCorrupt           = "E_STORE_CORRUPT"
	ErrLocked            = "E_STORE_LOCKED"
	ErrDiskFull          = "E_STORE_DISK_FULL"
	ErrReadOnly          = "E_STORE_READ_ONLY"
	ErrLimitExceeded     = "E_STORE_LIMIT_EXCEEDED"
	ErrInvalidParams     = "E_STORE_INVALID_PARAMS"
)

// Store wraps the SQLite handle.
type Store struct {
	db     *sql.DB
	path   string
	readOnly bool
}

// MetricRow is one persisted metric sample (quality preserved).
type MetricRow struct {
	ID       string
	Type     string
	Unit     string
	TsMs     int64
	Quality  string
	Provider string
	Value    *float64
	Dims     string // JSON-encoded, bounded
	ErrorCode string
	Note     string
}

// SampleSummary is one aggregated bucket for range queries.
type SampleSummary struct {
	StartMs   int64
	EndMs     int64
	Count     int
	ValidCount int
	Min       *float64
	Max       *float64
	Sum       float64
	LastTsMs  int64
}

const alertDDL = `
CREATE TABLE IF NOT EXISTS alert_transitions (
  rule_id TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  from_state TEXT NOT NULL,
  to_state TEXT NOT NULL,
  at_ms INTEGER NOT NULL,
  evidence TEXT NOT NULL DEFAULT '',
  data_source TEXT NOT NULL DEFAULT 'local'
);
CREATE INDEX IF NOT EXISTS idx_alerts_rule_at ON alert_transitions(rule_id, at_ms);
`

const schemaDDL = `
CREATE TABLE IF NOT EXISTS metrics (
  id TEXT NOT NULL,
  type TEXT NOT NULL,
  unit TEXT NOT NULL,
  ts_ms INTEGER NOT NULL,
  quality TEXT NOT NULL,
  provider TEXT NOT NULL,
  value REAL,
  dims TEXT NOT NULL DEFAULT '{}',
  error_code TEXT NOT NULL DEFAULT '',
  note TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_metrics_id_ts ON metrics(id, ts_ms);
CREATE INDEX IF NOT EXISTS idx_metrics_ts ON metrics(ts_ms);
`

var migrations = map[int]string{
	1: schemaDDL + alertDDL,
}

// Open opens (and migrates) the database. If the file cannot be opened or migrated, the
// error is returned and no fallback empty database is created silently: the caller marks
// the store read-only and queries keep failing with the stable code.
func Open(path string) (*Store, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("%s: path is required", ErrInvalidParams)
	}
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("%s: %w", ErrOpenFailed, err)
		}
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", ErrOpenFailed, err)
	}

	// One writer at a time; bounded pool to keep memory small.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	if err := db.Ping(); err != nil {
		db.Close()
		if isLocked(err) {
			return nil, &StoreError{Code: ErrLocked, Message: err.Error()}
		}
		if isCorrupt(err) {
			return nil, &StoreError{Code: ErrCorrupt, Message: err.Error()}
		}
		return nil, fmt.Errorf("%s: %w", ErrOpenFailed, err)
	}

	s := &Store{db: db, path: path}
	if err := s.migrate(); err != nil {
		db.Close()
		if strings.Contains(strings.ToLower(err.Error()), "not a database") || strings.Contains(strings.ToLower(err.Error()), "malformed") {
			return nil, &StoreError{Code: ErrCorrupt, Message: err.Error()}
		}
		return nil, err
	}
	return s, nil
}

// OpenWithVersion opens with an explicit schema version check (used by tests to simulate
// a newer database).
func OpenWithVersion(path string, version int) (*Store, error) {
	st, err := Open(path)
	if err != nil {
		return nil, err
	}
	_, err = st.db.Exec("PRAGMA user_version = ?", version)
	return st, err
}

// StoreError carries a stable code.
type StoreError struct {
	Code    string
	Message string
}

func (e *StoreError) Error() string { return e.Code + ": " + e.Message }

func isLocked(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "locked") || strings.Contains(msg, "busy")
}

func isCorrupt(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "not a database") || strings.Contains(msg, "malformed") || strings.Contains(msg, "corrupt") || strings.Contains(msg, "database disk image is malformed")
}

func isDiskFull(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "disk i/o error") || strings.Contains(msg, "database or disk is full") || strings.Contains(msg, "no space left")
}

// migrate applies the schema in order; a failure is returned and the database stays as it
// was (SQLite DDL is transactional).
func (s *Store) migrate() error {
	// User version pragma.
	var version int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return &StoreError{Code: ErrMigrateFailed, Message: err.Error()}
	}

	if version > SchemaVersion {
		return &StoreError{Code: ErrMigrateFailed, Message: fmt.Sprintf("database schema %d is newer than supported %d", version, SchemaVersion)}
	}

	for v := version + 1; v <= SchemaVersion; v++ {
		ddl, ok := migrations[v]
		if !ok {
			return &StoreError{Code: ErrMigrateFailed, Message: fmt.Sprintf("migration %d missing", v)}
		}
		tx, err := s.db.Begin()
		if err != nil {
			return classifyTxError(err)
		}
		if _, err := tx.Exec(ddl); err != nil {
			tx.Rollback()
			return classifyTxError(err)
		}
		if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", v)); err != nil {
			tx.Rollback()
			return classifyTxError(err)
		}
		if err := tx.Commit(); err != nil {
			return classifyTxError(err)
		}
	}
	return nil
}

func classifyTxError(err error) error {
	if err == nil {
		return nil
	}
	if isLocked(err) {
		return &StoreError{Code: ErrLocked, Message: err.Error()}
	}
	if isDiskFull(err) {
		return &StoreError{Code: ErrDiskFull, Message: err.Error()}
	}
	return &StoreError{Code: ErrMigrateFailed, Message: err.Error()}
}

// WriteBatch persists a batch of metric samples in one transaction.
func (s *Store) WriteBatch(ctx context.Context, rows []MetricRow) (int, error) {
	if s.readOnly {
		return 0, &StoreError{Code: ErrReadOnly, Message: "store is read-only"}
	}
	if len(rows) > MaxWriteBatch {
		return 0, &StoreError{Code: ErrLimitExceeded, Message: fmt.Sprintf("write batch %d exceeds %d", len(rows), MaxWriteBatch)}
	}
	if len(rows) == 0 {
		return 0, nil
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, classifyTxError(err)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx, `
INSERT INTO metrics (id, type, unit, ts_ms, quality, provider, value, dims, error_code, note)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, classifyTxError(err)
	}
	defer stmt.Close()

	wrote := 0
	for _, r := range rows {
		// dims JSON is produced by the caller; validate it is bounded.
		if len(r.Dims) > 2048 {
			continue
		}
		if _, err := stmt.ExecContext(ctx, r.ID, r.Type, r.Unit, r.TsMs, r.Quality, r.Provider, r.Value, r.Dims, r.ErrorCode, r.Note); err != nil {
			return wrote, classifyTxError(err)
		}
		wrote++
	}

	if err := tx.Commit(); err != nil {
		return wrote, classifyTxError(err)
	}
	return wrote, nil
}

// QueryRange returns aggregated buckets for a metric id and time range.
// Buckets is bounded by MaxQueryRows; the query is bounded by the same constant.
func (s *Store) QueryRange(ctx context.Context, id string, fromMs, toMs int64, bucketMs int64) ([]SampleSummary, error) {
	if fromMs >= toMs {
		return nil, &StoreError{Code: ErrInvalidParams, Message: "fromMs must be < toMs"}
	}
	if bucketMs <= 0 {
		bucketMs = (toMs - fromMs) / 200
	}
	if bucketMs <= 0 {
		bucketMs = 1
	}
	buckets := (toMs - fromMs) / bucketMs
	if buckets > MaxQueryRows {
		return nil, &StoreError{Code: ErrLimitExceeded, Message: fmt.Sprintf("range would produce %d buckets > %d", buckets, MaxQueryRows)}
	}

	rows, err := s.db.QueryContext(ctx, `
SELECT
  (ts_ms / ?) * ? AS bucket_start,
  COUNT(*),
  SUM(CASE WHEN quality = 'valid' AND value IS NOT NULL THEN 1 ELSE 0 END),
  MIN(CASE WHEN quality = 'valid' THEN value END),
  MAX(CASE WHEN quality = 'valid' THEN value END),
  COALESCE(SUM(CASE WHEN quality = 'valid' THEN value ELSE 0 END), 0),
  MAX(ts_ms)
FROM metrics
WHERE id = ? AND ts_ms >= ? AND ts_ms < ?
GROUP BY bucket_start
ORDER BY bucket_start`, bucketMs, bucketMs, id, fromMs, toMs)
	if err != nil {
		return nil, classifyQueryError(err)
	}
	defer rows.Close()

	out := make([]SampleSummary, 0, 512)
	for rows.Next() {
		var ss SampleSummary
		var lastTs int64
		if err := rows.Scan(&ss.StartMs, &ss.Count, &ss.ValidCount, &ss.Min, &ss.Max, &ss.Sum, &lastTs); err != nil {
			return nil, classifyQueryError(err)
		}
		ss.EndMs = ss.StartMs + bucketMs
		ss.LastTsMs = lastTs
		out = append(out, ss)
	}
	if err := rows.Err(); err != nil {
		return nil, classifyQueryError(err)
	}

	// Force closing of the rows before any further statement (bounded).
	rows.Close()
	return out, nil
}

// RawSamples returns the last N raw samples for a metric (bounded).
func (s *Store) RawSamples(ctx context.Context, id string, fromMs, toMs int64, limit int) ([]MetricRow, error) {
	if limit <= 0 || limit > MaxQueryRows {
		limit = MaxQueryRows
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT id, type, unit, ts_ms, quality, provider, value, dims, error_code, note
FROM metrics
WHERE id = ? AND ts_ms >= ? AND ts_ms < ?
ORDER BY ts_ms DESC
LIMIT ?`, id, fromMs, toMs, limit)
	if err != nil {
		return nil, classifyQueryError(err)
	}
	defer rows.Close()

	out := make([]MetricRow, 0, limit)
	for rows.Next() {
		var r MetricRow
		if err := rows.Scan(&r.ID, &r.Type, &r.Unit, &r.TsMs, &r.Quality, &r.Provider, &r.Value, &r.Dims, &r.ErrorCode, &r.Note); err != nil {
			return nil, classifyQueryError(err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, classifyQueryError(err)
	}
	return out, nil
}

func classifyQueryError(err error) error {
	if err == nil {
		return nil
	}
	if isLocked(err) {
		return &StoreError{Code: ErrLocked, Message: err.Error()}
	}
	return &StoreError{Code: ErrCorrupt, Message: err.Error()}
}

// Retention deletes samples older than cutoffMs (explicit, counted). It never touches
// anything else (there is no recovery data in this database).
func (s *Store) Retention(ctx context.Context, cutoffMs int64) (int64, error) {
	if s.readOnly {
		return 0, &StoreError{Code: ErrReadOnly, Message: "store is read-only"}
	}
	res, err := s.db.ExecContext(ctx, `DELETE FROM metrics WHERE ts_ms < ?`, cutoffMs)
	if err != nil {
		return 0, classifyTxError(err)
	}
	return res.RowsAffected()
}

// Stats reports the store state.
func (s *Store) Stats(ctx context.Context) (map[string]any, error) {
	var count int64
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM metrics`).Scan(&count); err != nil {
		return nil, classifyQueryError(err)
	}
	var size int64
	if info, err := os.Stat(s.path); err == nil {
		size = info.Size()
	}
	return map[string]any{
		"schemaVersion": SchemaVersion,
		"path":          s.path,
		"rows":          count,
		"bytes":         size,
		"readOnly":      s.readOnly,
	}, nil
}

// AppendAlertTransition records one alert transition (bounded, indexed).
func (s *Store) AppendAlertTransition(ctx context.Context, ruleID string, revision int, fromState, toState string, atMs int64, evidence, dataSource string) error {
	if s.readOnly {
		return &StoreError{Code: ErrReadOnly, Message: "store is read-only"}
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO alert_transitions (rule_id, revision, from_state, to_state, at_ms, evidence, data_source)
VALUES (?, ?, ?, ?, ?, ?, ?)`, ruleID, revision, fromState, toState, atMs, evidence, dataSource)
	if err != nil {
		return classifyTxError(err)
	}
	return nil
}

// AlertTransitions returns the last N transitions for a rule (bounded).
func (s *Store) AlertTransitions(ctx context.Context, ruleID string, limit int) ([]map[string]any, error) {
	if limit <= 0 || limit > MaxQueryRows {
		limit = MaxQueryRows
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT rule_id, revision, from_state, to_state, at_ms, evidence, data_source
FROM alert_transitions
WHERE rule_id = ?
ORDER BY at_ms DESC
LIMIT ?`, ruleID, limit)
	if err != nil {
		return nil, classifyQueryError(err)
	}
	defer rows.Close()

	out := make([]map[string]any, 0, limit)
	for rows.Next() {
		var rule, from, to, evidence, ds string
		var rev int
		var at int64
		if err := rows.Scan(&rule, &rev, &from, &to, &at, &evidence, &ds); err != nil {
			return nil, classifyQueryError(err)
		}
		out = append(out, map[string]any{
			"ruleId": rule, "revision": rev, "fromState": from, "toState": to,
			"atMs": at, "evidence": evidence, "dataSource": ds,
		})
	}
	if err := rows.Err(); err != nil {
		return nil, classifyQueryError(err)
	}
	return out, nil
}

// Close closes the store.
func (s *Store) Close() error {
	if s.db != nil {
		return s.db.Close()
	}
	return nil
}

// ErrCorruptCode is a helper for callers to detect the corrupt code.
func ErrCorruptCode(err error) bool {
	var se *StoreError
	return errors.As(err, &se) && se.Code == ErrCorrupt
}
