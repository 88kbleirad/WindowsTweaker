# Runtime compatibility matrix

WindowsTweaker runs on more than one PowerShell runtime. This document states what each one
can do, what was verified and where, and what was only implemented. It is deliberately
conservative: a row is only marked **executed** when the command that proves it was actually
run, and a runtime is only advertised when its evidence exists.

## Supported and tested

| Runtime | Bootstrap | Application | Evidence |
|---|---|---|---|
| **Windows PowerShell 5.1** (ships with Windows 10 22H2 / Windows 11) | **Runs.** The published launcher is ASCII-only and BOM-free by construction, so the body `iex` receives cannot start with `U+FEFF`; its download helper uses only APIs that exist on .NET Framework; runtime policy, discovery, handoff and installation offer are exercised by tests. | **Runs natively** in the same reduced mode as the validated runtime, with capability-gated features. | Static gate (5.1 syntax/commands/types: 0 findings, plus the .NET Framework HTTP rules) and the 52 tests of `tests/Bootstrap.Tests.ps1` run on PowerShell 7, including the text the one-liner hands to `iex` and the HTTP body reader over a real socket; **no 5.1 host was available**, so console, code page, registry and terminal behaviour are unexecuted, and the two 5.1 failures that motivated the launcher split and the streaming fix were reproduced on 7.6.9 with the identical error text ([VALIDATION.md](VALIDATION.md) sections 14 and 15). |
| **PowerShell 7.4 – 7.6 stable** | Runs, no second process. | Runs natively. | Full suite executed on **7.6.9** (Linux): engine, journal, providers, TUI in a real pty, worker, packaging. 7.4 and 7.5 are the same stable line but were not executed here. |

## Not supported or not advertised

| Runtime | Behaviour |
|---|---|
| PowerShell 3.0 / 4.0 / 5.0 | Refused before anything runs, with a bilingual message naming 5.1 as the floor (`#Requires -Version 5.1` also refuses at parse time). |
| PowerShell 6.x – 7.3 | **Untested.** The application starts (every API it uses exists there) and prints a notice naming the validated range; the bootstrap never hands off *to* one. |
| PowerShell 7.7 preview, 7.7+, 8.x | **Untested and never selected automatically.** If the current session is one, the application runs with a notice; discovery reports it and refuses it as a handoff target. |
| PowerShell 7 preview builds | The bootstrap skips them during discovery: `Read-WtBootstrapPwshCandidate` marks a build whose version string carries a pre-release label, or whose path names `preview`, as `Preview` and never selects it. |

## What the bootstrap does, per runtime

| Current runtime | Bootstrap behaviour | Exit path |
|---|---|---|
| < 5.1 | Refuses. `#Requires -Version 5.1` stops a file run; in the piped-text form the launcher checks the runtime before loading anything and prints an English `RUNTIME:` message with the current and minimum version (the launcher is ASCII-only, so it cannot carry the Vietnamese half of the message). | Returns 2; session intact. |
| Windows PowerShell 5.1 | Stages and validates the release first (the download/extract/verify path runs **on 5.1**), then: compatible stable pwsh installed → relaunch it on the staged entry point; none → one consent question (`winget`, official source) → re-discover without trusting PATH → relaunch; declined/cancelled/failed → run natively on 5.1 with a notice. | Mirrors the child's code into `$LASTEXITCODE`; never `exit`s. |
| PowerShell 7.4 – 7.6 | Runs natively, one process. | Same. |
| PowerShell 6 – 7.3, 7.7+, preview | Runs natively with the untested-runtime notice; a notice never becomes a silent upgrade. | Same. |

Handoff details:

* the child is started with the **explicit executable path** (`Program Files\PowerShell\7\pwsh.exe`,
  the Store alias, or PATH — every candidate is probed by running it, never by file name);
* it runs the **local staged script** (`.../release-<tag>/WindowsTweaker.ps1`), not the network text;
* the caller's **working directory**, **language/colour/worker options** and the **inherited
  console** are preserved (no stream redirection, no new window);
* **loop prevention**: the child receives `WT_BOOTSTRAP_HANDOFF=1`, `WT_BOOTSTRAP_DEPTH`,
  `WT_BOOTSTRAP_PARENT`; a bootstrap that sees either already set runs natively instead of
  discovering again, and the chain stops at depth 2;
* `WT_BOOTSTRAP_RUNTIME=native` never relaunches; `=pwsh` refuses to fall back silently.

## Application features that still depend on the runtime

| Capability | 5.1 | 7.4 – 7.6 | Notes |
|---|---|---|---|
| Engine, journal, rollback, verification | yes | yes | Same code; JSON and file writes go through the compatibility layer. |
| Preview and reviewed-state revalidation | yes | yes | `ConvertTo-WtJson` normalises escaping, so a plan written on one runtime re-validates on the other. |
| Journal durability, locking, recovery | yes | yes | Atomic replace + `FileStream` lock; no runtime-specific API. |
| Catalog strictness (duplicate keys, exact value kinds) | yes | yes | Portable strict parser (`Private/Catalog/Json.ps1`); `System.Text.Json` is no longer used at all. |
| Terminal interface (keys, dialogs, quit, EN/VI) | yes, **unexecuted on a 5.1 console** | yes | VT is enabled on Windows through `SetConsoleMode`; without it the interface falls back to its Mono/ASCII palette. Encoding and cursor state are restored in `finally`. |
| Optional Go worker | yes | yes | JSON Lines over the child's stdin/stdout, written as UTF-8 by hand (5.1 has no `ProcessStartInfo.StandardInputEncoding`). Falls back to PowerShell exactly as before. |
| WPF interface (`-Gui`) | yes (Windows only) | yes (Windows only) | Uses .NET Framework WPF on 5.1 and the same XAML on 7; executed only off Windows for structural checks. |
| Linux release extraction (executable bit) | n/a | yes (7.3+) | `SetUnixFileMode` is called through reflection only where it exists; Windows never needs it. |
| Reliability and monitoring (read-only) | yes | yes | No runtime-specific API after the port. |
| Licensing & activation diagnostics (read-only, one explicit activation request) | yes, **unexecuted** (no 5.1 or Windows host) | yes | Documented Windows interfaces only: `Get-CimInstance` (`SoftwareLicensingProduct` / `SoftwareLicensingService`), `slmgr.vbs` through `cscript.exe`, `Get-Service`, `Get-WinEvent` and `w32tm` - all present on 5.1, and the static gate reports no 5.1 syntax, command, parameter or type finding for the new files (`docs/VALIDATION.md` section 21). Providers are doubled in the tests; the smoke procedure for a guest is in that section. |

## Audit: what was 5.1-incompatible and how it is handled

Found with PSScriptAnalyzer's Windows PowerShell 5.1 profile (`PSUseCompatibleSyntax`,
`PSUseCompatibleCommands`, `PSUseCompatibleTypes`) plus a manual read of the areas the rules
cannot see (BOM handling, console APIs, process plumbing). `tools/Test-Compatibility.ps1`
re-runs the gate; it fails the build on any finding.

| Area | Finding | Sites | Resolution |
|---|---|---|---|
| Syntax | No 5.1-incompatible syntax was found (no ternary, `??`, `??=`, `&&`, `\|\|`, `-Parallel`). | 0 | Kept that way; the gate checks it. |
| Text encoding | `-Encoding utf8NoBOM` (7-only value); `-Encoding utf8` writes a BOM on 5.1 and corrupts hashed JSON/JSONL. | 22 | `Write-WtTextFile` / `Read-WtTextFile`: `System.IO` with `UTF8Encoding($false)` on both runtimes. |
| Text encoding | 44 source files with non-ASCII text had no BOM; 5.1 decodes those with the ANSI code page (mojibake for every Vietnamese string). | 44 | UTF-8 BOM added; the gate fails if a non-ASCII script lacks it. |
| Text encoding | The published bootstrap carried that BOM, and `irm \| iex` hands the body over as *text*: the BOM decodes to a leading `U+FEFF` and the parser refused the body's own attribute and param block (`Unexpected attribute 'CmdletBinding'.` at line 84 on the published file). | 1 file | Split: `bootstrap/bootstrap.ps1` is the pure-ASCII, BOM-free published launcher; `bootstrap/implementation.ps1` keeps the BOM and is decoded explicitly by the launcher. The gate fails if the launcher gains a BOM or a non-ASCII byte, if its text does not parse, or if the two files disagree about the launcher protocol. |
| .NET members | `HttpContent.ReadAsStream()` is .NET 5+; on .NET Framework (5.1) only the asynchronous accessors exist, so calling it throws `does not contain a method named 'ReadAsStream'` inside the download. | 2 (both bootstrap downloaders) | `Read-WtBootstrapContentBytes` / `Read-WtBootstrapLauncherContentBytes` await `ReadAsStreamAsync().GetAwaiter().GetResult()`, keep the byte bound, dispose the stream, and classify failures per stage. The gate fails on any synchronous `ReadAsStream`/`ReadAsString`/`ReadAsByteArray` call. |
| .NET types | `[System.Net.Http.HttpClient]` cannot be resolved on 5.1 until `System.Net.Http` is loaded, and the assembly is not loaded by default there ("Unable to find type"). | 2 (Prometheus adapter) | `Initialize-WtPromHttpClient` loads the assembly before the client is constructed; the gate fails a shipped file that constructs `HttpClient` without the load. |
| Platform detection | `$IsWindows` / `$IsLinux` / `$IsMacOS` do not exist on 5.1 → every platform branch read as "not Windows". | 35 | `Get-WtRuntimeProfile` / `Test-WtIsWindows` (`.NET OSVersion` fallback), one cached probe. |
| JSON parsing | `ConvertFrom-Json -Depth` (7.0+) and `-AsHashtable` (6.0+). | 13 | `ConvertFrom-WtJson`: adds the parameters only where they exist, emulates `-AsHashtable` with case-sensitive ordered dictionaries. |
| JSON parsing | `System.Text.Json` (`JsonDocument`, `JsonElement`) is absent on .NET Framework. | 1 file | Replaced by a portable recursive-descent parser that reports the same duplicate-key/depth/string-length errors. |
| JSON serialisation | 5.1 escapes non-ASCII as `\uXXXX`; 7 writes UTF-8. Hashed or compared JSON text differed between runtimes. | writers | `ConvertTo-WtJson` decodes `\uXXXX` (and surrogate pairs, while leaving `\\`/`\"` alone), so both runtimes produce identical text. |
| .NET types | `RuntimeInformation.OSArchitecture` / `OSDescription` are Core-only members. | 5 | Read through reflection, with the documented environment variables as the 5.1 fallback. |
| .NET types | `File.SetUnixFileMode` / `UnixFileMode` are .NET 7+. | 2 (bootstrap, packaging) | Reflection + capability check; Windows path never calls them. |
| Process launch | `ProcessStartInfo.ArgumentList` does not exist on .NET Framework. | bootstrap | `ConvertTo-WtBootstrapArgumentString` implements the `CommandLineToArgvW` quoting rules (spaces, quotes, trailing backslashes). |
| Process I/O | `ProcessStartInfo.StandardInputEncoding` does not exist on .NET Framework, so the worker request line was written in the console code page. | 1 | The worker client writes through its own UTF-8 `StreamWriter` on both runtimes: identical bytes, Vietnamese intact. |
| Terminal | `$Host.UI.SupportsVirtualTerminal` is 7-only; 5.1 leaves VT off on a console that supports it. | 1 | Probed in a `try`; on Windows `ENABLE_VIRTUAL_TERMINAL_PROCESSING` is enabled via `SetConsoleMode` (`WindowsTweaker.ConsoleMode`) and restored on exit. |
| Terminal | Console encoding and cursor must not survive the interface. | 1 | `Enter-WtTuiTerminal` / `Restore-WtTuiTerminal` already saved and restored them in `finally`; the console mode restore was added there. |
| Version gate | `#Requires -Version 7.4`, `PowerShellVersion = '7.4'`, `CompatiblePSEditions = @('Core')`, and a blanket throw in the bootstrap. | 4 | `#Requires -Version 5.1`, manifest 5.1 + `Desktop`/`Core`, and a runtime policy that hands off or explains instead of refusing. |
| Defect found during the port | `Test-Path -LiteralPath $x -and (Test-Path ...)` bound `-and` as a parameter and threw on every runtime. | 1 | Parenthesised; the branch now evaluates as intended. |

## What remains unverified (and is not claimed)

1. **Any 5.1 execution.** No Windows host was available. The static gate proves the code
   parses and uses only APIs that exist on 5.1; it cannot prove what a 5.1 console does with
   VT, code pages, `ReadKey`, or what the registry providers return. The one 5.1 behaviour
   reported from the field - the `irm | iex` parse failure - is reproduced on PowerShell 7.6.9
   with the identical messages and line numbers, but that reproduction is not a 5.1
   measurement; the fix removes the input that failed rather than relying on the parser
   difference ([VALIDATION.md](VALIDATION.md) section 14).
2. **PowerShell 7.4 and 7.5** (supported line, not executed) and **7.7+ / preview** (explicitly
   untested; the bootstrap refuses them as handoff targets).
3. **The Windows-only surfaces**: WPF window, registry/service/task/Appx/Defender mutations,
   `winget` installation itself, `%LOCALAPPDATA%` state location.
4. **The handoff inside a real Windows console**: the tests use fake runtimes and mocks for
   discovery/selection/installation, and a real child process for launch, working directory,
   argument quoting and terminal inheritance (executed on Linux).
5. **The licensing and activation diagnostics against a real Windows license**: the
   `SoftwareLicensingProduct` / `SoftwareLicensingService` classes, `slmgr.vbs` through
   `cscript` (including the `/ato` exchange), the Software Protection Service event log and
   `w32tm`. Every provider is doubled in the tests, so the mapping, the redaction and the
   failure paths are exercised - but no value in this archive was read from a real license, and
   the workspace has never been rendered by a 5.1 console. Section 21 of
   [VALIDATION.md](VALIDATION.md) is the smoke procedure; it deliberately does not request
   activation.

Rows 1-3 and 5 are the ones to run in a disposable Windows VM (5.1 and 7.6 side by side) before
claiming them. The exact commands are in [VALIDATION.md](VALIDATION.md).

## Verifying it yourself

`-ExecutionPolicy Bypass` is a per-process switch: it does not change the machine policy and
writes nothing to the registry.

```powershell
# Windows PowerShell 5.1 console
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap\bootstrap.ps1

# PowerShell 7.4+
pwsh -NoProfile -File .\bootstrap\bootstrap.ps1

# What does this runtime support? (read-only, identical on both)
pwsh    -NoProfile -File .\WindowsTweaker.ps1 -RuntimeReport
powershell.exe -NoProfile -File .\WindowsTweaker.ps1 -RuntimeReport
```

`tools/Test-Compatibility.ps1` re-runs the static gate offline, and
`tools/Invoke-Validation.ps1` includes it as phase 5.