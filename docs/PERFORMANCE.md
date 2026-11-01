# TUI performance: architecture, diagnostics and regression evidence

This document describes how the terminal interface's input-to-render path is measured,
what was changed to keep typing/navigation responsive, and how to reproduce the numbers
on a given host.

## What the path is

```
key (console) → Read-WtConsoleKey → ConvertTo-WtKey → Invoke-WtTuiKey (handler)
      → marks the screen dirty → next frame: Update-WtTuiView builds the whole grid
      → Write-WtScreen / Write-WtScreenPlain writes rows to the terminal
```

Everything except the terminal write happens in one runspace. Long apply/rollback work
runs in the worker runspace; the monitor view collects its own bounded samples on the
frame loop.

## What was changed

* **Row-level diff rendering.** The cell grid is remembered ($ previous frame (cells +
  styles per row). A writer now emits only rows that actually differ, and the plain
  (Windows PowerShell 5.1 / classic console) renderer writes each changed row as one
  buffered segment per style run instead of one per cell. An unchanged frame writes
  nothing at all. Ctrl+L (`ForceRepaint`) and resize reset the diff so the next frame is
  complete.
* **No repaint when nothing changed.** Arrow presses at the list edge, selecting the
  category you are already on, and re-setting the same status text no longer mark the
  screen dirty. Unknown keys never do.
* **Key batching.** The main loop and the monitor loop render at most once per step and
  drain the key queue in a bounded batch before the next render, so held-arrow autorepeat
  coalesces hundreds of key events into a handful of frames. No key is dropped; a modal
  overlay or a started operation interrupts the batch so the screen reflects the new mode
  immediately.
* **Bounded provider work in the overview.** The drift/interrupted counts shown on the
  Overview pane used to be recomputed on every paint of that pane; they are now cached and
  refreshed at most every five seconds (and invalidated by any catalog refresh).
* **Bounded performance diagnostics.** An opt-in, in-memory ring of the last 1024
  samples records dispatch/handler/frame-build/frame-output durations and writes a summary
  (median/p95/max, frame counts, process CPU share) to the structured log at exit. It never
  records typed text.

## Enabling the diagnostics (English / Vietnamese)

English:

```powershell
# Start the interface with diagnostics and a summary at exit:
Start-WtTui -PerfDiagnostics
# or
$env:WT_TUI_PERF_DIAGNOSTICS = '1'
.\WindowsTweaker.ps1
# The summary appears in the structured log (logs/wt-<date>.jsonl):
#   TUI performance: frames=... painted=... idle=...
#   TUI performance (ms): dispatch median=... p95=... max=...
#   TUI performance handler (ms): ...
#   TUI performance frame build (ms): ...
#   TUI performance frame output (ms): ...
#   TUI performance rows written per painted frame: ...
#   TUI performance process CPU: ...%
```

Tiếng Việt:

```powershell
# Bật chẩn đoán hiệu năng khi mở giao diện, có tóm tắt khi thoát:
Start-WtTui -PerfDiagnostics
# hoặc
$env:WT_TUI_PERF_DIAGNOSTICS = '1'
.\WindowsTweaker.ps1
# Tóm tắt nằm trong nhật ký có cấu trúc (logs/wt-<date>.jsonl):
#   TUI performance: frames=... painted=... idle=...
#   TUI performance (ms): dispatch median=... p95=... max=...
#   TUI performance handler (ms): ...
#   TUI performance frame build (ms): ...
#   TUI performance frame output (ms): ...
#   TUI performance rows written per painted frame: ...
#   TUI performance process CPU: ...%
```

The numbers are milliseconds of application processing time. They are **not** physical
key-to-display latency: that depends on the terminal, the console font and the input
hardware, which the diagnostics do not and cannot measure.

## Reproducing the render benchmark

`tools/Bench-TuiRender.ps1` measures the four writer variants on one machine (the legacy
all-rows ANSI and per-cell plain renderers compared with the current diff-based ones), with
console output redirected to a sink:

```powershell
pwsh -NoProfile -File tools/Bench-TuiRender.ps1 -Iterations 300 -Width 120 -Height 40
```

Executed on this Linux workstation (PowerShell 7.6.9, 120×40 grid, 300 iterations):

| Scenario | Writer | Median ms | p95 ms | Max ms |
|---|---|---|---|---|
| navigation | legacy ansi (all rows) | 3.24 | 4.36 | 15.76 |
| navigation | current ansi (diff) | 0.44 | 0.89 | 1.73 |
| navigation | legacy plain (per-cell) | 1.58 | 2.60 | 14.03 |
| navigation | current plain (segments+diff) | 0.45 | 1.19 | 1.85 |
| static | legacy ansi (all rows) | 2.18 | 2.83 | 3.31 |
| static | current ansi (diff) | 0.34 | 0.87 | 1.45 |
| static | legacy plain (per-cell) | 1.47 | 2.12 | 2.51 |
| static | current plain (segments+diff) | 0.33 | 0.82 | 1.05 |

About 7× faster for the ANSI path and 3.5–4.5× for the plain/classic-console path, and a
static frame (nothing changed) now writes nothing at all. Limit: the sink is not a real
Windows console; the syscall cost of a physical terminal is excluded, so absolute numbers
on the user's Windows console will be higher. The relative improvements transfer because
the same writer code paths are measured against their verbatim predecessors.

## Regression tests

`tests/TuiRender.Tests.ps1` covers:

* first-write/identical-frame/mutated-row behavior of both writers (byte-level for ANSI,
  written-row counters for plain),
* row-level invalidation and the forced-repaint reset,
* key batching: 12 queued arrows reach the handler in one step with few renders, no key
  dropped, and Escape/Enter survive a batch,
* the overview drift/interrupted cache cadence,
* the bounded performance-diagnostics ring and percentile computation.

Windows-specific checks (real classic console, Windows PowerShell 5.1 writing path) are not
executed on this Linux host and are marked **not executed** in the validation report.
