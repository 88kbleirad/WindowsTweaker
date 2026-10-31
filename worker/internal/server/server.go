// Package server implements the worker's request loop: one reader, one serialised writer,
// bounded concurrent jobs, cooperative cancellation and a bounded shutdown.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"

	"wintweaker.dev/worker/internal/exporter"
	"wintweaker.dev/worker/internal/metric"
	"wintweaker.dev/worker/internal/protocol"
	"wintweaker.dev/worker/internal/store"
	"wintweaker.dev/worker/internal/scan"
)

// Info is the build information reported in the handshake.
type Info struct {
	Worker  string
	Version string
	OS      string
	Arch    string
}

// Capabilities lists exactly what this build implements. A capability that is not listed must
// not be attempted by the client, and a capability that is listed must work.
var Capabilities = []string{"scan.directory", "scan.children", "metric.snapshot"}

const (
	// MaxConcurrentJobs bounds how many requests run at once.
	MaxConcurrentJobs = 4
	// ShutdownGrace bounds how long a shutdown waits for running jobs.
	ShutdownGrace = 2 * time.Second
	// JobTimeout bounds one scan when the client does not send a timeout.
	DefaultJobTimeout = 300 * time.Second
	ProgressEvery     = 250 * time.Millisecond
)

// Server is one worker process.
type Server struct {
	input  *protocol.Reader
	output *protocol.Writer
	logger *log.Logger
	info   Info
	metrics *metric.Snapshotter
	metricsStore *store.Store
	metricsExporter *exporter.Exporter

	mu   sync.Mutex
	jobs map[string]*job

	closed  bool
	planner sync.WaitGroup
}

type job struct {
	id      string
	op      string
	cancel  context.CancelFunc
	done    chan struct{}
	stopped bool
}

// New builds a server around the given streams. Diagnostics go to the logger (stderr); the
// writer is the only thing that touches stdout.
func New(input io.Reader, output io.Writer, logger *log.Logger, info Info) *Server {
	return &Server{
		input:  protocol.NewReader(input),
		output: protocol.NewWriter(output),
		logger: logger,
		info:   info,
		metrics: metric.New(),
		metricsStore: nil,
		jobs:   make(map[string]*job),
	}
}

// Run serves requests until shutdown, EOF or an unrecoverable protocol error.
func (server *Server) Run(ctx context.Context) error {
	server.logger.Printf("worker %s %s starting (protocol %d, capabilities %v)", server.info.Version, server.info.OS+"/"+server.info.Arch, protocol.Version, Capabilities)

	for {
		line, err := server.input.ReadLine()
		if err != nil {
			if errors.Is(err, protocol.ErrLineTooLarge) {
				server.writeError("", protocol.CodeTooLarge, fmt.Sprintf("a request line exceeded %d bytes and was discarded", protocol.MaxLineBytes), "")
				continue
			}
			if errors.Is(err, io.EOF) {
				server.logger.Print("stdin closed; stopping")
				server.shutdown("")
				return nil
			}
			return err
		}

		if len(line) == 0 {
			continue
		}

		var request protocol.Request
		if err := json.Unmarshal(line, &request); err != nil {
			// A line that is not JSON cannot carry a usable id, so the error goes out with no
			// id; the client reports it against the stream, not against a request.
			server.writeError("", protocol.CodeBadJSON, "the request was not valid JSON", err.Error())
			continue
		}

		if request.V != protocol.Version {
			server.writeError(request.ID, protocol.CodeProtocolVersion,
				fmt.Sprintf("this worker speaks protocol %d and refuses %d", protocol.Version, request.V), "")
			server.logger.Printf("protocol mismatch: client sent %d; exiting", request.V)
			server.shutdown("")
			return nil
		}

		if request.ID == "" {
			server.writeError("", protocol.CodeInvalidParams, "every request needs an id", "")
			continue
		}

		if err := server.dispatch(ctx, request); err != nil {
			if errors.Is(err, errStop) {
				return nil
			}
			return err
		}
	}
}

// dispatch routes one validated request.
func (server *Server) dispatch(ctx context.Context, request protocol.Request) error {
	switch request.Op {
	case protocol.OpHello:
		return server.output.Write(protocol.Message{Type: protocol.TypeHello, ID: request.ID, Hello: server.hello()})

	case protocol.OpShutdown:
		server.logger.Print("shutdown requested")
		server.writeResult(request.ID, map[string]any{"shutdown": true, "graceMs": ShutdownGrace.Milliseconds()})
		server.shutdown(request.ID)
		// A requested shutdown is a clean stop, not a failure: the sentinel is unwound by Run
		// and reported as exit code 0.
		return errStop

	case protocol.OpCancel:
		var params struct {
			Target string `json:"target"`
		}
		if len(request.Params) > 0 {
			if err := json.Unmarshal(request.Params, &params); err != nil {
				server.writeError(request.ID, protocol.CodeInvalidParams, "cancel needs {\"target\":\"<request id>\"}", err.Error())
				return nil
			}
		}

		state := server.cancel(params.Target)
		return server.output.Write(protocol.Message{
			Type: protocol.TypeCancelled, ID: request.ID,
			Cancelled: &protocol.Cancellation{Ack: true, State: state},
		})

	case protocol.OpScanDir:
		return server.startScan(ctx, request)

	case protocol.OpScanChildren:
		return server.startChildren(ctx, request)

	case protocol.OpMetricSnapshot:
		return server.startMetricSnapshot(ctx, request)

	case protocol.OpStoreWrite:
		return server.handleStoreWrite(ctx, request)
	case protocol.OpStoreQuery:
		return server.handleStoreQuery(ctx, request)
	case protocol.OpStoreRaw:
		return server.handleStoreRaw(ctx, request)
	case protocol.OpStoreRetention:
		return server.handleStoreRetention(ctx, request)
	case protocol.OpStoreStats:
		return server.handleStoreStats(ctx, request)

	case protocol.OpExporterStart:
		return server.handleExporterStart(ctx, request)
	case protocol.OpExporterStop:
		return server.handleExporterStop(ctx, request)
	case protocol.OpExporterStatus:
		return server.handleExporterStatus(ctx, request)

	case protocol.OpStoreAlert:
		return server.handleStoreAlert(ctx, request)
	}

	server.writeError(request.ID, protocol.CodeUnknownOp, "unknown operation", request.Op)
	return nil
}

// hello builds the handshake answer.
func (server *Server) hello() *protocol.Hello {
	return &protocol.Hello{
		Worker:       server.info.Worker,
		Version:      server.info.Version,
		Protocol:     protocol.Version,
		GoVersion:    runtime.Version(),
		OS:           runtime.GOOS,
		Arch:         runtime.GOARCH,
		Capabilities: append([]string{}, Capabilities...),
		Limits: protocol.Limits{
			MaxLineBytes:      protocol.MaxLineBytes,
			MaxErrors:         scan.MaxErrors,
			ScanWorkers:       scan.MaxWorkers,
			MaxScanDepth:      scan.MaxDepth,
			ProgressEveryMS:   int(ProgressEvery / time.Millisecond),
			MaxResultPaths:    scan.MaxLargest + scan.MaxErrors,
			MaxConcurrentJobs: MaxConcurrentJobs,
		},
	}
}

// startScan validates the request, then runs it as a bounded background job.
func (server *Server) startScan(ctx context.Context, request protocol.Request) error {
	var params struct {
		Root        string `json:"root"`
		MaxDepth    int    `json:"maxDepth"`
		FollowLinks bool   `json:"followLinks"`
		Workers     int    `json:"workers"`
	}
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "scan.directory params are not valid JSON", err.Error())
			return nil
		}
	}

	options := scan.Options{
		Root:        params.Root,
		MaxDepth:    params.MaxDepth,
		FollowLinks: params.FollowLinks,
		Workers:     params.Workers,
		Progress: func(snapshot scan.Progress) {
			server.writeProgress(request.ID, snapshot)
		},
	}
	if err := options.Validate(); err != nil {
		server.writeError(request.ID, protocol.CodeInvalidParams, "scan.directory parameters are invalid", err.Error())
		return nil
	}

	server.mu.Lock()
	if server.closed {
		server.mu.Unlock()
		server.writeError(request.ID, protocol.CodeBusy, "the worker is shutting down", "")
		return nil
	}
	if len(server.jobs) >= MaxConcurrentJobs {
		server.mu.Unlock()
		server.writeError(request.ID, protocol.CodeBusy, fmt.Sprintf("at most %d requests run at once", MaxConcurrentJobs), "")
		return nil
	}
	if _, exists := server.jobs[request.ID]; exists {
		server.mu.Unlock()
		server.writeError(request.ID, protocol.CodeInvalidParams, "request id is already in use", "")
		return nil
	}

	timeout := DefaultJobTimeout
	if request.TimeoutMS > 0 {
		timeout = time.Duration(request.TimeoutMS) * time.Millisecond
	}

	jobContext, cancel := context.WithTimeout(ctx, timeout)
	entry := &job{id: request.ID, op: request.Op, cancel: cancel, done: make(chan struct{})}
	server.jobs[request.ID] = entry
	server.planner.Add(1)
	server.mu.Unlock()

	go func() {
		defer server.planner.Done()
		defer close(entry.done)
		defer cancel()

		server.runScan(jobContext, request.ID, options, timeout)

		server.mu.Lock()
		delete(server.jobs, request.ID)
		server.mu.Unlock()
	}()

	return nil
}

// startChildren validates a scan.children request and runs it as a bounded background job.
func (server *Server) startChildren(ctx context.Context, request protocol.Request) error {
	var params struct {
		Root        string `json:"root"`
		FollowLinks bool   `json:"followLinks"`
		Workers     int    `json:"workers"`
	}
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "scan.children params are not valid JSON", err.Error())
			return nil
		}
	}
	if strings.TrimSpace(params.Root) == "" {
		server.writeError(request.ID, protocol.CodeInvalidParams, "scan.children requires a root", "")
		return nil
	}

	server.mu.Lock()
	if server.closed {
		server.mu.Unlock()
		server.writeError(request.ID, protocol.CodeBusy, "the worker is shutting down", "")
		return nil
	}
	if len(server.jobs) >= MaxConcurrentJobs {
		server.mu.Unlock()
		server.writeError(request.ID, protocol.CodeBusy, fmt.Sprintf("at most %d requests run at once", MaxConcurrentJobs), "")
		return nil
	}
	if _, exists := server.jobs[request.ID]; exists {
		server.mu.Unlock()
		server.writeError(request.ID, protocol.CodeInvalidParams, "request id is already in use", "")
		return nil
	}

	timeout := DefaultJobTimeout
	if request.TimeoutMS > 0 {
		timeout = time.Duration(request.TimeoutMS) * time.Millisecond
	}

	jobContext, cancel := context.WithTimeout(ctx, timeout)
	entry := &job{id: request.ID, op: request.Op, cancel: cancel, done: make(chan struct{})}
	server.jobs[request.ID] = entry
	server.planner.Add(1)
	server.mu.Unlock()

	go func() {
		defer server.planner.Done()
		defer close(entry.done)
		defer cancel()

		result, err := scan.ListChildren(jobContext, params.Root, params.FollowLinks, params.Workers)
		if err != nil {
			var failure *scan.Failure
			if errors.As(err, &failure) {
				server.writeError(request.ID, failure.Code, "the listing could not start", failure.Error())
				return
			}
			server.writeError(request.ID, protocol.CodeIO, "the listing failed", err.Error())
			return
		}
		if errors.Is(jobContext.Err(), context.Canceled) {
			server.writeCancelled(request.ID, "stopped", result.ElapsedMS)
			return
		}
		server.writeResult(request.ID, result)

		server.mu.Lock()
		delete(server.jobs, request.ID)
		server.mu.Unlock()
	}()

	return nil
}

// startMetricSnapshot runs one bounded metric collection as a job.
func (server *Server) startMetricSnapshot(ctx context.Context, request protocol.Request) error {
	var params struct {
		Scope string `json:"scope"`
	}
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "metric.snapshot params are not valid JSON", err.Error())
			return nil
		}
	}
	if len(params.Scope) > 128 {
		server.writeError(request.ID, protocol.CodeInvalidParams, "metric.snapshot scope is too long", "")
		return nil
	}

	server.mu.Lock()
	if server.closed {
		server.mu.Unlock()
		server.writeError(request.ID, protocol.CodeBusy, "the worker is shutting down", "")
		return nil
	}
	if len(server.jobs) >= MaxConcurrentJobs {
		server.mu.Unlock()
		server.writeError(request.ID, protocol.CodeBusy, fmt.Sprintf("at most %d requests run at once", MaxConcurrentJobs), "")
		return nil
	}
	if _, exists := server.jobs[request.ID]; exists {
		server.mu.Unlock()
		server.writeError(request.ID, protocol.CodeInvalidParams, "request id is already in use", "")
		return nil
	}

	timeout := DefaultJobTimeout
	if request.TimeoutMS > 0 {
		timeout = time.Duration(request.TimeoutMS) * time.Millisecond
	}

	jobContext, cancel := context.WithTimeout(ctx, timeout)
	entry := &job{id: request.ID, op: request.Op, cancel: cancel, done: make(chan struct{})}
	server.jobs[request.ID] = entry
	server.planner.Add(1)
	server.mu.Unlock()

	go func() {
		defer server.planner.Done()
		defer close(entry.done)
		defer cancel()

		snapshot, err := server.metrics.Snapshot(jobContext, params.Scope)
		if err != nil {
			server.writeError(request.ID, protocol.CodeIO, "the metric snapshot failed", err.Error())
		} else {
			server.writeResult(request.ID, snapshot)
		}

		server.mu.Lock()
		delete(server.jobs, request.ID)
		server.mu.Unlock()
	}()

	return nil
}

// runScan performs the walk and emits exactly one final message (result, error or
// cancelled). Progress is forwarded by the scan itself through a throttled callback, so the
// rate is bounded here and no goroutine is spawned per progress event.
func (server *Server) runScan(ctx context.Context, id string, options scan.Options, timeout time.Duration) {
	result, err := scan.Walk(ctx, options)
	server.finishScan(ctx, id, result, err, timeout)
}

// finishScan emits the final message for a scan, distinguishing cancellation from success.
func (server *Server) finishScan(ctx context.Context, id string, result *scan.Result, err error, timeout time.Duration) {
	if err != nil {
		var failure *scan.Failure
		if errors.As(err, &failure) {
			server.writeError(id, failure.Code, "the scan could not start", failure.Error())
			return
		}
		if errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled) {
			server.writeCancelled(id, "stopped", 0)
			return
		}
		code := protocol.CodeIO
		if errors.Is(err, context.DeadlineExceeded) {
			code = protocol.CodeTimeout
		}
		server.writeError(id, code, "the scan failed", err.Error())
		return
	}

	if result.Cancelled {
		server.writeCancelled(id, "stopped", result.ElapsedMS)
		return
	}

	if ctx.Err() != nil {
		// The job context expired: report a timeout only when the walk itself did not finish.
		server.writeError(id, protocol.CodeTimeout, fmt.Sprintf("the scan exceeded its %d ms budget", timeout.Milliseconds()), "")
		return
	}

	server.writeResult(id, result)
}

// cancel requests cancellation and reports whether the job had to keep unwinding.
func (server *Server) cancel(target string) string {
	server.mu.Lock()
	entry, ok := server.jobs[target]
	server.mu.Unlock()

	if !ok {
		return "completed"
	}

	entry.cancel()
	server.writeCancelled(target, "stopping", 0)
	return "stopping"
}

// shutdown cancels every job, waits for them within the grace period and marks the server
// closed. It is idempotent.
func (server *Server) shutdown(id string) {
	if server.metricsStore != nil {
		_ = server.metricsStore.Close()
		server.metricsStore = nil
	}

	server.mu.Lock()
	if server.closed {
		server.mu.Unlock()
		return
	}
	server.closed = true
	jobs := make([]*job, 0, len(server.jobs))
	for _, entry := range server.jobs {
		jobs = append(jobs, entry)
	}
	server.mu.Unlock()

	for _, entry := range jobs {
		entry.cancel()
	}

	done := make(chan struct{})
	go func() {
		server.planner.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(ShutdownGrace):
		// The cooperative path did not finish in time. The process exits below; the client
		// owns the documented final termination (kill after its own bounded wait).
		server.logger.Print("shutdown grace elapsed with jobs still running; exiting")
	}
}

func (server *Server) writeResult(id string, value any) {
	payload, err := json.Marshal(value)
	if err != nil {
		server.writeError(id, protocol.CodeInternal, "the result could not be encoded", err.Error())
		return
	}

	if err := server.output.Write(protocol.Message{Type: protocol.TypeResult, ID: id, Result: payload}); err != nil {
		server.logger.Printf("write result: %v", err)
	}
}

func (server *Server) writeError(id, code, message, detail string) {
	if err := server.output.Write(protocol.Message{Type: protocol.TypeError, ID: id, Error: &protocol.Error{Code: code, Message: message, Detail: detail}}); err != nil {
		server.logger.Printf("write error: %v", err)
	}
}

func (server *Server) writeCancelled(id, state string, elapsedMS int64) {
	if err := server.output.Write(protocol.Message{Type: protocol.TypeCancelled, ID: id, Cancelled: &protocol.Cancellation{Ack: true, State: state, ElapsedMS: elapsedMS}}); err != nil {
		server.logger.Printf("write cancelled: %v", err)
	}
}

func (server *Server) writeProgress(id string, snapshot scan.Progress) {
	message := protocol.Message{
		Type: protocol.TypeProgress, ID: id,
		Progress: &protocol.Progress{
			Phase:          snapshot.Phase,
			Files:          snapshot.Files,
			Directories:    snapshot.Directories,
			Bytes:          snapshot.Bytes,
			AllocatedBytes: snapshot.AllocatedBytes,
			Skipped:        snapshot.SkippedLinks + snapshot.SkippedOther,
			Errors:         snapshot.Errors,
			ElapsedMS:      snapshot.Elapsed.Milliseconds(),
		},
	}

	if err := server.output.Write(message); err != nil {
		server.logger.Printf("write progress: %v", err)
	}
}

// DefaultInfo returns the build information for main.
func DefaultInfo(version string) Info {
	return Info{Worker: "wt-worker", Version: version, OS: runtime.GOOS, Arch: runtime.GOARCH}
}

// ErrClosed is returned by helpers when the server already stopped.
var ErrClosed = errors.New("worker is closed")

// errStop unwinds Run after a requested shutdown without being reported as a failure.
var errStop = errors.New("stop")

var _ = os.Stderr

// openMetricsStore opens the store once; a failure is remembered and reported on every
// store operation (read-only behavior: queries fail, writes are refused).
func (server *Server) openMetricsStore(path string) error {
	if server.metricsStore != nil {
		return nil
	}
	st, err := store.Open(path)
	if err != nil {
		return err
	}
	server.metricsStore = st
	return nil
}

func storeErrorCode(err error) string {
	var se *store.StoreError
	if ok := errors.As(err, &se); ok {
		return se.Code
	}
	if err != nil {
		return store.ErrOpenFailed
	}
	return ""
}

// handleStoreWrite persists a batch of metric samples.
func (server *Server) handleStoreWrite(ctx context.Context, request protocol.Request) error {
	var params struct {
		Path  string `json:"path"`
		Rows []struct {
			ID        string   `json:"id"`
			Type      string   `json:"type"`
			Unit      string   `json:"unit"`
			TsMs      int64    `json:"tsMs"`
			Quality   string   `json:"quality"`
			Provider  string   `json:"provider"`
			Value     *float64 `json:"value"`
			Dims      string   `json:"dims"`
			ErrorCode string   `json:"errorCode"`
			Note      string   `json:"note"`
		} `json:"rows"`
	}
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "metric.store.write params are not valid JSON", err.Error())
			return nil
		}
	}
	if params.Path == "" {
		server.writeError(request.ID, store.ErrInvalidParams, "database path required", "")
		return nil
	}
	if err := server.openMetricsStore(params.Path); err != nil {
		server.writeError(request.ID, storeErrorCode(err), "metric store could not be opened", err.Error())
		return nil
	}
	rows := make([]store.MetricRow, 0, len(params.Rows))
	for _, r := range params.Rows {
		rows = append(rows, store.MetricRow{
			ID: r.ID, Type: r.Type, Unit: r.Unit, TsMs: r.TsMs, Quality: r.Quality,
			Provider: r.Provider, Value: r.Value, Dims: r.Dims, ErrorCode: r.ErrorCode, Note: r.Note,
		})
	}
	wrote, err := server.metricsStore.WriteBatch(ctx, rows)
	if err != nil {
		server.writeError(request.ID, storeErrorCode(err), "metric store write failed", err.Error())
		return nil
	}
	server.writeResult(request.ID, map[string]any{"wrote": wrote})
	return nil
}

// handleStoreQuery returns aggregated buckets.
func (server *Server) handleStoreQuery(ctx context.Context, request protocol.Request) error {
	var params struct {
		Path     string `json:"path"`
		ID       string `json:"id"`
		FromMs   int64  `json:"fromMs"`
		ToMs     int64  `json:"toMs"`
		BucketMs int64  `json:"bucketMs"`
	}
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "metric.store.query params are not valid JSON", err.Error())
			return nil
		}
	}
	if server.metricsStore == nil {
		if err := server.openMetricsStore(params.Path); err != nil {
			server.writeError(request.ID, storeErrorCode(err), "metric store could not be opened", err.Error())
			return nil
		}
	}
	buckets, err := server.metricsStore.QueryRange(ctx, params.ID, params.FromMs, params.ToMs, params.BucketMs)
	if err != nil {
		server.writeError(request.ID, storeErrorCode(err), "metric store query failed", err.Error())
		return nil
	}
	server.writeResult(request.ID, map[string]any{"buckets": buckets})
	return nil
}

// handleStoreRaw returns raw samples.
func (server *Server) handleStoreRaw(ctx context.Context, request protocol.Request) error {
	var params struct {
		Path   string `json:"path"`
		ID     string `json:"id"`
		FromMs int64  `json:"fromMs"`
		ToMs   int64  `json:"toMs"`
		Limit  int    `json:"limit"`
	}
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "metric.store.raw params are not valid JSON", err.Error())
			return nil
		}
	}
	if server.metricsStore == nil {
		if err := server.openMetricsStore(params.Path); err != nil {
			server.writeError(request.ID, storeErrorCode(err), "metric store could not be opened", err.Error())
			return nil
		}
	}
	samples, err := server.metricsStore.RawSamples(ctx, params.ID, params.FromMs, params.ToMs, params.Limit)
	if err != nil {
		server.writeError(request.ID, storeErrorCode(err), "metric store raw query failed", err.Error())
		return nil
	}
	server.writeResult(request.ID, map[string]any{"samples": samples})
	return nil
}

// handleStoreRetention deletes samples older than cutoff. The deleted count is reported
// before deletion is acknowledged (policy explained by the caller beforehand).
func (server *Server) handleStoreRetention(ctx context.Context, request protocol.Request) error {
	var params struct {
		Path     string `json:"path"`
		CutoffMs int64  `json:"cutoffMs"`
	}
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "metric.store.retention params are not valid JSON", err.Error())
			return nil
		}
	}
	if server.metricsStore == nil {
		if err := server.openMetricsStore(params.Path); err != nil {
			server.writeError(request.ID, storeErrorCode(err), "metric store could not be opened", err.Error())
			return nil
		}
	}
	deleted, err := server.metricsStore.Retention(ctx, params.CutoffMs)
	if err != nil {
		server.writeError(request.ID, storeErrorCode(err), "retention failed", err.Error())
		return nil
	}
	server.writeResult(request.ID, map[string]any{"deleted": deleted})
	return nil
}

// handleStoreStats reports store state.
func (server *Server) handleStoreStats(ctx context.Context, request protocol.Request) error {
	var params struct {
		Path string `json:"path"`
	}
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "metric.store.stats params are not valid JSON", err.Error())
			return nil
		}
	}
	if server.metricsStore == nil {
		if err := server.openMetricsStore(params.Path); err != nil {
			server.writeError(request.ID, storeErrorCode(err), "metric store could not be opened", err.Error())
			return nil
		}
	}
	stats, err := server.metricsStore.Stats(ctx)
	if err != nil {
		server.writeError(request.ID, storeErrorCode(err), "store stats failed", err.Error())
		return nil
	}
	server.writeResult(request.ID, stats)
	return nil
}

func (server *Server) handleExporterStart(ctx context.Context, request protocol.Request) error {
	var params struct {
		Port int `json:"port"`
	}
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "exporter.start params are not valid JSON", err.Error())
			return nil
		}
	}
	if server.metricsExporter == nil {
		e, err := exporter.New(exporter.Options{Port: params.Port})
		if err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "exporter configuration invalid", err.Error())
			return nil
		}
		server.metricsExporter = e
	}
	if err := server.metricsExporter.Start(); err != nil {
		server.writeError(request.ID, protocol.CodeIO, "exporter could not start", err.Error())
		return nil
	}
	server.writeResult(request.ID, map[string]any{"started": true, "address": "127.0.0.1", "port": params.Port})
	return nil
}

func (server *Server) handleExporterStop(ctx context.Context, request protocol.Request) error {
	if server.metricsExporter != nil {
		if err := server.metricsExporter.Stop(ctx); err != nil {
			server.writeError(request.ID, protocol.CodeIO, "exporter could not stop", err.Error())
			return nil
		}
	}
	server.writeResult(request.ID, map[string]any{"stopped": true})
	return nil
}

func (server *Server) handleExporterStatus(ctx context.Context, request protocol.Request) error {
	if server.metricsExporter == nil {
		server.writeResult(request.ID, map[string]any{"running": false})
		return nil
	}
	server.writeResult(request.ID, map[string]any{"running": true, "address": "127.0.0.1", "port": server.metricsExporter.Port()})
	return nil
}

func (server *Server) handleStoreAlert(ctx context.Context, request protocol.Request) error {
	var params struct {
		Path      string `json:"path"`
		RuleID    string `json:"ruleId"`
		Revision  int    `json:"revision"`
		FromState string `json:"fromState"`
		ToState   string `json:"toState"`
		AtMs      int64  `json:"atMs"`
		Evidence  string `json:"evidence"`
		DataSource string `json:"dataSource"`
	}
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			server.writeError(request.ID, protocol.CodeInvalidParams, "metric.store.alert params are not valid JSON", err.Error())
			return nil
		}
	}
	if server.metricsStore == nil {
		if err := server.openMetricsStore(params.Path); err != nil {
			server.writeError(request.ID, storeErrorCode(err), "metric store could not be opened", err.Error())
			return nil
		}
	}
	if err := server.metricsStore.AppendAlertTransition(ctx, params.RuleID, params.Revision, params.FromState, params.ToState, params.AtMs, params.Evidence, params.DataSource); err != nil {
		server.writeError(request.ID, storeErrorCode(err), "alert transition append failed", err.Error())
		return nil
	}
	server.writeResult(request.ID, map[string]any{"recorded": true})
	return nil
}
