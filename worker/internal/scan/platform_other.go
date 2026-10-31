//go:build !unix && !windows

package scan

import "io/fs"

// allocatedBytes: this platform does not expose an allocation size here. Reporting
// "unknown" is better than inventing one.
func allocatedBytes(fs.FileInfo) (int64, bool) {
	return 0, false
}

// fileIdentity: no portable identity, so hard links cannot be deduplicated here.
func fileIdentity(fs.FileInfo) (string, bool) {
	return "", false
}
