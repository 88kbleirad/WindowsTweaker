// Package protocol implements the versioned JSON Lines protocol the worker speaks on
// stdin/stdout.
//
// Contract (see docs/WORKER.md for the full specification):
//   - one JSON object per line, UTF-8, LF terminated;
//   - stdout carries protocol messages and nothing else;
//   - stderr carries bounded diagnostic lines only;
//   - every message carries the protocol version;
//   - exactly one writer goroutine owns stdout, so concurrent tasks can never interleave.
package protocol

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
)

// Version is the protocol revision this build speaks. A client that sends another value
// gets a single VersionMismatch message and the worker exits, rather than guessing.
const Version = 1

// Limits. A hostile or buggy client must not be able to make the worker allocate without
// bound, so every read is capped and oversize lines are rejected instead of buffered.
const (
	MaxLineBytes     = 1 << 20 // 1 MiB per request line
	MaxOutLineBytes  = 1 << 22 // 4 MiB per emitted line (bounded by the result caps below)
	writerBufferSize = 1 << 16
)

// Operation names.
const (
	OpHello        = "hello"
	OpScanDir      = "scan.directory"
	OpScanChildren = "scan.children"
	OpScanHash     = "scan.hash"
	OpNetDNS       = "net.dns"
	OpNetTCP       = "net.tcp"
	OpMetricSnapshot = "metric.snapshot"
	OpStoreWrite     = "metric.store.write"
	OpStoreQuery     = "metric.store.query"
	OpStoreRaw       = "metric.store.raw"
	OpStoreRetention = "metric.store.retention"
	OpStoreStats     = "metric.store.stats"
	OpExporterStart  = "exporter.start"
	OpExporterStop   = "exporter.stop"
	OpExporterStatus = "exporter.status"
	OpStoreAlert     = "metric.store.alert"
	OpCancel       = "cancel"
	OpShutdown     = "shutdown"
)

// Message types sent by the worker.
const (
	TypeHello     = "hello"
	TypeProgress  = "progress"
	TypeResult    = "result"
	TypeError     = "error"
	TypeCancelled = "cancelled"
)

// Stable error codes. The interface translates these; the worker never returns prose that
// the UI is expected to show verbatim.
const (
	CodeProtocolVersion = "E_PROTOCOL_VERSION"
	CodeBadJSON         = "E_BAD_JSON"
	CodeTooLarge        = "E_MESSAGE_TOO_LARGE"
	CodeUnknownOp       = "E_UNKNOWN_OP"
	CodeInvalidParams   = "E_INVALID_PARAMS"
	CodeNotFound        = "E_NOT_FOUND"
	CodeNotDir          = "E_NOT_DIRECTORY"
	CodeAccessDenied    = "E_ACCESS_DENIED"
	CodeIO              = "E_IO"
	CodeTimeout         = "E_TIMEOUT"
	CodeCancelled       = "E_CANCELLED"
	CodeBusy            = "E_BUSY"
	CodeInternal        = "E_INTERNAL"
)

// Request is one client message.
type Request struct {
	V         int             `json:"v"`
	ID        string          `json:"id"`
	Op        string          `json:"op"`
	Params    json.RawMessage `json:"params,omitempty"`
	TimeoutMS int             `json:"timeoutMs,omitempty"`
}

// Message is one worker message. Type selects which of the payload fields is meaningful;
// a client must ignore fields that do not belong to the type it received.
type Message struct {
	V         int             `json:"v"`
	Type      string          `json:"type"`
	ID        string          `json:"id,omitempty"`
	Hello     *Hello          `json:"hello,omitempty"`
	Progress  *Progress       `json:"progress,omitempty"`
	Result    json.RawMessage `json:"result,omitempty"`
	Error     *Error          `json:"error,omitempty"`
	Cancelled *Cancellation   `json:"cancelled,omitempty"`
}

// Hello is the capability handshake answer.
type Hello struct {
	Worker       string   `json:"worker"`
	Version      string   `json:"version"`
	Protocol     int      `json:"protocol"`
	GoVersion    string   `json:"goVersion"`
	OS           string   `json:"os"`
	Arch         string   `json:"arch"`
	Capabilities []string `json:"capabilities"`
	Limits       Limits   `json:"limits"`
}

// Limits advertises the bounds the worker enforces, so the client can validate before it
// asks rather than after it fails.
type Limits struct {
	MaxLineBytes      int `json:"maxLineBytes"`
	MaxErrors         int `json:"maxErrors"`
	ScanWorkers       int `json:"scanWorkers"`
	MaxScanDepth      int `json:"maxScanDepth"`
	ProgressEveryMS   int `json:"progressEveryMs"`
	MaxResultPaths    int `json:"maxResultPaths"`
	MaxConcurrentJobs int `json:"maxConcurrentJobs"`
}

// Progress is a bounded, throttled progress event.
type Progress struct {
	Phase          string `json:"phase"`
	Files          int64  `json:"files"`
	Directories    int64  `json:"directories"`
	Bytes          int64  `json:"bytes"`
	AllocatedBytes int64  `json:"allocatedBytes"`
	Skipped        int64  `json:"skipped"`
	Errors         int64  `json:"errors"`
	ElapsedMS      int64  `json:"elapsedMs"`
}

// Error is a structured failure with a stable code.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Detail  string `json:"detail,omitempty"`
}

// Cancellation reports how far cancellation got. "stopped" means every worker goroutine
// has finished; "stopping" means the acknowledgement was sent while a child (for example a
// filesystem read that cannot be interrupted) is still unwinding.
type Cancellation struct {
	Ack       bool   `json:"ack"`
	State     string `json:"state"`
	ElapsedMS int64  `json:"elapsedMs"`
}

// Writer serialises every message onto one stream. One mutex per writer is the whole
// concurrency story on the output side: no task library, no interleaving.
type Writer struct {
	mu sync.Mutex
	w  *bufio.Writer
}

// NewWriter wraps w.
func NewWriter(w io.Writer) *Writer {
	return &Writer{w: bufio.NewWriterSize(w, writerBufferSize)}
}

// Write encodes one message as a line and flushes it. It is safe for concurrent use.
func (writer *Writer) Write(message Message) error {
	if message.V == 0 {
		message.V = Version
	}

	payload, err := json.Marshal(message)
	if err != nil {
		return fmt.Errorf("encode message: %w", err)
	}

	if len(payload) > MaxOutLineBytes {
		return fmt.Errorf("message of %d bytes exceeds the %d byte limit", len(payload), MaxOutLineBytes)
	}

	writer.mu.Lock()
	defer writer.mu.Unlock()

	if _, err := writer.w.Write(payload); err != nil {
		return err
	}
	if err := writer.w.WriteByte('\n'); err != nil {
		return err
	}

	return writer.w.Flush()
}

// ErrLineTooLarge is returned by ReadRequest when a client line exceeds MaxLineBytes.
var ErrLineTooLarge = errors.New("request line exceeds the size limit")

// Reader reads request lines with a hard size cap.
type Reader struct {
	reader *bufio.Reader
}

// NewReader wraps r.
func NewReader(r io.Reader) *Reader {
	return &Reader{reader: bufio.NewReaderSize(r, writerBufferSize)}
}

// ReadLine returns the next line without its terminator. A line longer than the cap is
// reported as ErrLineTooLarge while the remainder of that line is discarded, so the stream
// stays usable for the next message instead of desynchronising.
func (reader *Reader) ReadLine() ([]byte, error) {
	line, err := reader.reader.ReadSlice('\n')
	if err == nil {
		if len(line) > MaxLineBytes {
			return nil, ErrLineTooLarge
		}
		return trimEOL(line), nil
	}

	if errors.Is(err, bufio.ErrBufferFull) {
		// Discard the rest of the oversized line.
		for errors.Is(err, bufio.ErrBufferFull) {
			_, err = reader.reader.ReadSlice('\n')
		}
		if err != nil && !errors.Is(err, io.EOF) {
			return nil, err
		}
		return nil, ErrLineTooLarge
	}

	if errors.Is(err, io.EOF) && len(line) > 0 {
		return trimEOL(line), nil
	}

	return nil, err
}

func trimEOL(line []byte) []byte {
	for len(line) > 0 {
		last := line[len(line)-1]
		if last == '\n' || last == '\r' {
			line = line[:len(line)-1]
			continue
		}
		break
	}
	return line
}
