# Validation results

Everything below was executed in this archive's working copy. Nothing in this document
is inferred: the commands are reproducible from the repository root, and the "not
executed" section lists what could not be run here and why.

## Environment used for validation

| Item | Value |
|---|---|
| Host | Linux (CachyOS), x86_64 |
| PowerShell | 7.6.9 (Core), `~/opt/pwsh/pwsh` |
| Pester | 6.2.0 (bare `Invoke-Pester`, the call `tools/Invoke-Validation.ps1` makes; 5.7.1 is installed too and is not what the recorded run used) |
| PSScriptAnalyzer | 1.25.0 |
| Terminal used for the interactive runs | a real pty (100x30, 110x30, 64x18 and 44x10) driven by `python3` + `pty.openpty()`, `TERM=xterm-256color`, `COLORTERM=truecolor` |
| Windows availability | **none** - no Windows host or VM was available for this work |

One command runs the whole suite:

```bash
pwsh -NoProfile -File tools/Invoke-Validation.ps1     # exit 0: ALL EXECUTED CHECKS PASSED
```

## 1. AST parse of every PowerShell script

```bash
pwsh -NoProfile -File tools/Parse-All.ps1
```

```
Files parsed : 146
Skipped dirs : reference
Parse errors : 0
```

`reference/original-upstream-reference.txt` is excluded on purpose: it is the upstream
reference material (not a `.ps1`), never loaded and never executed. The legacy `modules\`
tree is no longer in the tree: its 117 files are accounted for one by one in
`docs/FEATURE-INVENTORY.md` and `docs/migration-notes/`, and the deleted files stay
reachable through the git history of the initial revision. Eight of them could never have
run - the audit found **39 parse errors in those 8 files** - which is why deleting the tree
and keeping the accounting, rather than repairing superseded code, is what makes
`Parse-All.ps1` end at 0 errors.

## 2. PSScriptAnalyzer

```bash
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path ./src,./tests,./tools,./bootstrap,./WindowsTweaker.ps1 -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
```

```
Findings: 0 (Error/Warning)
```

`PSScriptAnalyzerSettings.psd1` excludes six rules, each with the justification in the
file itself (host output in the interfaces, `-Raw` provider seams deliberately without
`ShouldProcess`, `[OutputType]` on private helpers, private helper naming, BOM-less UTF-8
under a PowerShell 7-only manifest, and the uniform `param($Tweak, $Arguments)` detector
signature).

Findings that indicated real defects were **fixed**, not excluded. The terminal interface
added four more real fixes rather than exclusions: `$Matches` was assigned in a filter
helper (an automatic variable), `$Error` was used as a validation variable (read-only
automatic), the `Ctrl+C` handler parameters were named `$Sender`/`$EventArgs` (automatic),
and two helper names used unapproved verbs (`Toggle-WtTuiPending` -> `Switch-WtTuiPending`,
`Validate-WtTuiWritablePath` -> `Resolve-WtTuiPathError`).

## 3. Pester suite

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path tests"
```

The counts below are the ones Pester reports per file; the same command is phase 6 of
`tools/Invoke-Validation.ps1`.

| Test file | Tests | Failed | Covers |
|---|---|---|---|
| `Tui.Tests.ps1` | 130 | 0 | palette and text metrics (Vietnamese/CJK/emoji widths, NFC normalisation, truncation, wrapping); the four colour depths and the ASCII/Mono fallbacks; the screen grid (box drawing, bottom-right clipping, wide characters, out-of-range writes); the zero-width rules (combining marks, variation selectors, supplementary selectors) applied identically by the width model, the painter and the truncator; the modal confirmation contract (the painted highlight is the value Enter returns, Left/Right/Tab/Shift+Tab cycling, Y/N answering, exactly one boolean out of the helpers, the highlight surviving a redraw and a resize, the four quit paths, the cancelled quit leaving category/filter/cursor/focus untouched); the language lifecycle (immediate switch with the catalog re-localized, both directions, Vietnamese quit confirmation, preference persistence and precedence, the Overview entry, the startup override); text fields swallowing q/l/y/n; the input diagnostic (targets recorded, text masked, nothing drawn); and the console-loss shutdown with terminal restore; the icon registry (the full 39-key vocabulary in every set, the measured slot of each set, the monochrome/PUA glyph rules, mode resolution from switch + terminal + saved preference, the semantic mapping and the colour classes, the count-driven progress bar); icons in the interface (category, list, details, status, dialog and operation-panel surfaces, the `None` and `-Ascii` fallbacks, exact row widths across 6 terminal sizes x 5 modes, frame columns unchanged between modes, the icon column dropped when a pane is too narrow, Vietnamese labels beside the glyphs, the selected-row background variants, the help/quit panel titles, the tone-derived dialog icon, every shortcut still working in the `None` mode); the icon preference (save/read, corrupt-file tolerance, command-line override, the picker switching the mode and repainting); key normalisation (`Up`/`Down`/`Tab`/`Shift+Tab`/`Enter`/`Esc`/`Space`/`Ctrl+C`); text-field editing and scrolling; the ten interface categories and their catalog mapping; focus cycling; the three layouts including a simulated resize that keeps the cursor, the pending set and the filter; global search; search-mode text entry taking precedence over global shortcuts; adding/removing pending changes; refusing to queue an unsupported tweak; the target-state chooser; quit confirmations; help; every dialog type (message, confirm, text with validation, multi-select with filter and protected rows, scrolling); the honest result report; path validation; the worker contract (events, per-item results, cooperative cancellation, one task at a time, safe close); preset validation, round-trip and refusals; the safety assertions (no system mutation, no window, no `Invoke-Expression`/`Add-Type`, terminal restore on every exit path); and localization coverage of every dynamically composed key |
| `Engine.Tests.ps1` | 21 | 0 | state capture, dry run, exact rollback, unchanged detection, missing dependencies, failed operation reporting, service configuration capture, protection-reducing labelling, managed-policy reporting, structured logs, registry key lifecycle, UWP selection rules, selected-adapter DNS changes |
| `Loading.Tests.ps1` | 17 | 0 | import side effects, detection performs no mutation, loader fails loudly on a syntax error, explicit public surface, private helpers stay private, no duplicate command definitions, catalog metadata/state invariants, string-table parity, referenced-key coverage (both directions: every referenced key exists, every defined key is used), fallback chain, reference material never executed |
| `Providers.Tests.ps1` | 14 | 0 | operation status aggregation (including dry run outranking "unchanged"), unnamed registry value handling, value comparison semantics, operation result contract |
| `Cli.Tests.ps1` | 21 | 0 | entry point requirements, `-Status`, `-List`, unknown id, `-Report`, dry run writes nothing, rollback with no captured state, parameterized tweak refusal, `-PresetList`, `-IncludeRestorePoint` (accepted, never implicit), and the refusal to start the interface on a redirected terminal (exit code 2) |
| `Gui.Tests.ps1` | 9 | 0 | XAML well-formedness, every `FindName` target declared, Catppuccin Mocha palette, square corners, icon font/glyphs, no system-modification logic in the interface, confirmations suppressed in the background runspace, no change when WPF is unavailable |
| `Journal.Tests.ps1` | 28 | 0 | exact change preview (per-target current/proposed/type/scope/recovery, absent vs unreadable vs empty vs zero, review fingerprint revalidation, `review-required` refusal); conflict detection (same target, key containing a target); the original recovery baseline surviving a repeated apply; journal durability (written before the first mutation, session/origin/sequence/stage/targets, corrupt and empty stores treated as errors and never overwritten, interrupted operations detected, recovery records kept when a restore fails); verified execution and compensation (verification mismatch reported as failure, compensation attempted and its failures reported separately, external change blocks a restore until `-Force`, restored value verified); retired tweaks (apply refused, snapshot still restorable); drift classification (matching/changed/unsupported, never reapplied); session restore in reverse dependency order (`-WhatIf` restores nothing); journal export filters (Json/Csv); schema-1 migration |
| `Diagnostics.Tests.ps1` | 14 | 0 | bounded ring, no typed character recorded, home-path and token sanitization, sensitive data keys dropped, bounded/truncated values, export header contents, overwrite refusal, record and size bounds, JSONL re-parsing, summary counts, clear |
| `Measurements.Tests.ps1` | 14 | 0 | sample and timeout bounds, failed samples retained with their error, raw samples with unit/adapter/target/conditions/timestamps, Min/Max/Median over successful samples, improved/regressed/inconclusive/insufficient per the documented criteria, target/kind/unit mismatch, inputs never mutated, no apply path touched |
| `Worker.Tests.ps1` | 17 | 0 | worker discovery from the application-controlled path only; `Go` refusing to fall back; `Auto` falling back with a reason; backend preference round-trip; protocol handshake (version, capabilities, limits); incompatible version reported; crashed worker reported; garbage on stdout reported; PowerShell/Go aggregate equivalence (with the documented hard-link difference); Vietnamese file names; access-denied partial results in both backends; cooperative cancellation with the worker still usable afterwards; bounded shutdown without a kill; startup and round-trip overhead |
| `Bootstrap.Tests.ps1` | 52 | 0 | **the published launcher** (new): pure ASCII with no UTF-8 BOM, its text parsing exactly as `irm` delivers it, the implementation decoded with and without a leading `U+FEFF` to identical parseable text, the launcher-protocol refusal, the pinned URL and allowed-host policy, option forwarding with nothing emitted by the launcher, session survival and `$LASTEXITCODE` mirroring through `iex`, and file execution reaching the implementation beside the launcher without a download; **the HTTP body reader** (new): a real 256 KiB `HttpContent` through both readers, the size bound enforced while reading, and a real HTTP response streamed from a socket (ephemeral `TcpListener`) through the same reader; **the implementation**: executed as text (no `$PSScriptRoot`, no `$PSCommandPath`, no `exit()`, and the functions it defines removed again); the session surviving a failed run with `$LASTEXITCODE` at 1; exact platform-asset selection, ambiguity refusal and a declared platform that disagrees; the canonical platform-to-worker-path table; OS-architecture mapping including ARM64 and the refusal of a 32-bit host; the 5.1 runtime floor and the refusal of anything older; HTTPS-only and allow-listed-host redirects on every hop, including the real GitHub asset host and the refusal of a cross-host or `http://` hop; checksum-text parsing; refusal without a checksum; hash mismatch; traversal-safe extraction; paths with spaces and Unicode; manifest validation (schema, platform, entry point, worker protocol, canonical worker path, per-file size and hash); the no-bypass staging marker and cache rule; the launch step passing no arguments and propagating the exit code; no app state written; runtime policy (5.1 accepted, 4.0 refused, 7.4-<7.7 as the handoff target); probe-not-filename discovery with preview/untested rejection; PATH-first selection; handoff loop prevention; winget absent/consent/decline/failure with re-discovery; argument quoting and option/cwd/env preservation; classified errors. Six tests are the opt-in live run (`WT_BOOTSTRAP_LIVE_TEST=1`, skipped by default): three GitHub transport checks, two published-launcher checks and the whole-downloader check |
| `Compatibility.Tests.ps1` | 19 | 0 | the runtime layer: profile and tier, the tested range and the capability table with reasons; BOM-less UTF-8 read/write and append; cross-runtime JSON escaping (`\uXXXX`, surrogate pairs, escaped backslashes) and the `-AsHashtable` shape; the handoff command; the module manifest and entry-point floor; the UTF-8 BOM policy over every source file; EN/VI runtime strings; and bootstrap/module discovery classification parity over fake runtimes (stable, old, future, preview, garbage) |
| `ReleasePackage.Tests.ps1` | 12 | 0 | a real generated archive for the host platform taken through the bootstrap's own code: checksum agreement between `checksums.txt`, the release manifest and the bytes; safe extraction; internal manifest present, complete and free of archive hashes; every declared file hash and size; the executable bit on the worker; manifest validation; worker-path resolution and the real worker handshake from the staged client; and refusal of a byte-flipped archive, a same-length replaced worker, a manifest whose protocol/platform/worker path disagree, and a missing worker |
| `CapabilityLoss.Tests.ps1` | 11 | 0 | the per-definition capability-loss disclosure: parsing and load-time validation (catalog and PowerShell definitions), attachment to the definition, aggregation across a selection by stable capability id, and the refusal of malformed declarations - read-only throughout |
| `Catalog.Tests.ps1` | 46 | 0 | declarative documents (schema, duplicate property, operation kinds, hive prefixes, size limit, namespace rules, detection maps); the derived privilege/risk floor; no side effects from validating; the five `builtin.json` definitions; the definition view and its filters; planning (order, satisfied prerequisites, unreadable prerequisites, cycles, conflicts); migrations (rename, retirement, broken registry, old ids in the journal); packs (hash-stable storage, `-WhatIf`, re-import refusal, enable/disable, and a change restoring after its pack was removed) |
| `Devices.Tests.ps1` | 5 | 0 | the read-only device/driver inventory over a doubled CIM query: states, hardware ids, correlation confidence, the Driver Store split, and an unavailable-but-not-empty report off Windows |
| `Insight.Tests.ps1` | 45 | 0 | the sanity scan (rule documents, probe shapes, outcomes, incomplete results), recommendation policy and gates, state dimensions and their evidence, boundary verdicts, pending-restart marker states, and the bilingual rule text |
| `InsightTui.Tests.ps1` | 8 | 0 | the insight overlays driven through the real key dispatch: the scan, recommendation and choice views, filter typing versus shortcuts, objective cycling, export validation, replacing a pending alternative and bilingual rendering |
| `Monitor.Tests.ps1` | 22 | 0 | the metric model, bounded history, alert rules and transitions, dashboards and their validation, chart aggregation, and the collector lifecycle |
| `MultiHost.Tests.ps1` | 10 | 0 | fleet targets and conditions, incident timelines and evidence kinds, read-only playbooks, support-bundle preview/export with redaction and traversal-safe import, and versioned monitoring configuration |
| `PrivacyPowerTools.Tests.ps1` | 6 | 0 | the privacy summary/activity report shapes, power settings, SRUM history and the Explorer copy-path tweak |
| `SetupPlans.Tests.ps1` | 10 | 0 | checkpointed setup plans: data-only import, identity-bound resume registrations, refusal on tampering, a failed step stopping the plan, no automatic retry of uncertain steps and bounded reboot counts |
| **Total** | **542** | **0** | 536 passed, 6 skipped (the opt-in live GitHub, published-launcher and whole-downloader tests) |

`tools/Invoke-Validation.ps1` phase 5 on this tree reported `Tests passed: 536 | failed: 0 |
skipped: 6` and ended with `ALL EXECUTED CHECKS PASSED`. The six skipped tests are the live
transport and published-command checks, which need `WT_BOOTSTRAP_LIVE_TEST=1` and network access;
the pre-existing three were run separately and are recorded in section 12, and the
launcher/downloader checks can only pass once the fixed files are on `main` (sections 14 and 15).

Destructive operations are mocked: the registry, service, scheduled-task, firewall, DNS,
Appx and Defender seams are replaced by in-memory doubles, so no real system state is
touched by the suite. The interface tests additionally double the prerequisite check (so
selection, dialogs and targeting can be exercised off Windows) and inject both the keys
and the terminal size, which is what makes focus, filtering, selection preservation, resize
handling and the dialogs assertable without a terminal.

## 4. Dry-run proof

```bash
pwsh -NoProfile -Command "Import-Module ./src/WindowsTweaker/WindowsTweaker.psd1; Invoke-WtTweak -Id Privacy.AdvertisingId -State Disabled -WhatIf"
```

```
Status      : unsupported          # on this Linux host; on Windows it is 'dryrun'
State saved : False
state.json  : not created
```

The automated equivalent (with the Windows environment and providers doubled) is in
`Engine.Tests.ps1`: a dry run enumerates per-operation `dryrun` results, writes no
registry value, captures no state, creates no state file, changes no service, starts no
process and downloads nothing. `Tui.Tests.ps1` asserts the same for the interface's `W`
preview and for the worker (`Worker runspace`).

## 5. Entry point smoke tests

```bash
pwsh -NoProfile -File WindowsTweaker.ps1 -Status
pwsh -NoProfile -File WindowsTweaker.ps1 -List
pwsh -NoProfile -File WindowsTweaker.ps1 -PresetList
pwsh -NoProfile -File WindowsTweaker.ps1 -Preset privacy-hardening -WhatIf
pwsh -NoProfile -File WindowsTweaker.ps1 -Report
printf '' | pwsh -NoProfile -File WindowsTweaker.ps1        # redirected terminal
```

* `-Status` prints the environment snapshot, the log path, the state path and the preset
  names - and creates nothing.
* `-List` prints the catalog with per-tweak state and a summary line, exit code 0.
  On this host every tweak is honestly reported as `unsupported` (`113 tweaks`, all
  machine-level settings).
* `-PresetList` lists `explorer-usability` and `privacy-hardening` with their entry counts.
* `-Preset ... -WhatIf` walks the preset and reports each entry's status.
* `-Report` writes a JSON report and prints its path.
* With piped input the entry point refuses to start the interface, prints the reason and
  the CLI alternatives, and exits with code `2` - it does not hang.

## 6. Interactive interface in a real pty (executed)

The interface was driven through `python3` with a real pseudo-terminal, so the runs below
went through `[Console]::ReadKey`, `[Console]::WindowWidth/Height`, the ANSI renderer and
the alternate-screen sequences exactly as a user would. The screen below is the
reconstructed terminal content after each step (escape sequences interpreted).

| Step | Keys | Observed |
|---|---|---|
| Start | - | Three panes (categories, tweaks, details), header with `WindowsTweaker`, the detected OS/privilege/language, `Preset: custom selection`, footer shortcuts and the status line. No `Clear-Host` flashing: the frame is a single write. |
| Search | `/`, `advert`, `Enter` | The list filters to `Privacy.AdvertisingId` while the filter is typed; `Enter` keeps the filter and reports `1 item(s) match the filter`; `Esc` clears it |
| Panes | `Tab`, `Down`, `Tab` | Focus moves list -> details -> categories; `Down` moves the category cursor; the following repaint keeps the focus and the category |
| Help | `?` | The keyboard reference panel renders inside the frame with the safety rules and every shortcut; `Esc` closes it and the panes are repainted identically |
| Presets | `P`, `Down`, `Enter`, `y` | The preset list shows both shipped presets with their entry counts and a details pane; loading `privacy-hardening` fills 18 pending changes, the header switches to `Preset: privacy-hardening`, and nothing is written (no `state.json`) |
| Icons | `i` | The icon picker opens over the panes: the five modes, the saved choice (`Saved: Auto (recommended) | drawing with: Unicode`), the resolved set in the `Auto` row, and a preview line drawn with the real glyph table (`⌂ ○ ◆ ↺ ■ □ ∙ ▸ ✓ ✗ △ ∅ # ↻ / ⟳ ◎ » ↩ ⊘`). The same run confirms the picker is reachable from the Overview pane (`Icons` row) and from `?` -> `I` |
| Icon mode switch | `Down`, `Down`, `Enter` | Selecting *Nerd Font icons* repaints every pane with the private-use glyphs (they appear as blanks/blocks in a terminal without a patched font, which is exactly what the preview is for), the status line explains the font requirement, and `settings.json` is written with `"icons": "NerdFont"` - no font is installed and no terminal setting is touched |
| ASCII icons | `-Icons ASCII` at start | The frame uses `+ - |` borders and readable tags: `[SET]` for the brand and the System category, `[HW]`/`[IN]`/`[VIEW]` on the Overview rows, `[PRIV]` on the tweak rows; the 20-cell category pane drops its tag column (the label and the count keep their space) while the wider list pane keeps the tags |
| Review | `A` | The review panel lists the exact pending changes and caps the warning block; `Enter` continues to the confirmation, where `No` is highlighted by default |
| Apply | `y` | The worker panel appears with `Item n of 18`, then the per-item result panel: `Privacy.X: unsupported (0 operation(s))` with the detector's message for each entry - the honest outcome on a Linux host |
| Resize | 110x30 -> 64x18 -> 110x30 | The layout switched Wide -> Medium -> Wide, repainting inside the new grid; the pending set, the category, the cursor row and the status line survived every resize |
| Quit | `q`, `y` | The pending changes are reported (`18 pending change(s) will be discarded`) and the interface exits; the alternate screen is left, the cursor is shown again and the colour state is reset (`ESC[0m ESC[?25h ESC[?1049l` are the last bytes written) |
| Confirmation keys (re-run after the fix below) | `q`, `Esc`, `q`, `n`, `q`, `Tab`, `Enter` | The dialog paints `Yes [Y]` / `No [N]` with **No** highlighted (`DialogSelected` verified in the raw SGR of the button row); `Esc` and `N` return to the interface and the status line says `Quit cancelled. Nothing was changed.`; `Tab` moves the highlight to **Yes** and the very next frame is a new write; `Enter` then leaves the interface (`WT_EXIT=0`) |
| Language switch | `-Language vi`, `l`, `Enter`, `q`, `y` | The first frame is Vietnamese (`Tổng quan`, `Ngôn ngữ: Tiếng Việt`); `l` opens the picker titled `Ngôn ngữ`; selecting English re-renders the whole frame in English (`Overview`, `Language mode`, `Language: English`) without losing the pending set or the cursor, and `settings.json` records `"language": "en"` |
| Input diagnostics | `-InputDiagnostics`, `/`, `abc`, `Enter`, `d`, `q`, `n` | The log holds `input scope=main key=Char char=- target=search` for the typed filter (characters masked - `abc` appears nowhere), `target=global:d`, `target=dialog:confirm` and `target=escape`; the screen shows no trace text at all |

Not observed here (Windows-only): real registry/service/DNS/Appx/DISM effects, the effect
of `Restart` requirements, Windows key delivery through conhost, and the WPF interface.

### Defects found in the field and fixed (input / quit)

A user report on Linux/CachyOS (interface renders, the Quit dialog opens, but confirming
does not exit and Left/Right appear to do nothing) was reproduced in a real pty and traced
to two independent defects in the modal input path, plus three hardening gaps:

| # | Symptom | Root cause | Fix | Guard |
|---|---|---|---|---|
| 1 | The dialog showed **Yes** highlighted, but `Enter` returned *No*, so "confirming" the exit cancelled it | `Add-WtDialogToScreen` painted the buttons as `Yes(Index=1) / No(Index=0)` while `Read-WtDialogKey` computed `Result = (Confirm -eq 0)` with a default `Confirm = 1`: paint and answer used two different encodings of the same number | A confirmation now carries one ordered `Choices` list in render order; `Confirm` is the index of the highlighted choice (default = last = No) and `Enter` returns `Choices[Confirm]`; `Y`/`N` move the highlight to the button they stand for | `Modal confirmation input and quit` (painted highlight vs. returned value, every key), plus the raw-SGR frame check in the pty |
| 2 | `Left`/`Right` changed the internal selection but the terminal never changed | `Read-WtDialogKey` began with `$State = $null`, so the `if ($State) { $State.Screen.Dirty = $true }` hook at its end could never run and the frame loop (which repaints only when the grid is dirty) skipped every dialog update | The dialog loop passes `-State`; the hook is live, so every consumed key repaints | `repaints the dialog after a key` and the pty `Tab` step (a new frame is written) |
| 3 | Quitting from a dot-sourced/`&`-invoked script would also end the caller's PowerShell session | every branch of the entry point used `exit` | `Exit-WtEntryPoint` exits only for a top-level `pwsh -File` run and otherwise mirrors the code into `$LASTEXITCODE` and returns | `Cli.Tests.ps1` (process exit codes unchanged) + the session-invocation check in the entry-point smoke tests |
| 4 | A console that stops delivering input made the interface spin forever on a dead terminal (indistinguishable from a frozen dialog) | `Read-WtConsoleKey` swallowed the reader exception and returned null, which the loops treat as "no key yet" | The failure is recorded once (`WtConsoleInputLost`), logged, and ends the loop; the `finally` blocks restore the terminal | `stops the loop and restores the terminal when console input disappears` |
| 5 | No way to see which target a key reached | - | `-InputDiagnostics` / `WT_TUI_INPUT_TRACE=1` logs one record per key (target + masked character) to the log file only | `Input diagnostics` tests + pty verification |

The footer hint was also rewritten to describe the dialog keys exactly (`Y/N select
Left/Right or Tab choose Enter confirm Esc cancel`, with `Yes [Y]` / `No [N]` on the
buttons) and sized so it is not cut off in the layout that shows it.

## 7. Change verification, recovery and the operation journal (executed)

The verification layer was exercised at three levels on this host (Linux, PowerShell 7.6.9):

* **Automated** - `tests/Journal.Tests.ps1` (24 failure-injection tests), plus the preview,
  verification-view and layout-budget tests in `tests/Tui.Tests.ps1`, all green.
* **API smoke** (`Get-WtChangePreview`, `Get-WtDrift`, `Get-WtOperation`, `Get-WtSession`,
  `Get-WtInterruptedOperation`, `Get-WtRestorePlan`, `Undo-WtSession`, `Export-WtHistory`,
  `Export-WtDiagnostics`, `Measure-WtNetworkDiagnostics`, `Compare-WtMeasurements`):

  ```
  preview: targets=1 supported=False scope=User rollback=Full fp=676df94b1011
    row: HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Enabled
         | now=(unreadable) (Unreadable) -> 0 [DWord]
    support: Unsupported operating system for this tweak: Windows10; ... Windows11
  operations: 0 sessions: 0 interrupted: 0     drift rows: 0
  journal export: True      diagnostics export: True (header record)
  measure: kind=tcp unit=ms samples=3 ok=0 failed=3
  compare: insufficient | insufficient: a side has zero successful samples
  restore plan: operations=0 summary=Nothing to restore.
  session restore (WhatIf): status=unchanged steps=0
  ```

  The measurement against a closed port produced three *failed* samples and the comparison
  classified the run as `insufficient` - the honest outcome, with no score invented.

* **In the interface** - the pending review shows the per-target preview and conflicts, the
  `V` view lists drift and interrupted operations, and `E`/`D` export the journal and the
  diagnostics only when asked; these are covered by the TUI tests above (head-less frames).

## 8. Optional Go worker (executed on Linux only)

* **Go unit and integration tests**: `go test ./...` and `go test -race ./...` - protocol
  framing and concurrent serialisation, oversized-line rejection with stream recovery, scan
  aggregation (logical vs allocated, hard-link dedupe, symlink skipping, depth cap, progress
  rate), server dispatch (handshake, version mismatch, unknown op, malformed JSON, missing id,
  invalid parameters, concurrency limit, cancellation states, clean shutdown, EOF, four
  parallel scans).
* **PowerShell integration**: `tests/Worker.Tests.ps1` (14 tests, above) drives the adapter
  against the real binary and against canned fake workers for the failure modes.
* **Benchmark** (`tools/Measure-WtWorker.ps1`, 2001 files / 41 directories / 11 261 440 logical
  bytes, Linux amd64, PowerShell 7.6.9; raw samples in `docs/benchmarks/`):

  | Backend | Class | Runs | Median elapsed | Median CPU | Files | Logical bytes |
  |---|---|---|---|---|---|---|
  | PowerShell | cold (fresh process) | 3 | 313 ms | 380 ms | 2001 | 11 261 440 |
  | PowerShell | warm | 3 | 99 ms | 94 ms | 2001 | 11 261 440 |
  | Go worker | cold (fresh process) | 3 | 178 ms | 184 ms | 2000 | 11 254 784 |
  | Go worker | warm | 3 | 47 ms | 22 ms | 2000 | 11 254 784 |

  Worker startup plus handshake: 11 ms (2 ms CPU, ~7 MB resident). Protocol round-trip
  overhead is reported separately in the raw JSON. The Go totals are one file and one file
  size smaller because it deduplicates the hard link - a documented semantic difference, not a
  discrepancy.

  Interpretation, stated narrowly: on this workload the Go implementation is about 2x faster
  warm and about 1.8x faster cold. Part of that is the language, and part is that the PowerShell
  path is single-threaded and does more managed work per entry; the benchmark does not separate
  the two, so it is not evidence that "Go is twice as fast" in general. No claim is made for
  workloads that were not measured.

## 9. Declarative catalog, packs, planning and migrations (executed)

`tests/Catalog.Tests.ps1` covers the catalog layer end to end on this Linux host, with the registry
as an in-memory double and every document in a temporary directory:

| Area | What is asserted |
|---|---|
| Document validation | Unsupported `schemaVersion`, unknown properties, a **duplicated JSON property**, an unsupported operation kind, an unsupported registry type, a hive prefix inside `key`, a document above the byte limit, a duplicate tweak id, a pack id outside its namespace, two operations writing one target in one state, a detection map naming an undeclared state. |
| Derived fields | A definition that declares `privilege: None` for a machine scope, or `risk: Low` with `reducesProtection`, is refused - the floor is derived from the flags, not trusted. |
| No side effects | Validating and registering a document leaves the catalog and the raw registry writers untouched (write and remove counters stay at zero). |
| Migrated definitions | The five definitions shipped in `builtin.json` are loaded through `New-WtRegistryTweak`; the three privacy ones (`Privacy.DismissMSAccount`, `Privacy.LanguageListAccess`, `Privacy.WindowsTips`) additionally carry per-field assertions of their detection maps, state operations, scope, privilege, default states, managed policy and capability requirements against the documented values; their canonical target identities are compared with an equivalent PowerShell definition. |
| Definition view | `Get-WtTweakDefinitionView` reports `Structural` support for a built-in definition and `AuthorClaimed`/`Unverified` for a pack, including a pack that claims `WindowsValidated` for itself; an unrecognised filter is an error, not "everything". |
| Planning | Order (`requires` first), a satisfied prerequisite excluded from the apply set, an unreadable prerequisite kept in the plan with a warning, an unknown id, a cycle, and a conflict. |
| Migrations | A rename resolves the old id to the new definition, a retired id is reported as retired, a broken registry (cycle or missing target) is rejected, and a journal entry stored under the old id is still found by `Undo-WtTweak` without the entry being rewritten. |
| Packs | Byte-identical storage with a recorded SHA-256, `-WhatIf` storing nothing, a second import refused without `-Force`, a namespace violation and an oversized document refused, an edited document not enabling (hash mismatch), enable/disable round trip, removal refused while changes are pending, and - the important one - **a change created by a pack still restoring after the pack was removed**, from the captured state alone. |

The suite runs on any platform and does not touch a real registry; see "Not executed here" below
for what that leaves unverified.

## 10. Sanity scan, recommendations, state dimensions and choice groups (executed)

`tests/Insight.Tests.ps1` covers the insight layer with an in-memory registry double, temporary rule
documents and a temporary pack directory; `tests/Cli.Tests.ps1` runs the new switches as a child
process exactly as a user does.

| Area | What is asserted |
|---|---|
| Read-only scan | Scanning leaves the registry double and the write counter untouched, and writes no file. |
| Outcomes | `Findings` when a documented value is outside its documented shape; `Clean` only when every required probe answered; `Incomplete` - never `Clean` - when a required probe cannot be read; findings and gaps reported together when only part of the run could be read; an absent value reported as absent, not as proof of a default; an unavailable probe producing no finding at all. |
| Rule validation | A rule without a source URL or without a claim is refused, and an unsupported probe kind is refused - a rule cannot smuggle in a command. |
| Reports | Nothing is written unless a path is given, and the report names the source URL. |
| Recommendation policy | Items without metadata are excluded; an item is recommended only for an objective it names, and never for another one; preferences are excluded unless explicitly requested, and the Gaming objective never takes them; a protection-reducing definition is never automatically selected; an unknown applicability stays `Unknown`; an already satisfied item is not proposed; an imported pack that claims eligibility, evidence and low risk is offered at most (`Rec.Excluded.PackClaim`); changing the objective leaves a manual selection untouched; an unknown objective is an error rather than a substitution. |
| State dimensions | Configured `Matches` while the effective state stays `Unknown`/`Inferred`; `Mixed` when only some targets match; an Explorer-boundary change reported as `PendingRestart`, a sign-out boundary as `PendingSignOut` and a reboot boundary as `PendingReboot`; missing, empty, non-empty and unreadable restart markers kept apart; ownership reported as `Unmanaged` and then `Owned` after a real apply through the journal. |
| Choice groups | The group exposes its alternatives with their intent; a custom value matching no option is reported as custom rather than guessed; one pending alternative per group, replaced on request with no stale fingerprint; a full apply/verify/restore cycle returns the exact captured value; restoring a captured baseline and asking for the Windows default produce different results; an overlap between a group and a pack is reported by the existing conflict engine. |
| Interface and localization | The new views render in English and Vietnamese without raw keys; the details pane draws the configured/effective/ownership lines; `S` opens the scan and closing it leaves the pending set untouched. |
| Command line | `-SanityScan`, `-Recommend`, `-Choices` and `-CatalogInspect -CatalogDimensions` run as a child process with the expected exit codes, and an unknown rule fails instead of scanning nothing. |

### Not executed for this layer

* No rule was run against a real Windows build: the *shape* of a probe result, the outcome logic and
  the finding text are asserted against doubles, and the values a real machine would return are not.
  The rules' applicability to Windows 10/11 is what Microsoft's pages say, not something observed
  here.
* Nothing measured behaviour: no throughput, latency or frame rate was recorded anywhere, and no
  report claims one.
* The effective dimension is exercised through declarations (`Inferred`, boundaries) and through
  `Unknown`; `Observed` requires a real observation on a build and none was made.
* Choice-group mappings are inherited from the repo's existing definitions; the group adds
  exclusivity, intent and validation. Microsoft publishes no reference page for the `LaunchTo`
  value, and the definition says so.

## 11. Release packaging (executed)

```bash
pwsh -NoProfile -File tools/New-ReleasePackage.ps1 -Version 1.0.0 -OutDir ./dist
```

```
Files parsed : 146
Skipped dirs : reference
Parse errors : 0
Building worker for win-x64 (windows/amd64)
Building worker for win-arm64 (windows/arm64)
Building worker for linux-x64 (linux/amd64)
Building worker for linux-arm64 (linux/arm64)
Packaged WindowsTweaker-win-x64-v1.0.0.zip (eb8256c21cfb114e0147e0c97feb9d902d31638a3e8c93c8663f7d584a19616a, 6164819 bytes)
Packaged WindowsTweaker-win-arm64-v1.0.0.zip (ed325f060f41a34cfc3640409e5e6ef2beb301fba8221ae4782937a01341b7e3, 5641247 bytes)
Packaged WindowsTweaker-linux-x64-v1.0.0.zip (786e7a69eb991223830177ba7edcd8aed8a801d7e5428a3b38ed79a49f44ffdf, 6081462 bytes)
Packaged WindowsTweaker-linux-arm64-v1.0.0.zip (b287f67bbdbca2345034ea7c9ac395d0bdebffe5137b6e754af14bf1a2dd07f6, 5608225 bytes)
Validated WindowsTweaker-win-x64-v1.0.0.zip: checksum, safe extraction, manifest, 146 file hashes, worker path
Validated WindowsTweaker-win-arm64-v1.0.0.zip: checksum, safe extraction, manifest, 146 file hashes, worker path
  worker handshake: 0.1.0, protocol 1, 3 capabilities
Validated WindowsTweaker-linux-x64-v1.0.0.zip: checksum, safe extraction, manifest, 146 file hashes, worker path
Validated WindowsTweaker-linux-arm64-v1.0.0.zip: checksum, safe extraction, manifest, 146 file hashes, worker path
Release package set written to /home/dariel/WindowsTweaker/dist
```

The exact assets of that run (independent `sha256sum` and `unzip -tq` agree with every line):

| Asset | Bytes | SHA-256 |
|---|---|---|
| `WindowsTweaker-win-x64-v1.0.0.zip` | 6164819 | `eb8256c21cfb114e0147e0c97feb9d902d31638a3e8c93c8663f7d584a19616a` |
| `WindowsTweaker-win-arm64-v1.0.0.zip` | 5641247 | `ed325f060f41a34cfc3640409e5e6ef2beb301fba8221ae4782937a01341b7e3` |
| `WindowsTweaker-linux-x64-v1.0.0.zip` | 6081462 | `786e7a69eb991223830177ba7edcd8aed8a801d7e5428a3b38ed79a49f44ffdf` |
| `WindowsTweaker-linux-arm64-v1.0.0.zip` | 5608225 | `b287f67bbdbca2345034ea7c9ac395d0bdebffe5137b6e754af14bf1a2dd07f6` |

`checksums.txt` (408 bytes) carries these four lines; the external `manifest.json` (2461 bytes)
carries the same sizes and hashes with the download URLs. A later run produces different bytes
because the manifest records `createdUtc`; the published release is whatever one run produced, and
the workflow packages once and uploads what it validated.

Each archive holds 147 entries: the entry point, the module tree, the compatible worker binary
(`worker/bin/<goos>-<goarch>/`, stored with the executable bit), `THIRD-PARTY-NOTICES.md`, the
verbatim licence texts under `licenses/` (the worker statically links the modules listed there),
and the internal package `manifest.json` - written before the archive was closed, carrying every
file's size and SHA-256 and no archive hash of its own. `checksums.txt` and the external release
`manifest.json` are written next to the archives and are inside neither.

The tool refuses to package a tree that does not parse, refuses a `-Version` that is not the
module's `ModuleVersion`, builds the worker for every selected platform before packaging, and then
validates each archive it wrote with the bootstrap's own code: `Test-WtBootstrapHash` against the
`checksums.txt` line, `Expand-WtBootstrapArchive`, and `Test-WtBootstrapRelease` (manifest schema,
platform identity, entry point, worker protocol, canonical worker path, every declared file's size
and SHA-256). On the host platform it additionally imports the staged client and runs the worker
handshake - the line above, `0.1.0, protocol 1, 3 capabilities`. Publishing is not part of the
tool.

`tests/ReleasePackage.Tests.ps1` repeats this on a generated archive and then tampers with it:
same-length replacement of the worker binary, a manifest whose protocol/platform/worker path
disagree, a removed worker, and a byte-flipped archive. Every case is refused.

## 12. Bootstrap transport against real GitHub (executed)

```bash
WT_BOOTSTRAP_LIVE_TEST=1 pwsh -NoProfile -Command "Invoke-Pester -Path tests/Bootstrap.Tests.ps1 -Output Detailed"
```

```
[+] downloads a real release asset through the github.com -> release-assets redirect 734ms
[+] reads real release metadata from the GitHub API 521ms
[+] refuses the project metadata URL while no release is published 448ms
```

What the redirect check establishes, measured with `curl -sSI` against a public release before the
test was written:

| Request | Response |
|---|---|
| `github.com/cli/cli/releases/download/v2.0.0/gh_2.0.0_checksums.txt` | `302` to `release-assets.githubusercontent.com/...` |
| that URL | `200`, `content-length: 1495` |

`release-assets.githubusercontent.com` is therefore in `Get-WtBootstrapAllowedHosts`; without it
every real asset download was refused as a disallowed host. The two historical asset hosts are
kept as well. The bootstrap follows redirects manually with `HttpClient` and
`AllowAutoRedirect = $false`, re-validating scheme and host on every hop, so a `302` to another
host or a downgrade to `http://` is refused (asserted in `tests/Bootstrap.Tests.ps1`).

The third test above is the honest record of the current public state: the project's own
`releases/latest` answers `404`, and the bootstrap reports it instead of resolving anything.

### Bootstrap staging, cache and launch (executed)

```bash
# the generated linux-x64 archive, through the bootstrap's own functions on this host
.
bootstrap/bootstrap.ps1            # WT_BOOTSTRAP_TEST_ONLY=1
$Bytes = [System.IO.File]::ReadAllBytes("dist/WindowsTweaker-$Key-v1.0.0.zip")
Test-WtBootstrapHash -Bytes $Bytes -ExpectedHash $Checksums[$Asset.name]   # verified
Expand-WtBootstrapArchive -Bytes $Bytes -Staging $State/release-v1.0.0
Test-WtBootstrapRelease -Staging $State/release-v1.0.0 -PlatformKey $Key  # platform, worker, 143 hashes
Set-WtBootstrapStagingComplete ...
Find-WtBootstrapCache -State $State -PlatformKey $Key                     # -> tag v1.0.0
Invoke-WtBootstrapLaunch -EntryPoint <stub>                                # -> exit code 0, no arguments
```

```
selected asset      : WindowsTweaker-linux-x64-v1.0.0.zip [linux-x64] size=6081462
checksum            : verified (786e7a69eb991223830177ba7edcd8aed8a801d7e5428a3b38ed79a49f44ffdf)
staged + validated  : /tmp/wt-e2e/state/release-v1.0.0 (platform linux-x64, worker worker/bin/linux-amd64/wt-worker)
cache lookup        : tag=v1.0.0 staging=/tmp/wt-e2e/state/release-v1.0.0
STUB-ENTRY args=0
launch exit code    : 0
```

And the entry block itself, executed as text through `iex` in a child `pwsh` (the `irm | iex`
path), against the real GitHub API:

```
=== A. no release published yet: metadata 404 must fail loudly, nothing launched ===
Write-Error: Could not resolve release metadata: HTTP 404 for https://api.github.com/repos/88kbleirad/WindowsTweaker/releases/latest.
LASTEXITCODE=1
SESSION-ALIVE

=== B. validated cache + unreachable metadata: explicit offline launch ===
STUB-ENTRY args=0
LASTEXITCODE=0
SESSION-ALIVE
```

Case A is what a user running the documented one-liner gets today: a named failure and an intact
session. Case B shows the offline branch launching only the staged, validated release, with the
entry point started bare (no `-WhatIf`, no `-Id`, no preset): opening the interface applies no
tweak. The transport hop in this rehearsal was replaced by a local read of the generated archive;
the HTTP transport is covered by section 12's live redirect test, and the combination has **not**
been run end to end, because that needs a published release.

The launch step itself was also driven inside a real pty (`python3` + `pty.openpty()`, the same
harness section 6 uses), with an entry point that reports what it inherited and then reads one key:

```powershell
'ENTRY-INPUT-REDIRECTED=' + [Console]::IsInputRedirected
'ENTRY-ARG-COUNT=' + $Args.Count
'ENTRY-KEY=' + [Console]::ReadKey($true).KeyChar
```

```
ENTRY-INPUT-REDIRECTED=False
ENTRY-ARG-COUNT=0
ENTRY-KEY=q
```

The launched interface therefore inherits the caller's terminal standard input (not redirected, so
the child did not get a pipe) and can read keys, while receiving no arguments at all.

## 13. Multi-runtime compatibility (executed statically; 5.1 host not available)

```bash
pwsh -NoProfile -File tools/Test-Compatibility.ps1
```

```
5.1 syntax (src, bootstrap, tools, tests)      0 finding(s)
5.1 commands/parameters and .NET types         0 finding(s)
Non-ASCII files with a UTF-8 BOM               58 of 58
Entry point requirement                        #Requires -Version 5.1
Module manifest floor                          PowerShellVersion 5.1, editions Desktop/Core
Published launcher encoding                    BOM absent, non-ASCII bytes 0
Published launcher text parses                 0 error(s) in the text the one-liner passes to iex
Bootstrap pair protocol                        launcher 1, implementation 1
Bootstrap runtime policy                       runtime profile present
HTTP accessors available on .NET Framework     0 synchronous HttpContent accessor call(s)
System.Net.Http loaded where HttpClient is used 0 file(s) missing the assembly load

COMPATIBILITY GATE PASSED
```

The gate is phase 5 of `tools/Invoke-Validation.ps1`. It runs PSScriptAnalyzer's own Windows
PowerShell 5.1 compatibility rules (`PSUseCompatibleSyntax` with `TargetVersions 5.1`,
`PSUseCompatibleCommands` and `PSUseCompatibleTypes` against the published profile
`win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework`) over every shipped script,
and separately asserts the properties the rules cannot see:

* every source file containing non-ASCII text carries a UTF-8 BOM (5.1 decodes a BOM-less file
  with the ANSI code page);
* the published launcher is pure ASCII with no BOM, its text parses, and both bootstrap files
  declare the same launcher protocol (section 14);
* no shipped file calls a synchronous `HttpContent` accessor, and any file that constructs
  `[System.Net.Http.HttpClient]` loads `System.Net.Http` first (section 15).

Development tooling and the test suite are gated for syntax only, because they run on the
validated PowerShell 7 runtime.

Before the port, the same gate reported 14 command/parameter findings (twelve
`ConvertFrom-Json -Depth`, one `-AsHashtable`, one parameter-binding defect) and 18 .NET type
findings (`System.Text.Json` x13, `RuntimeInformation.OSArchitecture`/`OSDescription` x4,
`File.SetUnixFileMode`); the audit table in [COMPATIBILITY.md](COMPATIBILITY.md) lists every
finding and its resolution, including the differences the rules cannot see (BOM handling, console
APIs, process plumbing).

Executed alongside it:

| Area | Evidence |
|---|---|
| Compatibility layer unit tests | `tests/Compatibility.Tests.ps1`: profile and tier, capability list with reasons, BOM-less UTF-8 read/write, JSON escaping normalisation (`\uXXXX`, surrogate pairs, escaped backslashes), `-AsHashtable` shape, handoff-command quoting, manifest/entry-point floor, BOM policy over the tree, EN/VI runtime strings |
| Bootstrap runtime policy | `tests/Bootstrap.Tests.ps1`: 5.1 accepted, 4.0 refused, tested range 7.4-<7.7 only, preview never selected, probe-not-filename discovery, PATH-first selection, loop prevention (handoff marker, depth, native mode), `pwsh`-mode refusal with manual instructions, winget-absent/consent/decline/failure paths, re-discovery after install, argument quoting with spaces/quotes/trailing backslashes, working directory and environment inheritance, error classification |
| Catalogue strictness without `System.Text.Json` | `tests/Catalog.Tests.ps1`, `tests/Insight.Tests.ps1`, `tests/Loading.Tests.ps1`, `tools/Test-Catalog.ps1` |
| Worker protocol on the 5.1 path | `tests/Worker.Tests.ps1` (handshake, round trip, Vietnamese path, garbage line, cooperative shutdown) with the client's own UTF-8 `StreamWriter` |
| Terminal interface regression | `tests/Tui.Tests.ps1`, `tests/InsightTui.Tests.ps1` after the VT/encoding changes |
| Release archive still valid after the port | Section 11: four archives, 146 file hashes each, worker handshake |

**Executed on PowerShell 7.6.9 (Linux) only.** The public one-liner was run end to end on Linux
against the published `v1.0.0` release (section 14), but nothing in this section was executed on a
Windows PowerShell 5.1 host. The rows that therefore remain unproven are listed in
[COMPATIBILITY.md](COMPATIBILITY.md) ("What remains unverified"): 5.1 console/VT/code-page
behaviour, 7.4/7.5, Windows-only providers, the WPF window, `winget` itself, and
`irm | iex` in a Windows console.

## 14. Public bootstrap command: BOM parse failure and the launcher split (executed)

**Reported.** The documented one-liner on Windows PowerShell 5.1:

```powershell
irm "https://raw.githubusercontent.com/88kbleirad/WindowsTweaker/main/bootstrap/bootstrap.ps1" | iex
```

```
At line:84 char:1
Unexpected attribute 'CmdletBinding'.
Unexpected token 'param' in expression or statement.
... one "the assignment expression is not valid" per parameter default below it
```

**Root cause.** The published file was a single 5.1-parseable script carrying a UTF-8 BOM (needed
so 5.1 decodes its Vietnamese messages with UTF-8, not the ANSI code page). `irm` hands the
response body to `iex` as a *string*; the BOM decodes to a leading `U+FEFF`, and the parser then
refuses the body's own `[CmdletBinding()] param(...)` block. Measured with the parser on
PowerShell 7.6.9:

| Text given to the parser | Source | Parse errors |
|---|---|---|
| the body as the transport delivers it (first char `U+FEFF`) | UTF-8 decode of the published bytes | **4**, first at line 84: `Unexpected attribute 'CmdletBinding'.` |
| the same text with the marker removed | `$text.Substring(1)` | **0** |
| `Get-Content -Raw` of the same file | the cmdlet strips the BOM | **0** |
| the same bytes decoded as Latin-1 (`ï»¿` prefix) | a transport without the charset | **4**, same messages and lines |

The failure also reproduces through the real mechanism, `irm` over HTTP into `iex`:

```
ParseException: At line:84 char:1
    line 84 col 1: Unexpected attribute 'CmdletBinding'.
    line 85 col 1: Unexpected token 'param' in expression or statement.
    line 87 col 98: The assignment expression is not valid. ...
    line 91 col 102: The assignment expression is not valid. ...
```

A file-level parse (`ParseFile`, `Get-Content -Raw`) never reaches that state, which is why the
suite did not catch it: the failing input is the *text* the one-liner builds, not the file.

**Fix.** Two files, each with one encoding job:

| File | Encoding | Job |
|---|---|---|
| `bootstrap/bootstrap.ps1` | pure ASCII, **no BOM** | Published launcher: runtime floor, implementation bytes (the file beside it, or the pinned HTTPS URL), explicit UTF-8 decode with a leading `U+FEFF` removed, parse + launcher-protocol check, script-block invocation in a child scope with every option forwarded, `$LASTEXITCODE` mirrored, no `exit()`, nothing emitted. |
| `bootstrap/implementation.ps1` | UTF-8 **with BOM** | The previous installer, unchanged in behaviour: release selection, HTTPS/host/hash verification, staging, runtime discovery and handoff, launch, terminal cleanup. |

Both declare `$Script:WtBootstrapLauncherProtocol = 1`; a mismatch is refused as `INTEGRITY:` with
the remedy (re-run the documented one-liner). `tools/Test-Compatibility.ps1` now fails the build if
the launcher gains a BOM or a non-ASCII byte, if the text it serves does not parse, or if the two
files disagree about the protocol.

**Executed here (Linux, PowerShell 7.6.9)**

| Check | Evidence |
|---|---|
| published body parsed as text, exactly as `irm` delivers it | 4 errors, first `line 84: Unexpected attribute 'CmdletBinding'.`; the same text without the marker: 0 errors |
| fixed launcher through `irm | iex` (local HTTP fixture, no `$PSScriptRoot`) | implementation loaded, the release URL refused → `NETWORK:` error, `$LASTEXITCODE` = 1, 0 `*WtBootstrap*` functions left behind, session alive |
| launcher as a file (`pwsh -NoProfile -File bootstrap/bootstrap.ps1`) | real GitHub metadata, `v1.0.0` asset downloaded, SHA-256 verified against `checksums.txt`, staged, interface opened in a real pty (header rendered, Vietnamese UI) |
| implementation content decoded with and without a leading `U+FEFF` | identical text, marker absent, 0 parse errors (`tests/Bootstrap.Tests.ps1`) |
| protocol mismatch and unparseable implementation | refused as `INTEGRITY:` before anything runs |
| option forwarding launcher → implementation | all seven options arrive with the caller's values; the launcher itself emits nothing |
| file execution does not download the implementation | the sibling file is used; the implementation URL is never requested |
| the whole public chain (Linux) | `releases/latest` → asset → hash → staging → interface, against the published `v1.0.0` |

**Release package.** The published archive's own `manifest.json` (downloaded by the fixed launcher)
lists 146 files - `WindowsTweaker.ps1`, `PSScriptAnalyzerSettings.psd1`, `THIRD-PARTY-NOTICES.md`,
`src/WindowsTweaker/**`, `licenses/**`, the platform worker and the manifest itself - and **no
`bootstrap/` entry**. The bootstrap files are served from `main`, so this fix changes no published
asset and needs no new release; tag and release `v1.0.0` were left untouched.

**Not executed.** `irm | iex` on a Windows host: no Windows PowerShell 5.1 host and no Windows host
was available. The 5.1 report above is a user report, reproduced here on PowerShell 7.6.9 with the
identical error text and line numbers - the parser behaviour is the same on both, but that is an
inference for 5.1, not a measurement. The fixed body can only be tested against the public URL
after it is merged to `main`; the opt-in live tests (`WT_BOOTSTRAP_LIVE_TEST=1`) fetch the
published launcher and implementation and assert the same properties remotely.

## 15. Windows PowerShell 5.1 HTTP content access: the synchronous accessor (executed)

**Reported.** After the launcher split (section 14), a 5.1 run failed while downloading:

```
LAUNCH: Method invocation failed because [System.Net.Http.StreamContent] does not contain a method named 'ReadAsStream'.
```

**Root cause.** Both download helpers read the response body with
`$Response.Content.ReadAsStream()`. That member is .NET 5+; Windows PowerShell 5.1 runs on .NET
Framework, whose `HttpContent` exposes only `ReadAsStreamAsync()`, `ReadAsStringAsync()` and
`ReadAsByteArrayAsync()`. The exception was raised inside the download and carried no
classification, so the entry point reported it as `LAUNCH:` without naming the stage.

**Fix.**

* `bootstrap/implementation.ps1`: `Get-WtBootstrapContent` delegates the body to
  `Read-WtBootstrapContentBytes`, which awaits
  `$Content.ReadAsStreamAsync().GetAwaiter().GetResult()` - the parameterless overload; the
  `CancellationToken` overload is not used because its availability on the .NET Framework build is
  not guaranteed. It enforces the byte bound **while** reading, disposes the body stream and the
  buffer on every path, and classifies failures as `NETWORK: ... while opening/reading the
  response body ...`, or `INTEGRITY` for the bound. The whole client block is wrapped so an
  unexpected failure there becomes `NETWORK: Download of <url> failed: <original message>` instead
  of `LAUNCH`. The release-metadata JSON parse is classified `PACKAGE`.
* `bootstrap/bootstrap.ps1`: the same reader for the implementation download
  (`Read-WtBootstrapLauncherContentBytes`) with the same classification. It is a deliberate second
  copy: the launcher has to work before the implementation exists.
* `src/WindowsTweaker/Private/Observability/PromData.ps1`: `[System.Net.Http.HttpClient]::new()`
  cannot be resolved on 5.1 until `System.Net.Http` is loaded ("Unable to find type"); both call
  sites now call `Initialize-WtPromHttpClient` first. Its existing
  `ReadAsStreamAsync().GetAwaiter().GetResult()` was already 5.1-safe.

Unchanged: bounded size, 30 s client timeout, TLS 1.2 scoped to the request with the previous
value restored, manual redirect/allowed-host validation, same-release SHA-256 verification, the
`.complete` staging marker, and disposal of the response, request and client on every path.

**Executed here (Linux, PowerShell 7.6.9)**

| Check | Evidence |
|---|---|
| real `HttpContent` (256 KiB `ByteArrayContent`) through both readers | returned bytes hash-equal to the input |
| the size bound while reading | `INTEGRITY: ... exceeds the 1024 byte limit` from both readers |
| a real HTTP exchange over a socket (ephemeral `TcpListener`, `Connection: close`) through `Read-WtBootstrapContentBytes` | 256 KiB body streamed and hash-equal; a second response with `-MaxBytes 4096` refused as `INTEGRITY` |
| the launcher's real HTTPS download of the published body | body fetched and decoded; refused as `INTEGRITY: ... declares launcher protocol 0` (the pre-merge body), not a `ReadAsStream` failure |
| the whole chain with the real downloader | `releases/latest` → asset and `checksums.txt` → SHA-256 verified → staged → launch attempted |
| the static gate rules | negative-tested, see below |

`tools/Test-Compatibility.ps1` now fails the build when a shipped file calls a synchronous
`HttpContent` accessor (AST-level, so the explanatory comments that name the missing member do not
trip it) or constructs `[System.Net.Http.HttpClient]` without loading `System.Net.Http`. Both rules
were exercised against the defective shapes: re-adding `.ReadAsStream()` reported
`bootstrap.ps1:183 ReadAsStream()`, and a probe file constructing `HttpClient` without the
assembly load was reported by name. Both probes were removed again.

**Not executed.** The streaming tests on Windows PowerShell 5.1: no Windows host was available, so
the 5.1 failure is a user report and every check above ran on 7.6.9. The tests are deliberately
runtime-agnostic - a real `HttpContent` and a real socket, never a mock of the failing member - so
they are the check to run on a 5.1 host, together with the opt-in live test, which drives the whole
downloader over the real transport on whichever runtime runs it:

```powershell
$env:WT_BOOTSTRAP_LIVE_TEST = '1'
powershell.exe -NoProfile -Command "Invoke-Pester -Path ./tests/Bootstrap.Tests.ps1 -Output Detailed"
```

**Patch release.** `ModuleVersion` is now `1.0.1`, and the packages were rebuilt locally with
`tools/New-ReleasePackage.ps1 -Version 1.0.1` (four archives, 146 file hashes each, worker
handshake; `engineVersion` 1.0.1 in both manifests, `ModuleVersion` 1.0.1 inside each archive).
The published `v1.0.0` release and its tag were not touched, and nothing was pushed or published.

## Not executed here (Windows-only integration checks)

The declarative definitions added to `Data/Catalog/builtin.json` are in the same position as the
rest of the catalog: their structure, detection maps, operations and target identities are checked,
and reading the values back on a live Windows 11 build is **not** among the executed checks. Their
evidence blocks say `Unverified` for that reason.

These are **not** validated by this archive and must be run in a disposable Windows VM
before relying on them:

1. Any real mutation: registry writes/removals, service start type and state, scheduled
   task enable/disable, firewall group changes, per-adapter DNS changes, DoH registry
   values, Appx removal, Defender preference changes, DISM feature/capability changes,
   `powercfg` and `Checkpoint-Computer`.
2. Rollback against a real registry: value kinds (DWord/QWord/ExpandString/Binary/
   MultiString), unnamed values written through `[Microsoft.Win32.Registry]`, recursive
   key deletion and its bounded capture.
3. The terminal interface on Windows: conhost without virtual terminal support (the
   `[Console]` API renderer), legacy code pages (the ASCII frame fallback), a real
   `Ctrl+C` through the console, and the Vietnamese layout in a Windows console font.
   The icon modes were validated in a Linux pty only: the appearance of the `NerdFont`
   private-use glyphs in a patched Windows font, and the alignment of the ambiguous-width
   Unicode symbols (`◆`, `○`, `△`, `■`) in a Windows console font that renders them as
   double-width, were **not** observed here.
4. The WPF interface: rendering, layout, icons, the package/adapter picker dialogs, and
   the background apply runspace.
5. Windows-only module availability through `-UseWindowsPowerShell` (Appx, DISM) and the
   accuracy of the dependency checks that use it. `Get-WtWindowsFeature` /
   `Get-WtWindowsCapability` therefore returned an empty list here by design (they report
   the honest "cannot read the list" case instead of failing).
6. Installer paths: `Get-WtVerifiedDownload` publisher validation and the exit-code
   checks of `Invoke-WtProcess` with real installers.
7. Windows 10 22H2 versus Windows 11 differences in the tweaks that declare
   `-SupportedOS`/`-MinBuild`.
8. Cancelling a *native* operation that is already in flight (DISM, `Remove-AppxPackage`):
   the cooperative contract is tested (queued items are dropped, the running item
   finishes), but the Windows-side behaviour of those tools could not be observed.
9. PSScriptAnalyzer's `-Recommended` rule set on Windows PowerShell compatibility
   surfaces (the run above used the checked-in settings file).

## Reproducing the cut-over checks

The legacy tree (`modules\*.ps1`, 117 files) was removed only after every file was
accounted for in `docs/migration-notes/` (migrated, already covered, dropped or
"not ported" with a reason) - verified mechanically by scanning the notes for each
module name before deletion (117 of 117 named in both `docs/FEATURE-INVENTORY.md` and
`docs/migration-notes/`). The tree is no longer in the working copy; the deleted files
remain reachable through the git history of the initial revision.
`docs/FEATURE-INVENTORY.md` contains the resulting mapping, the interfaces, the shipped
presets and the explicit "not ported" list.

## How the new surfaces are validated

* **Structural validation**: `tools/Parse-All.ps1` (every loadable file parses), `tools/Test-Catalog.ps1`
  (catalog invariants), `tools/Test-Insight.ps1` (the sanity rules, the exclusive groups and the
  recommendation links as cross-document invariants - including that a rule's remediation link
  points back at a repair that names that rule's own finding), `tools/Invoke-Validation.ps1`
  (the harness above, now with the insight invariants as phase 3), and the schema/loader
  anti-drift assertions in `tests/Catalog.Tests.ps1`.
* **Mocked behaviour**: `tests/Insight.Tests.ps1` runs the engine against a registry double and
  mocked probes (scan outcomes, recommendation gates, dimension evidence, boundary verdicts,
  pending-restart marker states, group current states). `tests/InsightTui.Tests.ps1` drives the
  real terminal interface head-lessly through the injectable key source: filter typing vs.
  shortcuts, objective cycling, export validation, replacement of a pending alternative and
  bilingual rendering. `tests/Journal.Tests.ps1` covers the store version guards.
* **Real Windows read-back**: not executed on this Linux host. The providers, the boundary probes
  and the `bcdedit` read are real code paths that require a Windows session; they are exercised
  only through fakes here and belong in a disposable Windows VM.
* **Observed runtime effect**: none is claimed. No test asserts a performance or behaviour change.
