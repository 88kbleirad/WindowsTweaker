# Optional background worker (`wt-worker`)

A small, **read-only**, unprivileged Go program that WindowsTweaker can start as a child
process to do measured work off the PowerShell interpreter. It is optional: the PowerShell
implementation stays available, is used automatically when the worker is missing, and is the
comparison baseline for every benchmark.

What the worker deliberately does **not** do:

* it never writes a Windows setting, a registry value, a service, a task, a package or a file;
* it does not implement the change engine, the journal writer or the rollback system - those
  stay in PowerShell, where the confirmation, the capture and the recovery live;
* it is not a service, a listener, a tray application or a scheduled task;
* it never reads terminal keys, never writes ANSI sequences and never draws anything;
* it does not install dependencies, and it is not started as administrator.

## Status

| Area | State |
|---|---|
| Linux (amd64, arm64) | built, tested and benchmarked in this repository (`go test ./...`, `-race`, integration tests, benchmarks) |
| Windows (amd64, arm64) | **cross-compiled and `go vet`-checked only.** No Windows host was available while implementing this, so the worker has **not** been executed on Windows. See "Windows checks not executed" below |
| Capabilities implemented | `scan.directory` (read-only directory aggregation) |
| Capabilities planned, not implemented | `scan.hash`, `net.dns`, `net.tcp` - not advertised in the handshake until they work |

The handshake advertises exactly what is implemented: a client must treat an unlisted
capability as unavailable, and a listed capability as working.

## Layout

```
worker/
  go.mod                        module wintweaker.dev/worker (SQLite store, Prometheus client)
  cmd/wt-worker/main.go         entry point: stdin/stdout protocol, stderr diagnostics
  internal/protocol/            message types, version, single serialised writer, capped reader
  internal/scan/                the capability: bounded walk + size aggregation (+ tests)
  internal/server/              request loop, concurrency limit, cancellation, shutdown (+ tests)
  bin/<os>-<arch>/wt-worker     built binaries
tools/Measure-WtWorker.ps1      reproducible PowerShell-vs-Go benchmark
tests/Worker.Tests.ps1          PowerShell-side integration tests
```

## Protocol (version 1)

* Transport: the child's **stdin/stdout**, one UTF-8 **JSON object per line** (LF).
* `stdout` carries protocol messages only. `stderr` carries bounded diagnostic lines
  (`wt-worker: <message>`); the client keeps at most the last 64 of them.
* One writer goroutine serialises stdout, so two concurrent tasks can never interleave
  messages inside a line.
* Both streams are **UTF-8 on every runtime**: the client writes the request line through its
  own `StreamWriter` (`UTF8Encoding($false)`, LF) because `ProcessStartInfo.StandardInputEncoding`
  does not exist on .NET Framework, and it sets `StandardOutputEncoding`/`StandardErrorEncoding`
  explicitly. A Vietnamese path in a request therefore reaches the worker intact from Windows
  PowerShell 5.1 and from PowerShell 7 alike.
* Request lines are capped at **1 MiB**; a longer line is rejected with
  `E_MESSAGE_TOO_LARGE` and the remainder of that line is discarded so the stream stays
  usable. Emitted messages are capped at 4 MiB (the result caps make that unreachable in
  practice).

### Client → worker

```json
{"v":1,"id":"1","op":"hello"}
{"v":1,"id":"2","op":"scan.directory","params":{"root":"C:\\Users","maxDepth":64,"followLinks":false,"workers":4},"timeoutMs":60000}
{"v":1,"id":"3","op":"cancel","params":{"target":"2"}}
{"v":1,"id":"4","op":"shutdown"}
```

| Operation | Parameters | Notes |
|---|---|---|
| `hello` | - | capability handshake; answers with version, protocol, os/arch, capabilities and the enforced limits |
| `scan.directory` | `root` (absolute, required), `maxDepth` (≤128), `followLinks` (default false), `workers` (≤8) | read-only aggregation |
| `cancel` | `target` (the request id) | cooperative; answers `completed` when the target is not running |
| `shutdown` | - | cancels every job, waits within the grace period, exits 0 |

Every request needs an `id` and `v`. A message with another `v` gets exactly one
`E_PROTOCOL_VERSION` error and the worker exits, rather than guessing the dialect.

### Worker → client

```json
{"v":1,"type":"hello","id":"1","hello":{"worker":"wt-worker","version":"0.1.0","protocol":1,
  "goVersion":"go1.27.3","os":"linux","arch":"amd64","capabilities":["scan.directory"],
  "limits":{"maxLineBytes":1048576,"maxErrors":200,"scanWorkers":8,"maxScanDepth":128,
            "progressEveryMs":250,"maxResultPaths":220,"maxConcurrentJobs":4}}}
{"v":1,"type":"progress","id":"2","progress":{"phase":"walk","files":1200,"directories":80,
  "bytes":12345678,"allocatedBytes":12582912,"skipped":3,"errors":1,"elapsedMs":320}}
{"v":1,"type":"result","id":"2","result":{ ...see below... }}
{"v":1,"type":"error","id":"2","error":{"code":"E_ACCESS_DENIED","message":"...","detail":"..."}}
{"v":1,"type":"cancelled","id":"2","cancelled":{"ack":true,"state":"stopped","elapsedMs":180}}
```

Progress is emitted at most every 250 ms (`progressEveryMs`), which is what keeps a terminal
repaint from being flooded. `state` distinguishes the phases of cancellation:
`stopping` (acknowledged, the job is unwinding), `stopped` (the job has finished unwinding),
`completed` (there was nothing to cancel).

### Stable error codes

| Code | Meaning |
|---|---|
| `E_PROTOCOL_VERSION` | the client speaks another protocol version |
| `E_BAD_JSON` | the line was not valid JSON |
| `E_MESSAGE_TOO_LARGE` | the line exceeded the size cap |
| `E_INVALID_PARAMS` | the request is missing an id, or its parameters do not validate |
| `E_UNKNOWN_OP` | the operation is not implemented by this build |
| `E_NOT_FOUND` | the root does not exist |
| `E_NOT_DIRECTORY` | the root is not a directory (or is a link and links are not followed) |
| `E_ACCESS_DENIED` | a path could not be read (also reported per path inside a partial result) |
| `E_IO` | an unexpected filesystem error |
| `E_TIMEOUT` | the request exceeded its timeout |
| `E_CANCELLED` | the request was cancelled |
| `E_BUSY` | too many requests are running at once |
| `E_INTERNAL` | the worker failed internally |

The codes are stable identifiers: the **interface** owns the wording (English and Vietnamese
strings live in `Data/Strings.<lang>.psd1`), the worker never returns prose meant to be shown.

### `scan.directory` result

```json
{
  "root": "/home/user",
  "files": 2000, "directories": 41,
  "bytes": 11254784, "allocatedBytes": 12582912, "allocatedKnown": true, "allocatedNote": "",
  "sizeKind": "logical+allocated",
  "skippedLinks": 1, "skippedOther": 0,
  "hardLinksDeduped": 1, "hardLinkNote": "hard links are counted once: a repeated file identity is skipped",
  "errors": [{"code":"E_ACCESS_DENIED","path":"/home/user/private","error":"open ...: permission denied"}],
  "errorsTruncated": false, "partial": true, "cancelled": false,
  "elapsedMs": 46, "workers": 4,
  "largest": [{"path":"/home/user/big.iso","bytes":734003200}], "largestTruncated": true
}
```

* `bytes` is the **logical** size (what the filesystem reports for each file).
* `allocatedBytes` is the **allocated** size where the platform exposes it: block count on
  Unix. `allocatedKnown` says whether it could be determined at all, and `allocatedNote`
  explains a fallback. On Windows the worker currently reports logical size only and sets
  `allocatedKnown = false` (see below).
* `partial` is true whenever anything could not be read. A partial result is still a result:
  the errors are listed (bounded to 200, with `errorsTruncated`), never hidden.
* Hard links are counted once where a file identity is available (Unix `dev:ino`); where it is
  not, `hardLinkNote` says so and each link is counted.
* Symbolic links and reparse points are skipped by default and counted in `skippedLinks`;
  `followLinks` opts in, with a bounded cycle guard.

## Controlled concurrency and memory

* A fixed worker pool (`workers`, default 2, 4 on an 8-core machine, hard cap 8) drains a
  mutex-guarded work stack. There is no goroutine per directory, so a deep or wide tree cannot
  explode the goroutine count, and the pool cannot deadlock when every worker is producing
  work at the same time.
* At most `MaxConcurrentJobs` (4) requests run at once; further requests get `E_BUSY`.
* One directory is held open per worker, so the open-handle count is bounded by the pool.
* Memory is bounded: counts are streamed, the error list is capped at 200 entries, the largest
  files list at 20, and progress is throttled. Nothing accumulates per file.
* Cancellation is cooperative through a `context`; the reply distinguishes `stopping` from
  `stopped`. The worker spawns **no** native subprocesses, so there is no child to reap;
  process lifecycle is the client's business.

## PowerShell side

| Setting / parameter | Values | Meaning |
|---|---|---|
| `settings.json` → `backend` | `Auto`, `Go`, `PowerShell` | saved preference |
| `-WorkerBackend` (entry point) | `Auto`, `Go`, `PowerShell` | one-run override, wins over the setting |
| `$env:WT_WORKER_PATH` | path | explicit worker location (packaging/tests); never a PATH lookup |
| `Get-WtWorkerStatus` | - | path, installed/available, protocol, capabilities, resolved backend |
| `Set-WtWorkerBackend` | `Auto`, `Go`, `PowerShell` | saves the preference |
| `Invoke-WtDirectoryScan -Root <path>` | - | the capability, one result shape for both backends |
| `Measure-WtWorkerOverhead` | - | startup + protocol round-trip cost, worker memory |

Resolution: `Auto` uses the worker when it is installed **and** protocol-compatible, and
otherwise uses PowerShell *with the reason reported*; `Go` never falls back (the capability is
reported unavailable instead); `PowerShell` always uses the baseline. Nothing is fabricated:
a transport error is reported as a transport error, and a finished operation is never retried.

Shutdown: the client sends `shutdown`, waits up to 2 s for the process to exit, and only then
kills it (`Kill($true)`) as the documented final termination path for this read-only worker.
The terminal state (cursor, colours, alternate screen) is restored by the existing `finally`
blocks, and a crashed worker is reported as `E_WORKER_EXITED` instead of trapping the user.

## Build

Supported toolchain: **Go 1.26 or newer** (the module declares `go 1.26.0`; this repository was
built and tested with the Go toolchain available on the development host).

```bash
cd worker

# test (including the race detector)
go test ./...
go test -race ./...

# build for the machine you are on
go build -trimpath -ldflags "-s -w -X main.Version=0.1.0" -o bin/linux-amd64/wt-worker ./cmd/wt-worker

# cross-compile the Windows binaries (compiles + vets only; not a Windows runtime check)
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.Version=0.1.0" -o bin/windows-amd64/wt-worker.exe ./cmd/wt-worker
CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build -trimpath -ldflags "-s -w -X main.Version=0.1.0" -o bin/windows-arm64/wt-worker.exe ./cmd/wt-worker
GOOS=windows go vet ./...
```

Binary locations the client looks at (in order):

1. `$env:WT_WORKER_PATH`
2. `<repository>/worker/bin/<windows|linux>-<amd64|arm64>/wt-worker[.exe]`
3. `<repository>/worker/bin/wt-worker[.exe]` (a development build)

That second path is the **canonical** one: it is what the build commands above write, what
`bootstrap/bootstrap.ps1` declares in `Get-WtBootstrapPlatforms` and requires of a staged release
(`worker/bin/<goos>-<goarch>/`), and where `tools/New-ReleasePackage.ps1` places the binary inside
each archive - stored with the executable bit, so extraction on Linux keeps it runnable. A release
archive that puts the worker anywhere else is refused by the bootstrap's validator and by the
packaging tool, which share the same table.

Packaging: ship the binary for the target architecture next to the module; **users do not need
Go installed**. The worker is a single static binary built with `CGO_ENABLED=0` for Windows, so
it has no runtime dependencies. If the binary is absent, the interface says so and uses
PowerShell.

Dependencies and licences: **not the standard library alone**. The store uses
`modernc.org/sqlite` (BSD-3-Clause) and the optional exporter uses the official Prometheus
Go client (Apache-2.0); `worker/go.mod` declares 22 requirements and `worker/go.sum` pins
them. The 16 modules that are actually linked into the shipped binaries, with their
licences and the verbatim licence texts under `licenses/go-worker/`, are listed in
`THIRD-PARTY-NOTICES.md`. The Go standard library itself is covered by the Go licence
(BSD-3-Clause), which that file lists for the toolchain too.

## Windows checks not executed

The following are **not** validated here, because no Windows host was available:

1. Running the worker on Windows at all (spawn, pipes, UTF-8 console code page, process exit
   codes) - the binaries are cross-compiled and vetted, which proves they *compile*.
2. `allocatedBytes` on Windows: the worker currently reports logical size only and sets
   `allocatedKnown = false`, because the on-disk size needs `GetCompressedFileSizeW` or
   `FILE_STANDARD_INFO` with a full path and unsafe plumbing that could not be tested. Wiring
   it up is small but must be done and verified on Windows.
3. Hard-link deduplication on Windows (needs the volume serial number and the file index from
   `GetFileInformationByHandle`). Until then the result says hard links are counted per link.
4. ReadePoints other than symlinks/junctions as Go reports them, and long paths
   (`\\?\` prefixes), drive-relative paths and UNC roots.
5. Antivirus/EDR interaction (a spawned child process) and Windows process-tree kill
   semantics (`Kill($true)`).

## Benchmark

```powershell
pwsh -NoProfile -File tools/Measure-WtWorker.ps1                       # 2000 files, 3 runs, both backends
pwsh -NoProfile -File tools/Measure-WtWorker.ps1 -Files 5000 -Runs 5
pwsh -NoProfile -File tools/Measure-WtWorker.ps1 -Path D:\Data -Backends Go
```

The tool creates a deterministic tree (known file count, sizes, one symlink, one hard link,
Vietnamese file names), measures both backends under the same conditions, and writes every raw
sample - elapsed, CPU, peak working set, file/byte totals - to
`docs/benchmarks/worker-<os>-<timestamp>.json`.

What the classes mean: **cold** is a fresh process per run after the tree was re-created;
**warm** is repeated runs in one process. True page-cache eviction needs root, so "cold" here
is **not** a guaranteed uncached read - it is reported as what it is. Startup and protocol
round-trip overhead are measured separately by `Measure-WtWorkerOverhead`.

A regression is a regression: if the Go path is slower for a workload, the numbers are printed
as they are and the PowerShell path stays the default for that workload.

## `scan.children` (disk-usage explorer)

See the integration tests and the PowerShell `Get-WtDirectoryChildren` for the contract.

## `metric.snapshot` (monitoring)

One request returns a bounded snapshot of typed metrics (`id`, `type`, `unit`, `tsMs`,
`quality`, `dims`, `provider`, `value`, `errorCode`, `note`). Linux providers read /proc
and /sys; Windows builds report `unsupported` with a stable code and the PowerShell CIM
providers own Windows collection. Missing data is never zeroed; counter rates are computed
by the client from monotonic elapsed time.
