package scan

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// buildTree creates the fixture the scan tests share:
//
//	root/f1.txt         5 bytes
//	root/f1-hard.txt    hard link to f1.txt
//	root/a/f2.txt       10 bytes
//	root/a/b/f3.txt     3 bytes
//	root/c/tệp việt.txt 5 bytes
//	root/link-outside   symbolic link to a directory outside the root
func buildTree(t *testing.T) string {
	t.Helper()

	root := t.TempDir()
	writeFile(t, filepath.Join(root, "f1.txt"), 5)
	writeFile(t, filepath.Join(root, "a", "f2.txt"), 10)
	writeFile(t, filepath.Join(root, "a", "b", "f3.txt"), 3)
	writeFile(t, filepath.Join(root, "c", "tệp việt.txt"), 5)

	if err := os.Symlink(t.TempDir(), filepath.Join(root, "link-outside")); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	if err := os.Link(filepath.Join(root, "f1.txt"), filepath.Join(root, "f1-hard.txt")); err != nil {
		t.Logf("hard links are unavailable here (%v); the dedupe assertion is skipped", err)
	}

	return root
}

func writeFile(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func TestWalkAggregatesAndStaysInsideTheRoot(t *testing.T) {
	root := buildTree(t)

	result, err := Walk(context.Background(), Options{Root: root})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}

	if result.Files != 4 {
		t.Fatalf("expected 4 files (the hard link is deduplicated), got %d", result.Files)
	}
	if result.Bytes != 23 {
		t.Fatalf("expected 23 logical bytes, got %d", result.Bytes)
	}
	if result.Directories != 4 {
		t.Fatalf("expected 4 directories, got %d", result.Directories)
	}
	if result.SkippedLinks != 1 {
		t.Fatalf("expected the symbolic link to be skipped, skipped=%d", result.SkippedLinks)
	}
	if result.Partial {
		t.Fatalf("a clean tree must not be reported as partial: %+v", result.Errors)
	}
	if result.Cancelled {
		t.Fatal("a completed walk must not report itself as cancelled")
	}
	if !result.AllocatedKnown && runtime.GOOS == "linux" {
		t.Logf("allocation size unavailable: %s", result.AllocatedNote)
	}
	if result.SizeKind != "logical+allocated" && result.SizeKind != "logical" {
		t.Fatalf("unexpected size kind %q", result.SizeKind)
	}
	if len(result.Largest) == 0 || result.Largest[0].Bytes != 10 {
		t.Fatalf("largest list looks wrong: %+v", result.Largest)
	}
}

func TestWalkDeduplicatesHardLinks(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "a.txt"), 7)

	if err := os.Link(filepath.Join(root, "a.txt"), filepath.Join(root, "b.txt")); err != nil {
		t.Skipf("hard links are unavailable on this platform: %v", err)
	}

	result, err := Walk(context.Background(), Options{Root: root})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}

	if result.Files != 1 {
		t.Fatalf("expected the hard link to be counted once, got %d files", result.Files)
	}
	if result.Bytes != 7 {
		t.Fatalf("expected 7 bytes once, got %d", result.Bytes)
	}
	if result.HardLinksDeduped != 1 {
		t.Fatalf("expected one deduplicated link, got %d", result.HardLinksDeduped)
	}
}

func TestWalkReportsAccessDeniedAsPartial(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("running with privileges that ignore directory permissions")
	}

	root := t.TempDir()
	writeFile(t, filepath.Join(root, "ok.txt"), 3)
	denied := filepath.Join(root, "denied")
	writeFile(t, filepath.Join(denied, "hidden.txt"), 4)
	if err := os.Chmod(denied, 0o000); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(denied, 0o755) })

	result, err := Walk(context.Background(), Options{Root: root})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}

	if !result.Partial {
		t.Fatal("a directory that cannot be read must make the result partial")
	}
	if len(result.Errors) == 0 || result.Errors[0].Code != "E_ACCESS_DENIED" {
		t.Fatalf("expected an E_ACCESS_DENIED error, got %+v", result.Errors)
	}
	if result.Files != 1 {
		t.Fatalf("the readable file must still be counted, files=%d", result.Files)
	}
}

func TestWalkCancellationReturnsPartialResult(t *testing.T) {
	root := t.TempDir()
	for index := 0; index < 400; index++ {
		writeFile(t, filepath.Join(root, "d", "f.txt"), 1+index%7)
		os.MkdirAll(filepath.Join(root, "d"), 0o755)
	}
	for index := 0; index < 200; index++ {
		directory := filepath.Join(root, "sub", string(rune('a'+index%26)), string(rune('a'+index%13)))
		writeFile(t, filepath.Join(directory, "f.txt"), 1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	result, err := Walk(ctx, Options{Root: root})
	if err != nil {
		t.Fatalf("a cancelled walk must return its partial result, got error %v", err)
	}
	if !result.Cancelled {
		t.Fatal("the result must say it was cancelled")
	}
}

func TestWalkValidatesTheRequest(t *testing.T) {
	if _, err := Walk(context.Background(), Options{Root: "relative/path"}); err == nil {
		t.Fatal("a relative root must be rejected")
	}

	var failure *Failure
	if _, err := Walk(context.Background(), Options{Root: ""}); !errors.As(err, &failure) || failure.Code != "E_INVALID_PARAMS" {
		t.Fatalf("expected E_INVALID_PARAMS, got %v", err)
	}

	root := t.TempDir()
	writeFile(t, filepath.Join(root, "file.txt"), 1)
	if _, err := Walk(context.Background(), Options{Root: filepath.Join(root, "file.txt")}); !errors.As(err, &failure) || failure.Code != "E_NOT_DIRECTORY" {
		t.Fatalf("expected E_NOT_DIRECTORY, got %v", err)
	}

	if _, err := Walk(context.Background(), Options{Root: filepath.Join(root, "missing")}); !errors.As(err, &failure) || failure.Code != "E_NOT_FOUND" {
		t.Fatalf("expected E_NOT_FOUND, got %v", err)
	}
}

func TestValidateClampsBounds(t *testing.T) {
	options := Options{Root: "/tmp", Workers: 999, MaxDepth: 100000}
	if err := options.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
	if options.Workers != MaxWorkers {
		t.Fatalf("workers must be clamped to %d, got %d", MaxWorkers, options.Workers)
	}
	if options.MaxDepth != MaxDepth {
		t.Fatalf("depth must be clamped to %d, got %d", MaxDepth, options.MaxDepth)
	}
	if options.ProgressEvery <= 0 {
		t.Fatal("a progress interval must be set")
	}
}

func TestWalkHonoursTheDepthCap(t *testing.T) {
	root := t.TempDir()
	deep := root
	for index := 0; index < 8; index++ {
		deep = filepath.Join(deep, "level")
	}
	writeFile(t, filepath.Join(deep, "deep.txt"), 4)
	writeFile(t, filepath.Join(root, "shallow.txt"), 2)

	result, err := Walk(context.Background(), Options{Root: root, MaxDepth: 2})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}

	if result.Files != 1 || result.Bytes != 2 {
		t.Fatalf("files beyond the depth cap must not be counted: files=%d bytes=%d", result.Files, result.Bytes)
	}
}

func TestWalkReportsProgressAtABoundedRate(t *testing.T) {
	root := t.TempDir()
	for index := 0; index < 60; index++ {
		writeFile(t, filepath.Join(root, "d", "f.txt"), 1+index)
	}

	var calls int
	result, err := Walk(context.Background(), Options{
		Root:          root,
		ProgressEvery: 5 * time.Millisecond,
		Progress:      func(Progress) { calls++ },
	})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
	if result.Files == 0 {
		t.Fatal("nothing was counted")
	}
	if calls > 200 {
		t.Fatalf("progress was reported %d times for a tiny tree: the rate is not bounded", calls)
	}
}

func TestWalkFollowsLinksOnlyWhenAsked(t *testing.T) {
	outside := t.TempDir()
	writeFile(t, filepath.Join(outside, "secret.txt"), 11)

	root := t.TempDir()
	writeFile(t, filepath.Join(root, "inside.txt"), 2)
	if err := os.Symlink(outside, filepath.Join(root, "outside")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	result, err := Walk(context.Background(), Options{Root: root})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
	if result.Bytes != 2 {
		t.Fatalf("the walk left the selected root: bytes=%d", result.Bytes)
	}

	followed, err := Walk(context.Background(), Options{Root: root, FollowLinks: true})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
	if followed.Bytes != 13 {
		t.Fatalf("with FollowLinks the target is walked and the result must reflect that: bytes=%d", followed.Bytes)
	}
}

var _ fs.FileInfo

func TestListChildrenListsDirectChildrenWithSubtreeAggregates(t *testing.T) {
	root := buildTree(t)

	result, err := ListChildren(context.Background(), root, false, 0)
	if err != nil {
		t.Fatalf("list: %v", err)
	}

	var dirA, fileF1, link *ChildEntry
	for index := range result.Entries {
		entry := &result.Entries[index]
		switch entry.Name {
		case "a":
			dirA = entry
		case "f1.txt":
			fileF1 = entry
		case "link-outside":
			link = entry
		}
	}

	if dirA == nil || fileF1 == nil || link == nil {
		t.Fatalf("expected direct children a, f1.txt and link-outside, got %+v", result.Entries)
	}
	if dirA.Kind != "dir" {
		t.Fatalf("a must be a directory, got %s", dirA.Kind)
	}
	// a contains f2.txt (10) and b (which contains f3.txt, 3).
	if dirA.Bytes != 13 {
		t.Fatalf("subtree aggregate for a must be 13, got %d", dirA.Bytes)
	}
	if dirA.Files != 2 || dirA.Directories != 2 {
		t.Fatalf("a must have 2 files and 1 subdirectory, got files=%d dirs=%d", dirA.Files, dirA.Directories)
	}
	if fileF1.Kind != "file" || fileF1.Bytes != 5 {
		t.Fatalf("f1.txt must be a 5-byte file, got %+v", fileF1)
	}
	if link.Kind != "link" {
		t.Fatalf("a symlink child must be listed as a link, got %s", link.Kind)
	}
}

func TestListChildrenReportsPartialAndErrorsForUnreadableSubdirs(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "ok.txt"), 1)

	if runtime.GOOS == "windows" {
		t.Skip("permission bits are not enforced the same way on Windows")
	}

	blocked := filepath.Join(root, "blocked")
	if err := os.Mkdir(blocked, 0o000); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(blocked, 0o755) })

	result, err := ListChildren(context.Background(), root, false, 0)
	if err != nil {
		t.Fatalf("list: %v", err)
	}

	var blockedEntry *ChildEntry
	for index := range result.Entries {
		if result.Entries[index].Name == "blocked" {
			blockedEntry = &result.Entries[index]
		}
	}
	if blockedEntry == nil {
		t.Fatal("the blocked directory must still be listed")
	}
	if blockedEntry.Error == "" && !blockedEntry.Partial && len(blockedEntry.Errors) == 0 {
		t.Fatal("the blocked directory must carry its read error")
	}
}

func TestListChildrenRejectsRelativeAndMissingRoots(t *testing.T) {
	if _, err := ListChildren(context.Background(), "relative/path", false, 0); err == nil {
		t.Fatal("a relative root must be rejected")
	}
	if _, err := ListChildren(context.Background(), filepath.Join(t.TempDir(), "missing"), false, 0); err == nil {
		t.Fatal("a missing root must be rejected")
	}
}

func TestListChildrenSkipsSymlinkTargets(t *testing.T) {
	outside := t.TempDir()
	writeFile(t, filepath.Join(outside, "secret.txt"), 100)

	root := t.TempDir()
	writeFile(t, filepath.Join(root, "inside.txt"), 2)
	if err := os.Symlink(outside, filepath.Join(root, "outside")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	result, err := ListChildren(context.Background(), root, false, 0)
	if err != nil {
		t.Fatalf("list: %v", err)
	}

	total := int64(0)
	for index := range result.Entries {
		total += result.Entries[index].Bytes
	}
	if total != 2 {
		t.Fatalf("the listing walked into a symlink target: total=%d", total)
	}
}
