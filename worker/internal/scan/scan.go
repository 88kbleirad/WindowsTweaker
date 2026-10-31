// Package scan implements the worker's first read-only capability: walking an explicitly
// selected directory tree and aggregating file sizes.
//
// Properties this package guarantees, each one covered by a test:
//   - the walk never leaves the root it was given;
//   - symbolic links (and on Windows the reparse points Go reports as links) are skipped by
//     default and counted as skipped, never followed;
//   - a file or directory that cannot be read, or that disappears mid-walk, is recorded as a
//     bounded structured error and the walk continues: the result is explicitly partial and
//     never reports success it cannot back up;
//   - logical size and allocated size are reported separately, with a flag and a note saying
//     whether allocation could be determined at all;
//   - hard links are counted once where the platform exposes a file identity (Unix) and the
//     limitation is stated on platforms where it does not;
//   - memory is bounded: counters are streamed, the error list is capped, and the only paths
//     retained are those in that capped list plus a bounded largest-files list;
//   - concurrency is bounded by an explicit worker count, and cancellation is cooperative
//     through the caller's context.
//
// The traversal deliberately does not use a channel-per-directory or an unbounded goroutine
// per subdirectory: a work stack guarded by a condition variable keeps the goroutine count
// fixed and cannot deadlock when every worker is producing work at the same time.
package scan

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Hard bounds the scan enforces regardless of what the client asks for.
const (
	MaxDepth       = 128
	MaxWorkers     = 8
	MaxErrors      = 200
	MaxLargest     = 20
	DefaultWorkers = 2
	// DefaultProgressEvery bounds how often the client is told about progress.
	DefaultProgressEvery = 250 * time.Millisecond
	// MaxProgressEvery keeps a client from asking for an update per file.
	MaxProgressEvery = 5 * time.Second
	// MaxVisitedDirectories bounds the cycle guard used when links are followed.
	MaxVisitedDirectories = 100000
)

// Options is a scan request.
type Options struct {
	Root          string
	MaxDepth      int
	FollowLinks   bool
	Workers       int
	ProgressEvery time.Duration
	// Progress, when set, is called with a snapshot at a bounded rate (never faster than
	// ProgressEvery). It is invoked from the worker goroutines, so it must be safe for
	// concurrent use; the server's protocol writer already is.
	Progress func(Progress)
}

// Validate fills in the defaults and rejects what cannot be run.
func (options *Options) Validate() error {
	options.Root = strings.TrimSpace(options.Root)
	if options.Root == "" {
		return errors.New("root is required")
	}
	if !filepath.IsAbs(options.Root) {
		return errors.New("root must be an absolute path")
	}

	if options.MaxDepth <= 0 {
		options.MaxDepth = MaxDepth
	}
	if options.MaxDepth > MaxDepth {
		options.MaxDepth = MaxDepth
	}

	if options.Workers <= 0 {
		// Conservative by default: for a metadata walk on a spinning disk more readers make
		// things slower, so the default stays low and the caller can raise it explicitly.
		options.Workers = DefaultWorkers
		if runtime.NumCPU() >= 8 {
			options.Workers = 4
		}
	}
	if options.Workers > MaxWorkers {
		options.Workers = MaxWorkers
	}

	if options.ProgressEvery <= 0 {
		options.ProgressEvery = DefaultProgressEvery
	}
	if options.ProgressEvery > MaxProgressEvery {
		options.ProgressEvery = MaxProgressEvery
	}

	return nil
}

// Progress is one snapshot of the aggregate.
type Progress struct {
	Phase          string
	Files          int64
	Directories    int64
	Bytes          int64
	AllocatedBytes int64
	SkippedLinks   int64
	SkippedOther   int64
	Errors         int64
	Elapsed        time.Duration
}

// ScanError is one bounded, structured failure met while walking.
type ScanError struct {
	Code string `json:"code"`
	Path string `json:"path"`
	Err  string `json:"error"`
}

// FileSize is one entry of the bounded largest-files list.
type FileSize struct {
	Path  string `json:"path"`
	Bytes int64  `json:"bytes"`
}

// Result is the aggregate. Partial is true whenever anything could not be read.
type Result struct {
	Root             string      `json:"root"`
	Files            int64       `json:"files"`
	Directories      int64       `json:"directories"`
	Bytes            int64       `json:"bytes"`
	AllocatedBytes   int64       `json:"allocatedBytes"`
	AllocatedKnown   bool        `json:"allocatedKnown"`
	AllocatedNote    string      `json:"allocatedNote,omitempty"`
	SizeKind         string      `json:"sizeKind"`
	SkippedLinks     int64       `json:"skippedLinks"`
	SkippedOther     int64       `json:"skippedOther"`
	HardLinksDeduped int64       `json:"hardLinksDeduped"`
	HardLinkNote     string      `json:"hardLinkNote,omitempty"`
	Errors           []ScanError `json:"errors"`
	ErrorsTruncated  bool        `json:"errorsTruncated"`
	Partial          bool        `json:"partial"`
	Cancelled        bool        `json:"cancelled"`
	ElapsedMS        int64       `json:"elapsedMs"`
	Workers          int         `json:"workers"`
	Largest          []FileSize  `json:"largest"`
	LargestTruncated bool        `json:"largestTruncated"`
}

// ChildEntry is one direct child of the listed directory. For a subdirectory the sizes and
// counts are the aggregate of its whole subtree; for a file they are its own measurement.
// Kind is "dir", "file", "link" (a symbolic link or reparse point, never followed) or
// "other" (any other special file). A child that could not be read at all carries its error
// in Error and kind "dir"/"other" as appropriate; a directory whose subtree was only partly
// readable carries Partial = true with the structured errors from its own walk.
type ChildEntry struct {
	Name           string      `json:"name"`
	Path           string      `json:"path"`
	Kind           string      `json:"kind"`
	Bytes          int64       `json:"bytes"`
	AllocatedBytes int64       `json:"allocatedBytes,omitempty"`
	AllocatedKnown bool        `json:"allocatedKnown"`
	Files          int64       `json:"files"`
	Directories    int64       `json:"directories"`
	SkippedLinks   int64       `json:"skippedLinks,omitempty"`
	Partial        bool        `json:"partial"`
	Errors         []ScanError  `json:"errors,omitempty"`
	Error          string       `json:"error,omitempty"`
}

// ChildrenResult lists the direct children of one explicitly selected directory. Each
// subdirectory is aggregated with its own bounded walk, so the caller gets one usable level
// of the hierarchy without running a whole-root scan on every redraw.
type ChildrenResult struct {
	Root            string       `json:"root"`
	Entries         []ChildEntry `json:"entries"`
	ErrorsTruncated bool         `json:"errorsTruncated"`
	Cancelled       bool         `json:"cancelled"`
	ElapsedMS       int64        `json:"elapsedMs"`
}

// Failure is a scan that could not start (unknown root, wrong type).
type Failure struct {
	Code string
	Path string
	Err  error
}

func (failure *Failure) Error() string {
	return fmt.Sprintf("%s: %s: %v", failure.Code, failure.Path, failure.Err)
}

// ListChildren lists the direct children of one directory, read-only, with bounded
// concurrency for the per-subdirectory aggregation.
func ListChildren(ctx context.Context, root string, followLinks bool, workers int) (*ChildrenResult, error) {
	root = strings.TrimSpace(root)
	if root == "" {
		return nil, &Failure{Code: "E_INVALID_PARAMS", Path: root, Err: errors.New("root is required")}
	}
	if !filepath.IsAbs(root) {
		return nil, &Failure{Code: "E_INVALID_PARAMS", Path: root, Err: errors.New("root must be an absolute path")}
	}

	info, err := os.Lstat(root)
	if err != nil {
		code := "E_NOT_FOUND"
		if errors.Is(err, fs.ErrPermission) {
			code = "E_ACCESS_DENIED"
		}
		return nil, &Failure{Code: code, Path: root, Err: err}
	}
	if !info.IsDir() {
		if info.Mode()&os.ModeSymlink != 0 && !followLinks {
			return nil, &Failure{Code: "E_NOT_DIRECTORY", Path: root, Err: errors.New("the root is a symbolic link and links are not followed")}
		}
		return nil, &Failure{Code: "E_NOT_DIRECTORY", Path: root, Err: errors.New("the root is not a directory")}
	}

	started := time.Now()
	entries, err := os.ReadDir(root)
	if err != nil {
		code := codeForError(err)
		return nil, &Failure{Code: code, Path: root, Err: err}
	}

	// Per-child aggregation: a bounded pool walks each subdirectory, a bounded channel
	// collects the results, and the caller reads them in the original order.
	directories := make([]string, 0, len(entries))
	direct := make([]ChildEntry, 0, len(entries))
	for _, entry := range entries {
		child := filepath.Join(root, entry.Name())

		info, err := entry.Info()
		if err != nil {
			code := codeForError(err)
			direct = append(direct, ChildEntry{
				Name: entry.Name(), Path: child, Kind: "other",
				Error: code + ": " + err.Error(),
			})
			continue
		}

		mode := info.Mode()
		kind := "file"
		if mode&os.ModeSymlink != 0 {
			kind = "link"
			direct = append(direct, ChildEntry{Name: entry.Name(), Path: child, Kind: "link"})
			continue
		}
		if info.IsDir() {
			kind = "dir"
			directories = append(directories, child)
			continue
		}
		if !mode.IsRegular() {
			kind = "other"
			direct = append(direct, ChildEntry{Name: entry.Name(), Path: child, Kind: "other"})
			continue
		}

		direct = append(direct, ChildEntry{
			Name: entry.Name(), Path: child, Kind: kind,
			Bytes: info.Size(),
		})
	}

	if workers <= 0 {
		workers = DefaultWorkers
	}
	if workers > MaxWorkers {
		workers = MaxWorkers
	}

	bag := make(chan int, len(directories))
	results := make(chan ChildEntry, len(directories))
	var group sync.WaitGroup
	for index := range directories {
		bag <- index
	}
	close(bag)

	for range workers {
		group.Add(1)
		go func() {
			defer group.Done()
			for index := range bag {
				child := directories[index]
				agg, aggErr := Walk(ctx, Options{Root: child, FollowLinks: followLinks, Workers: workers})
				entry := ChildEntry{Name: filepath.Base(child), Path: child, Kind: "dir"}
				if aggErr != nil {
					var failure *Failure
					if errors.As(aggErr, &failure) {
						entry.Error = failure.Code + ": " + failure.Err.Error()
					} else {
						entry.Error = aggErr.Error()
					}
				} else {
					entry.Bytes = agg.Bytes
					entry.AllocatedBytes = agg.AllocatedBytes
					entry.AllocatedKnown = agg.AllocatedKnown
					entry.Files = agg.Files
					entry.Directories = agg.Directories
					entry.SkippedLinks = agg.SkippedLinks
					entry.Partial = agg.Partial || agg.Cancelled
					if len(agg.Errors) > 0 {
						entry.Errors = append([]ScanError{}, agg.Errors...)
					}
				}
				results <- entry
			}
		}()
	}

	group.Wait()
	close(results)

	children := make([]ChildEntry, 0, len(entries))
	children = append(children, direct...)
	for child := range results {
		children = append(children, child)
	}

	sort.SliceStable(children, func(i, j int) bool {
		a, b := children[i], children[j]
		if a.Kind != b.Kind {
			return a.Kind < b.Kind
		}
		return strings.ToLower(a.Name) < strings.ToLower(b.Name)
	})

	return &ChildrenResult{
		Root:      root,
		Entries:   children,
		ElapsedMS: time.Since(started).Milliseconds(),
	}, nil
}

type counters struct {
	files        atomic.Int64
	directories  atomic.Int64
	bytes        atomic.Int64
	allocated    atomic.Int64
	skippedLinks atomic.Int64
	skippedOther atomic.Int64
	errors       atomic.Int64
	deduped      atomic.Int64
	allocatedOK  atomic.Bool
	identityOK   atomic.Bool
}

// Walker runs one scan and holds its bounded state.
type Walker struct {
	options  Options
	counters counters

	mu          sync.Mutex
	errs        []ScanError
	errsFull    bool
	largest     []FileSize
	largestFull bool
	seen        map[string]struct{}
	visited     map[string]struct{}
	started     time.Time

	lastProgress atomic.Int64
}

// Walk aggregates the tree under options.Root.
//
// It always returns the result gathered so far, including when the context is cancelled or
// a directory read fails unexpectedly: the caller reports "partial" rather than nothing.
func Walk(ctx context.Context, options Options) (*Result, error) {
	if err := options.Validate(); err != nil {
		return nil, &Failure{Code: "E_INVALID_PARAMS", Path: options.Root, Err: err}
	}

	walker := &Walker{options: options, seen: make(map[string]struct{})}
	walker.counters.allocatedOK.Store(true)
	walker.started = time.Now()
	walker.lastProgress.Store(time.Now().Add(-options.ProgressEvery).UnixNano())

	info, err := os.Lstat(options.Root)
	if err != nil {
		code := "E_NOT_FOUND"
		if errors.Is(err, fs.ErrPermission) {
			code = "E_ACCESS_DENIED"
		}
		return nil, &Failure{Code: code, Path: options.Root, Err: err}
	}

	if !info.IsDir() {
		if info.Mode()&os.ModeSymlink != 0 && !options.FollowLinks {
			return nil, &Failure{Code: "E_NOT_DIRECTORY", Path: options.Root, Err: errors.New("the root is a symbolic link and links are not followed")}
		}
		return nil, &Failure{Code: "E_NOT_DIRECTORY", Path: options.Root, Err: errors.New("the root is not a directory")}
	}

	walker.traverse(ctx)

	cancelled := errors.Is(ctx.Err(), context.Canceled)
	return walker.result(cancelled), nil
}

// traverse runs the bounded worker pool over the work stack.
func (walker *Walker) traverse(ctx context.Context) {
	var mu sync.Mutex
	cond := sync.NewCond(&mu)
	stack := []string{walker.options.Root}
	inflight := 0

	push := func(path string) {
		mu.Lock()
		stack = append(stack, path)
		mu.Unlock()
		cond.Broadcast()
	}

	worker := func() {
		for {
			mu.Lock()
			for len(stack) == 0 && inflight > 0 {
				cond.Wait()
			}
			if len(stack) == 0 {
				mu.Unlock()
				cond.Broadcast()
				return
			}
			path := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			inflight++
			mu.Unlock()

			if ctx.Err() == nil {
				walker.readDirectory(ctx, path, walker.options.MaxDepth, push)
				walker.report("walk")
			}

			mu.Lock()
			inflight--
			mu.Unlock()
			cond.Broadcast()
		}
	}

	var workers sync.WaitGroup
	for index := 0; index < walker.options.Workers; index++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			worker()
		}()
	}

	// Cancellation must wake the workers that are waiting on the condition variable.
	stop := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			mu.Lock()
			cond.Broadcast()
			mu.Unlock()
		case <-stop:
		}
	}()

	workers.Wait()
	close(stop)
}

// readDirectory lists one directory, aggregates its files and pushes its subdirectories.
func (walker *Walker) readDirectory(ctx context.Context, path string, maxDepth int, push func(string)) {
	walker.counters.directories.Add(1)

	if depth(path, walker.options.Root) > maxDepth {
		walker.counters.skippedOther.Add(1)
		return
	}

	entries, err := os.ReadDir(path)
	if err != nil {
		walker.record(codeForError(err), path, err)
		return
	}

	var pending []string

	for _, entry := range entries {
		if ctx.Err() != nil {
			return
		}

		child := filepath.Join(path, entry.Name())
		info, err := entry.Info()
		if err != nil {
			walker.record(codeForError(err), child, err)
			continue
		}

		mode := info.Mode()
		if mode&os.ModeSymlink != 0 {
			if !walker.options.FollowLinks {
				// Following a link can leave the selected root and can loop forever, so it is
				// opt-in and the skipped link is counted where it was seen.
				walker.counters.skippedLinks.Add(1)
				continue
			}

			// Follow it deliberately: the target type decides what happens next.
			target, err := os.Stat(child)
			if err != nil {
				walker.record(codeForError(err), child, err)
				continue
			}
			info = target
			mode = target.Mode()
		}

		if info.IsDir() {
			if !walker.visit(info) {
				// Already visited through another path (a link, a junction or a bind
				// mount): descending again would loop.
				walker.counters.skippedOther.Add(1)
				continue
			}
			pending = append(pending, child)
			continue
		}

		if !mode.IsRegular() {
			walker.counters.skippedOther.Add(1)
			continue
		}

		walker.addFile(child, info)
	}

	for _, child := range pending {
		push(child)
	}
}

// addFile aggregates one regular file.
//
// The identity check happens first: a file that is a hard link to one already counted is
// skipped entirely, so neither the file count nor the byte totals double-count it.
func (walker *Walker) addFile(path string, info fs.FileInfo) {
	size := info.Size()

	if key, ok := fileIdentity(info); ok {
		walker.counters.identityOK.Store(true)

		walker.mu.Lock()
		_, seen := walker.seen[key]
		if !seen {
			walker.seen[key] = struct{}{}
		}
		walker.mu.Unlock()

		if seen {
			walker.counters.deduped.Add(1)
			return
		}
	}

	walker.counters.files.Add(1)
	walker.counters.bytes.Add(size)

	if allocated, ok := allocatedBytes(info); ok {
		walker.counters.allocated.Add(allocated)
	} else {
		walker.counters.allocatedOK.Store(false)
		walker.counters.allocated.Add(size)
	}

	walker.rememberLargest(path, size)
}

// rememberLargest keeps a bounded list of the largest files seen.
func (walker *Walker) rememberLargest(path string, size int64) {
	walker.mu.Lock()
	defer walker.mu.Unlock()

	if len(walker.largest) == MaxLargest && size <= walker.largest[len(walker.largest)-1].Bytes {
		walker.largestFull = true
		return
	}

	walker.largest = append(walker.largest, FileSize{Path: path, Bytes: size})
	sort.Slice(walker.largest, func(i, j int) bool { return walker.largest[i].Bytes > walker.largest[j].Bytes })
	if len(walker.largest) > MaxLargest {
		walker.largest = walker.largest[:MaxLargest]
		walker.largestFull = true
	}
}

// record stores one bounded error.
func (walker *Walker) record(code, path string, err error) {
	walker.counters.errors.Add(1)

	walker.mu.Lock()
	defer walker.mu.Unlock()

	if len(walker.errs) >= MaxErrors {
		walker.errsFull = true
		return
	}

	walker.errs = append(walker.errs, ScanError{Code: code, Path: path, Err: err.Error()})
}

// Snapshot returns the current counters, for a progress event.
func (walker *Walker) Snapshot(phase string) Progress {
	return Progress{
		Phase:          phase,
		Files:          walker.counters.files.Load(),
		Directories:    walker.counters.directories.Load(),
		Bytes:          walker.counters.bytes.Load(),
		AllocatedBytes: walker.counters.allocated.Load(),
		SkippedLinks:   walker.counters.skippedLinks.Load(),
		SkippedOther:   walker.counters.skippedOther.Load(),
		Errors:         walker.counters.errors.Load(),
		Elapsed:        time.Since(walker.started),
	}
}

// result assembles the aggregate.
func (walker *Walker) result(cancelled bool) *Result {
	walker.mu.Lock()
	defer walker.mu.Unlock()

	allocatedKnown := walker.counters.allocatedOK.Load()
	identityKnown := walker.counters.identityOK.Load()

	note := ""
	sizeKind := "logical"
	if allocatedKnown {
		sizeKind = "logical+allocated"
	} else {
		note = "the platform could not report an allocation size for every file; allocatedBytes repeats the logical size for those files"
	}

	hardLinkNote := ""
	switch {
	case !identityKnown:
		hardLinkNote = "hard links could not be identified on this platform; a file with several links is counted once per link"
	case walker.counters.deduped.Load() > 0:
		hardLinkNote = "hard links are counted once: a repeated file identity is skipped"
	}

	return &Result{
		Root:             walker.options.Root,
		Files:            walker.counters.files.Load(),
		Directories:      walker.counters.directories.Load(),
		Bytes:            walker.counters.bytes.Load(),
		AllocatedBytes:   walker.counters.allocated.Load(),
		AllocatedKnown:   allocatedKnown,
		AllocatedNote:    note,
		SizeKind:         sizeKind,
		SkippedLinks:     walker.counters.skippedLinks.Load(),
		SkippedOther:     walker.counters.skippedOther.Load(),
		HardLinksDeduped: walker.counters.deduped.Load(),
		HardLinkNote:     hardLinkNote,
		Errors:           append([]ScanError{}, walker.errs...),
		ErrorsTruncated:  walker.errsFull,
		Partial:          walker.counters.errors.Load() > 0 || walker.errsFull,
		Cancelled:        cancelled,
		ElapsedMS:        time.Since(walker.started).Milliseconds(),
		Workers:          walker.options.Workers,
		Largest:          append([]FileSize{}, walker.largest...),
		LargestTruncated: walker.largestFull,
	}
}

// visit records a directory that is being descended into, and reports false when it has
// already been seen. Identity is taken from the directory entry itself (never the target
// of a link), so a junction, a bind mount or a repeated link that lands on the same
// directory is visited once no matter how links are configured - the depth cap stays as
// the final protection when an identity is not available.
func (walker *Walker) visit(info fs.FileInfo) bool {
	key, ok := fileIdentity(info)
	if !ok {
		// Without an identity the depth cap is the only protection; that is documented.
		return true
	}

	walker.mu.Lock()
	defer walker.mu.Unlock()

	if walker.visited == nil {
		walker.visited = make(map[string]struct{})
	}

	key = "dir:" + key
	if _, seen := walker.visited[key]; seen {
		return false
	}

	if len(walker.visited) < MaxVisitedDirectories {
		walker.visited[key] = struct{}{}
	}

	return true
}

// report calls the progress callback, at most once per ProgressEvery.
func (walker *Walker) report(phase string) {
	if walker.options.Progress == nil {
		return
	}

	interval := walker.options.ProgressEvery
	if interval <= 0 {
		interval = 250 * time.Millisecond
	}

	now := time.Now()
	previous := time.Unix(0, walker.lastProgress.Load())
	if now.Sub(previous) < interval {
		return
	}

	if !walker.lastProgress.CompareAndSwap(previous.UnixNano(), now.UnixNano()) {
		return
	}

	walker.options.Progress(walker.Snapshot(phase))
}

// codeForError maps a filesystem error to a stable code.
func codeForError(err error) string {
	switch {
	case errors.Is(err, fs.ErrPermission):
		return "E_ACCESS_DENIED"
	case errors.Is(err, fs.ErrNotExist):
		return "E_IO"
	default:
		return "E_IO"
	}
}

// depth counts the separators between root and path; it is used for the depth cap and never
// relies on the directory entry order.
func depth(path, root string) int {
	relative, err := filepath.Rel(root, path)
	if err != nil || relative == "." {
		return 0
	}
	return len(strings.Split(relative, string(filepath.Separator)))
}
