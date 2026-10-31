//go:build windows

package scan

import "io/fs"

// Windows notes for the reader of this file:
//
//   - The worker is compiled for windows/amd64 and windows/arm64 on every build
//     (`GOOS=windows go build ./...`) and vetted with `go vet`, but the code in this file has
//     not been executed on a real Windows host as part of this project's validation. The
//     cross-compile proves it compiles; it does not prove it behaves. docs/WORKER.md states
//     this explicitly.
//
//   - allocatedBytes returns "unknown" rather than guessing. Querying the real on-disk size
//     on Windows means GetCompressedFileSizeW or FILE_STANDARD_INFO, both of which need the
//     full path (fs.FileInfo only carries the base name) and unsafe syscall plumbing that
//     cannot be validated here. The scan therefore reports logical size only, sets
//     allocatedKnown = false, and explains it in allocatedNote - which is the honest answer
//     until the Windows path can be tested on Windows.
//
//   - fileIdentity returns "unknown" for the same reason: identifying a hard link needs the
//     volume serial number and the file index from GetFileInformationByHandle. Until that is
//     implemented and tested, hard-linked files are counted once per link and the result
//     says so in hardLinkNote.
func allocatedBytes(fs.FileInfo) (int64, bool) {
	return 0, false
}

func fileIdentity(fs.FileInfo) (string, bool) {
	return "", false
}
