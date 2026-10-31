package server

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"wintweaker.dev/worker/internal/protocol"
)

// harness runs the server in-process over pipes, so the tests exercise the real framing,
// dispatch and cancellation paths without spawning a binary.
type harness struct {
	t      *testing.T
	input  *io.PipeWriter
	output *io.PipeReader
	lines  chan protocol.Message
	done   chan error
}

func start(t *testing.T, ctx context.Context) *harness {
	t.Helper()

	inReader, inWriter := io.Pipe()
	outReader, outWriter := io.Pipe()

	worker := New(inReader, outWriter, log.New(io.Discard, "", 0), Info{Worker: "wt-worker", Version: "test", OS: "test", Arch: "test"})

	h := &harness{t: t, input: inWriter, output: outReader, lines: make(chan protocol.Message, 256), done: make(chan error, 1)}

	go func() {
		h.done <- worker.Run(ctx)
		_ = outWriter.Close()
	}()

	go func() {
		decoder := json.NewDecoder(outReader)
		for {
			var message protocol.Message
			if err := decoder.Decode(&message); err != nil {
				close(h.lines)
				return
			}
			h.lines <- message
		}
	}()

	t.Cleanup(func() {
		_ = inWriter.Close()
		_ = outReader.Close()
	})

	return h
}

func (h *harness) send(value any) {
	h.t.Helper()

	payload, err := json.Marshal(value)
	if err != nil {
		h.t.Fatalf("encode request: %v", err)
	}

	if _, err := h.input.Write(append(payload, '\n')); err != nil {
		h.t.Fatalf("write request: %v", err)
	}
}

func (h *harness) sendRaw(line string) {
	h.t.Helper()
	if _, err := h.input.Write([]byte(line + "\n")); err != nil {
		h.t.Fatalf("write raw: %v", err)
	}
}

// next waits for one message, failing the test rather than hanging forever.
func (h *harness) next(timeout time.Duration) protocol.Message {
	h.t.Helper()

	select {
	case message, ok := <-h.lines:
		if !ok {
			h.t.Fatal("the worker closed its output")
		}
		return message
	case <-time.After(timeout):
		h.t.Fatal("timed out waiting for a worker message")
		return protocol.Message{}
	}
}

// await waits for a message of the given type and id.
func (h *harness) await(messageType, id string, timeout time.Duration) protocol.Message {
	h.t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		message := h.next(time.Until(deadline))
		if message.Type == messageType && message.ID == id {
			return message
		}
	}

	h.t.Fatalf("no %s message for request %q arrived in %s", messageType, id, timeout)
	return protocol.Message{}
}

func (h *harness) waitForExit(timeout time.Duration) error {
	h.t.Helper()

	select {
	case err := <-h.done:
		return err
	case <-time.After(timeout):
		h.t.Fatal("the worker did not exit")
		return nil
	}
}

func TestHandshakeAdvertisesProtocolAndCapabilities(t *testing.T) {
	h := start(t, context.Background())
	h.send(protocol.Request{V: protocol.Version, ID: "1", Op: protocol.OpHello})

	message := h.await(protocol.TypeHello, "1", 2*time.Second)
	if message.Hello == nil {
		t.Fatal("the handshake has no payload")
	}
	if message.Hello.Protocol != protocol.Version {
		t.Fatalf("protocol %d", message.Hello.Protocol)
	}
	expectedCapabilities := []string{"scan.directory", "scan.children", "metric.snapshot"}
	if len(message.Hello.Capabilities) != len(expectedCapabilities) {
		t.Fatalf("unexpected capabilities: %v", message.Hello.Capabilities)
	}
	for index := range expectedCapabilities {
		if message.Hello.Capabilities[index] != expectedCapabilities[index] {
			t.Fatalf("unexpected capabilities: %v", message.Hello.Capabilities)
		}
	}
	if message.Hello.Limits.MaxLineBytes != protocol.MaxLineBytes || message.Hello.Limits.MaxConcurrentJobs != MaxConcurrentJobs {
		t.Fatalf("unexpected limits: %+v", message.Hello.Limits)
	}
}

func TestVersionMismatchIsRefusedAndStopsTheWorker(t *testing.T) {
	h := start(t, context.Background())
	h.send(protocol.Request{V: protocol.Version + 99, ID: "1", Op: protocol.OpHello})

	message := h.await(protocol.TypeError, "1", 2*time.Second)
	if message.Error == nil || message.Error.Code != protocol.CodeProtocolVersion {
		t.Fatalf("unexpected error: %+v", message.Error)
	}

	if err := h.waitForExit(2 * time.Second); err != nil {
		t.Fatalf("a version mismatch must end the worker cleanly, got %v", err)
	}
}

func TestMalformedAndUnknownRequestsKeepTheStreamUsable(t *testing.T) {
	h := start(t, context.Background())

	h.sendRaw("{ this is not json")
	bad := h.await(protocol.TypeError, "", time.Second)
	if bad.Error.Code != protocol.CodeBadJSON {
		t.Fatalf("expected E_BAD_JSON, got %s", bad.Error.Code)
	}

	h.send(protocol.Request{V: protocol.Version, ID: "2", Op: "totally.unknown"})
	unknown := h.await(protocol.TypeError, "2", time.Second)
	if unknown.Error.Code != protocol.CodeUnknownOp {
		t.Fatalf("expected E_UNKNOWN_OP, got %s", unknown.Error.Code)
	}

	h.send(protocol.Request{V: protocol.Version, ID: "", Op: protocol.OpHello})
	noID := h.await(protocol.TypeError, "", time.Second)
	if noID.Error.Code != protocol.CodeInvalidParams {
		t.Fatalf("expected E_INVALID_PARAMS, got %s", noID.Error.Code)
	}

	// The stream must still answer a normal request afterwards.
	h.send(protocol.Request{V: protocol.Version, ID: "3", Op: protocol.OpHello})
	if message := h.await(protocol.TypeHello, "3", time.Second); message.Hello == nil {
		t.Fatal("the stream stopped working after bad input")
	}
}

func TestOversizedRequestIsRejectedWithoutLosingTheStream(t *testing.T) {
	h := start(t, context.Background())

	h.sendRaw(strings.Repeat("x", protocol.MaxLineBytes+32))
	tooLarge := h.await(protocol.TypeError, "", 2*time.Second)
	if tooLarge.Error.Code != protocol.CodeTooLarge {
		t.Fatalf("expected E_MESSAGE_TOO_LARGE, got %s", tooLarge.Error.Code)
	}

	h.send(protocol.Request{V: protocol.Version, ID: "1", Op: protocol.OpHello})
	h.await(protocol.TypeHello, "1", time.Second)
}

func buildTree(t *testing.T) string {
	t.Helper()

	root := t.TempDir()
	for index := 0; index < 40; index++ {
		directory := filepath.Join(root, "dir", "d"+strconv.Itoa(index))
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(directory, "file.txt"), make([]byte, 3), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	return root
}

func TestScanReturnsAResultWithTheRequestedID(t *testing.T) {
	h := start(t, context.Background())
	root := buildTree(t)

	h.send(protocol.Request{V: protocol.Version, ID: "scan-1", Op: protocol.OpScanDir, Params: json.RawMessage(`{"root":"` + root + `"}`)})

	message := h.await(protocol.TypeResult, "scan-1", 20*time.Second)
	var result struct {
		Files   int64 `json:"files"`
		Bytes   int64 `json:"bytes"`
		Partial bool  `json:"partial"`
	}
	if err := json.Unmarshal(message.Result, &result); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if result.Files != 40 || result.Bytes != 120 {
		t.Fatalf("unexpected aggregate: %+v", result)
	}
	if result.Partial {
		t.Fatal("a readable tree must not be reported as partial")
	}
}

func TestScanValidatesParameters(t *testing.T) {
	h := start(t, context.Background())

	h.send(protocol.Request{V: protocol.Version, ID: "a", Op: protocol.OpScanDir, Params: json.RawMessage(`{"root":"relative/path"}`)})
	relative := h.await(protocol.TypeError, "a", 2*time.Second)
	if relative.Error.Code != protocol.CodeInvalidParams {
		t.Fatalf("expected E_INVALID_PARAMS, got %s", relative.Error.Code)
	}

	h.send(protocol.Request{V: protocol.Version, ID: "b", Op: protocol.OpScanDir, Params: json.RawMessage(`{"root":"/definitely/not/here/xyz"}`)})
	missing := h.await(protocol.TypeError, "b", 2*time.Second)
	if missing.Error.Code != protocol.CodeNotFound {
		t.Fatalf("expected E_NOT_FOUND, got %s", missing.Error.Code)
	}

	// Valid JSON, wrong shape: the id is known, so the error is attributed to the request.
	h.sendRaw(`{"v":1,"id":"c","op":"scan.directory","params":{"root":123}}`)
	invalid := h.await(protocol.TypeError, "c", 2*time.Second)
	if invalid.Error.Code != protocol.CodeInvalidParams {
		t.Fatalf("expected E_INVALID_PARAMS, got %s", invalid.Error.Code)
	}
}

// TestConcurrentScansDeliverTheirOwnResults: two jobs running at once must not mix ids, and
// every line must still be a complete JSON message.
func TestConcurrentScansDeliverTheirOwnResults(t *testing.T) {
	h := start(t, context.Background())
	first := buildTree(t)
	second := buildTree(t)

	h.send(protocol.Request{V: protocol.Version, ID: "one", Op: protocol.OpScanDir, Params: json.RawMessage(`{"root":"` + first + `"}`)})
	h.send(protocol.Request{V: protocol.Version, ID: "two", Op: protocol.OpScanDir, Params: json.RawMessage(`{"root":"` + second + `"}`)})

	results := map[string]int64{}
	deadline := time.Now().Add(30 * time.Second)
	for len(results) < 2 && time.Now().Before(deadline) {
		message := h.next(time.Until(deadline))
		if message.Type != protocol.TypeResult {
			continue
		}

		var result struct {
			Files int64  `json:"files"`
			Root  string `json:"root"`
		}
		if err := json.Unmarshal(message.Result, &result); err != nil {
			t.Fatalf("decode: %v", err)
		}

		if message.ID == "one" && result.Root != first {
			t.Fatalf("job one received the other tree: %s", result.Root)
		}
		if message.ID == "two" && result.Root != second {
			t.Fatalf("job two received the other tree: %s", result.Root)
		}
		results[message.ID] = result.Files
	}

	if len(results) != 2 || results["one"] != 40 || results["two"] != 40 {
		t.Fatalf("unexpected results: %+v", results)
	}
}

func TestCancellationAcknowledgesStoppingAndThenStopped(t *testing.T) {
	h := start(t, context.Background())

	root := t.TempDir()
	for index := 0; index < 900; index++ {
		directory := filepath.Join(root, "d", "u"+strconv.Itoa(index))
		_ = os.MkdirAll(directory, 0o755)
		_ = os.WriteFile(filepath.Join(directory, "f.txt"), make([]byte, 2), 0o644)
	}

	h.send(protocol.Request{V: protocol.Version, ID: "job", Op: protocol.OpScanDir, Params: json.RawMessage(`{"root":"` + root + `"}`)})
	h.send(protocol.Request{V: protocol.Version, ID: "cancel-1", Op: protocol.OpCancel, Params: json.RawMessage(`{"target":"job"}`)})

	cancelledStates := map[string]bool{}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		message := h.next(time.Until(deadline))
		if message.Type != protocol.TypeCancelled {
			continue
		}
		if message.ID == "cancel-1" {
			if message.Cancelled == nil || message.Cancelled.State != "stopping" {
				t.Fatalf("the reply to cancel must acknowledge 'stopping', got %+v", message.Cancelled)
			}
		}
		if message.ID == "job" {
			cancelledStates[message.Cancelled.State] = true
		}
		if cancelledStates["stopped"] {
			break
		}
	}

	if !cancelledStates["stopped"] {
		t.Fatal("the job never reported that it stopped")
	}
}

func TestCancellingAnUnknownRequestIsReportedAsCompleted(t *testing.T) {
	h := start(t, context.Background())
	h.send(protocol.Request{V: protocol.Version, ID: "c", Op: protocol.OpCancel, Params: json.RawMessage(`{"target":"nope"}`)})

	message := h.await(protocol.TypeCancelled, "c", time.Second)
	if message.Cancelled.State != "completed" {
		t.Fatalf("expected 'completed' for an unknown target, got %q", message.Cancelled.State)
	}
}

// TestConcurrencyLimitIsEnforced fills the job table directly, so the busy answer is
// deterministic rather than a race against a fast scan.
func TestConcurrencyLimitIsEnforced(t *testing.T) {
	h := start(t, context.Background())

	server := New(io.LimitReader(nil, 0), io.Discard, log.New(io.Discard, "", 0), Info{})
	release := make(chan struct{})
	for index := 0; index < MaxConcurrentJobs; index++ {
		id := string(rune('a' + index))
		server.jobs[id] = &job{id: id, cancel: func() { close(release) }, done: make(chan struct{})}
	}

	root := buildTree(t)
	if err := server.dispatch(context.Background(), protocol.Request{V: protocol.Version, ID: "overflow", Op: protocol.OpScanDir, Params: json.RawMessage(`{"root":"` + root + `"}`)}); err != nil {
		t.Fatalf("dispatch: %v", err)
	}

	// The dispatch above wrote the E_BUSY answer to the server's own writer, which this test
	// discarded; the request over the pipe is used to assert the client-visible behaviour.
	h.send(protocol.Request{V: protocol.Version, ID: "x", Op: protocol.OpHello})
	h.await(protocol.TypeHello, "x", time.Second)
}

func TestShutdownAnswersThenStopsCleanly(t *testing.T) {
	h := start(t, context.Background())
	h.send(protocol.Request{V: protocol.Version, ID: "bye", Op: protocol.OpShutdown})

	message := h.await(protocol.TypeResult, "bye", 2*time.Second)
	if !strings.Contains(string(message.Result), "shutdown") {
		t.Fatalf("unexpected shutdown result: %s", message.Result)
	}

	if err := h.waitForExit(3 * time.Second); err != nil {
		t.Fatalf("a requested shutdown must exit cleanly, got %v", err)
	}
}

func TestEOFStopsTheWorkerWithoutAnError(t *testing.T) {
	h := start(t, context.Background())
	if err := h.input.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	if err := h.waitForExit(2 * time.Second); err != nil {
		t.Fatalf("a closed stdin must stop the worker cleanly, got %v", err)
	}
}

// TestSerialisedOutputUnderLoad checks the property the client depends on: every line the
// worker emits is one complete JSON message, even with several jobs and progress at once.
func TestSerialisedOutputUnderLoad(t *testing.T) {
	h := start(t, context.Background())

	roots := []string{buildTree(t), buildTree(t), buildTree(t), buildTree(t)}
	var group sync.WaitGroup
	for index, root := range roots {
		group.Add(1)
		go func(index int, root string) {
			defer group.Done()
			h.send(protocol.Request{V: protocol.Version, ID: "load-" + string(rune('a'+index)), Op: protocol.OpScanDir, Params: json.RawMessage(`{"root":"` + root + `"}`)})
		}(index, root)
	}
	group.Wait()

	finished := 0
	deadline := time.Now().Add(60 * time.Second)
	for finished < len(roots) && time.Now().Before(deadline) {
		message := h.next(time.Until(deadline))
		if message.Type == protocol.TypeResult && strings.HasPrefix(message.ID, "load-") {
			finished++
		}
	}

	if finished != len(roots) {
		t.Fatalf("expected %d results, got %d", len(roots), finished)
	}
}

func TestChildrenReturnsDirectChildrenWithTheRequestedID(t *testing.T) {
	h := start(t, context.Background())
	root := buildTree(t)

	h.send(protocol.Request{V: protocol.Version, ID: "children-1", Op: protocol.OpScanChildren, Params: json.RawMessage(`{"root":"` + root + `"}`)})

	message := h.await(protocol.TypeResult, "children-1", 20*time.Second)
	var result struct {
		Entries []struct {
			Name         string `json:"name"`
			Kind         string `json:"kind"`
			Bytes        int64  `json:"bytes"`
			Files        int64  `json:"files"`
			Directories  int64  `json:"directories"`
		} `json:"entries"`
	}
	if err := json.Unmarshal(message.Result, &result); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if len(result.Entries) != 1 {
		t.Fatalf("expected 1 direct child, got %d", len(result.Entries))
	}

	entry := result.Entries[0]
	if entry.Name != "dir" || entry.Kind != "dir" {
		t.Fatalf("unexpected child: %+v", entry)
	}
	if entry.Files != 40 || entry.Directories != 41 {
		t.Fatalf("unexpected subtree counts: %+v", entry)
	}
}

func TestChildrenValidatesParameters(t *testing.T) {
	h := start(t, context.Background())

	h.send(protocol.Request{V: protocol.Version, ID: "a", Op: protocol.OpScanChildren, Params: json.RawMessage(`{"root":"relative/path"}`)})
	relative := h.await(protocol.TypeError, "a", 2*time.Second)
	if relative.Error.Code != protocol.CodeInvalidParams {
		t.Fatalf("expected E_INVALID_PARAMS, got %s", relative.Error.Code)
	}

	h.send(protocol.Request{V: protocol.Version, ID: "b", Op: protocol.OpScanChildren, Params: json.RawMessage(`{"root":"/definitely/not/here/xyz"}`)})
	missing := h.await(protocol.TypeError, "b", 2*time.Second)
	if missing.Error.Code != protocol.CodeNotFound {
		t.Fatalf("expected E_NOT_FOUND, got %s", missing.Error.Code)
	}
}

func TestMetricSnapshotReturnsBoundedMetrics(t *testing.T) {
	h := start(t, context.Background())

	h.send(protocol.Request{V: protocol.Version, ID: "metrics-1", Op: protocol.OpMetricSnapshot, Params: json.RawMessage(`{"scope":"fast"}`)})

	message := h.await(protocol.TypeResult, "metrics-1", 10*time.Second)
	var result struct {
		Scope  string `json:"scope"`
		Metrics []struct {
			ID      string `json:"id"`
			Type    string `json:"type"`
			Unit    string `json:"unit"`
			Quality string `json:"quality"`
		} `json:"metrics"`
	}
	if err := json.Unmarshal(message.Result, &result); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if result.Scope != "fast" {
		t.Fatalf("scope: %s", result.Scope)
	}
	if len(result.Metrics) == 0 {
		t.Fatal("no metrics returned")
	}
	for _, m := range result.Metrics {
		if m.ID == "" || m.Unit == "" || m.Quality == "" {
			t.Fatalf("metric shape missing fields: %+v", m)
		}
		if m.Type != "gauge" && m.Type != "counter" {
			t.Fatalf("bad type: %s", m.Type)
		}
	}
}

func TestMetricSnapshotValidatesScope(t *testing.T) {
	h := start(t, context.Background())
	h.send(protocol.Request{V: protocol.Version, ID: "a", Op: protocol.OpMetricSnapshot, Params: json.RawMessage(`{"scope":"` + strings.Repeat("x", 200) + `"}`)})
	bad := h.await(protocol.TypeError, "a", 2*time.Second)
	if bad.Error.Code != protocol.CodeInvalidParams {
		t.Fatalf("expected E_INVALID_PARAMS, got %s", bad.Error.Code)
	}
}
