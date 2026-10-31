//go:build unix

package scan

import (
	"fmt"
	"io/fs"
	"syscall"
)

// allocatedBytes returns the space the file actually occupies. On Unix this is the block
// count the filesystem reports, which is what "size on disk" means there.
func allocatedBytes(info fs.FileInfo) (int64, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}

	return stat.Blocks * 512, true
}

// fileIdentity returns a key that is stable across hard links to the same file, so the
// same inode is only counted once.
func fileIdentity(info fs.FileInfo) (string, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", false
	}

	return fmt.Sprintf("%d:%d", uint64(stat.Dev), stat.Ino), true
}
