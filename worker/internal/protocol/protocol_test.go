package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
)

// TestWriterSerialisesConcurrentMessages is the property that matters most on the output
// side: two tasks writing at the same time must never interleave inside a line.
func TestWriterSerialisesConcurrentMessages(t *testing.T) {
	buffer := &syncBuffer{}
	writer := NewWriter(buffer)

	const writers = 16
	const each = 40

	var group sync.WaitGroup
	for index := 0; index < writers; index++ {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			for sequence := 0; sequence < each; sequence++ {
				if err := writer.Write(Message{Type: TypeProgress, ID: "id", Progress: &Progress{Phase: "walk", Files: int64(index)}}); err != nil {
					t.Errorf("write: %v", err)
					return
				}
			}
		}(index)
	}
	group.Wait()

	lines := strings.Split(strings.TrimRight(buffer.String(), "\n"), "\n")
	if len(lines) != writers*each {
		t.Fatalf("expected %d lines, got %d", writers*each, len(lines))
	}

	for index, line := range lines {
		var message Message
		if err := json.Unmarshal([]byte(line), &message); err != nil {
			t.Fatalf("line %d is not valid JSON (%v): %q", index, err, line)
		}
		if message.V != Version {
			t.Fatalf("line %d carries protocol %d", index, message.V)
		}
		if message.Progress == nil {
			t.Fatalf("line %d lost its progress payload", index)
		}
	}
}

// TestWriterOmitsUnusedPayloads: a message must not carry a null payload for a type it is
// not (the PowerShell adapter keys off the type).
func TestWriterOmitsUnusedPayloads(t *testing.T) {
	buffer := &syncBuffer{}
	writer := NewWriter(buffer)
	if err := writer.Write(Message{Type: TypeHello, ID: "1", Hello: &Hello{Worker: "wt-worker"}}); err != nil {
		t.Fatalf("write: %v", err)
	}

	line := strings.TrimSpace(buffer.String())
	for _, unwanted := range []string{"progress", "result", "error", "cancelled"} {
		if strings.Contains(line, `"`+unwanted+`"`) {
			t.Fatalf("hello message contains %q: %s", unwanted, line)
		}
	}
}

// TestReaderRejectsOversizedLineAndKeepsStreaming: the stream must stay usable after a line
// that is too long, otherwise one bad client message desynchronises everything after it.
func TestReaderRejectsOversizedLineAndKeepsStreaming(t *testing.T) {
	oversized := strings.Repeat("x", MaxLineBytes+16)
	stream := oversized + "\n" + `{"v":1,"id":"after","op":"hello"}` + "\n"

	reader := NewReader(strings.NewReader(stream))

	if _, err := reader.ReadLine(); !errors.Is(err, ErrLineTooLarge) {
		t.Fatalf("expected ErrLineTooLarge, got %v", err)
	}

	line, err := reader.ReadLine()
	if err != nil {
		t.Fatalf("the stream did not recover: %v", err)
	}
	if !strings.Contains(string(line), "after") {
		t.Fatalf("unexpected line after the oversized one: %q", line)
	}
}

// TestReaderHandlesFinalLineWithoutNewline: a client that closes stdin right after a request
// must still have that request processed.
func TestReaderHandlesFinalLineWithoutNewline(t *testing.T) {
	reader := NewReader(strings.NewReader(`{"v":1,"id":"1","op":"hello"}`))
	line, err := reader.ReadLine()
	if err != nil || len(line) == 0 {
		t.Fatalf("line=%q err=%v", line, err)
	}

	if _, err := reader.ReadLine(); !errors.Is(err, io.EOF) {
		t.Fatalf("expected EOF, got %v", err)
	}
}

// TestWriterRejectsOversizedMessage: the worker must never emit a line bigger than the
// documented ceiling.
func TestWriterRejectsOversizedMessage(t *testing.T) {
	writer := NewWriter(&syncBuffer{})
	huge := bytes.Repeat([]byte("a"), MaxOutLineBytes)
	if err := writer.Write(Message{Type: TypeResult, ID: "1", Result: json.RawMessage(`"` + string(huge) + `"`)}); err == nil {
		t.Fatal("expected an error for an oversized message")
	}
}

type syncBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buffer.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buffer.String()
}
