//go:build !linux

package metric

import "errors"

// Other platforms (Windows included): the worker does not ship a statfs implementation
// for them; the providers report unsupported instead. This stub keeps the package
// cross-compilable.
type syscallStatfs struct {
	Bavail int64
	Bsize  int64
	Blocks int64
}

func statfs(path string, stat *syscallStatfs) error {
	return errors.New("E_UNSUPPORTED_PROVIDER: statfs is not implemented on this platform")
}
