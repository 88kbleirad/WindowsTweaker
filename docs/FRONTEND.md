# WindowsTweaker frontend (WinUI 3)

The native desktop frontend replaces the console as the primary interactive surface while
the terminal interface (TUI) and the CLI stay fully supported. The frontend is a WinUI 3
app on .NET 10; the engine remains the PowerShell module, and the two halves talk through
a versioned structured bridge.

## Layout

```
gui/
  src/
    WindowsTweaker.Gui.Core/          presentation-independent half (builds and tests on Linux)
      Bridge/                         BridgeSession (stdio JSON-lines client), PowerShellLocator,
                                      ProcessElevation (UAC handoff)
      Model/                          typed projections of protocol payloads (Projections.cs)
      Protocol/                       BridgeFrame parsing + ProtocolConstants (shared values)
      ViewModels/                     ShellViewModel + per-workspace view models
    WindowsTweaker.WinUI/             native window: XAML, styles, App, MainWindow
  tests/WindowsTweaker.Gui.Core.Tests/  xUnit suite (bridge protocol + live backend tests)
src/WindowsTweaker/
  Bridge/wt-bridge.ps1                backend host process (stdin/stdout JSON-lines server)
  Private/Bridge/BridgeProtocol.ps1   protocol, bounds, allowlist, key contract
  Private/Bridge/BridgeTasks.ps1      background runspace task runner
  Private/Bridge/BridgeDto.ps1        DTO projections (flat, bounded frames)
  Data/Strings.{en,vi}.gui.psd1       frontend string tables (merged with the terminal tables)
```

## Runtime requirements (verified against official Microsoft documentation, 2026-11)

| Component | Choice | Evidence |
|---|---|---|
| .NET | 10 (LTS), `net10.0` | SDK 10.0.403 used for all builds in this repository |
| Windows App SDK | **1.8.260921001** (latest stable 1.8 servicing; NuGet) | 1.8 line supports Windows 10 1809+ through Windows 11 26H2, incl. Windows 11 IoT Enterprise LTSC 2024 (build 26100) |
| Windows SDK BuildTools | 10.0.26100.4654 | dependency floor of WinAppSDK 1.8.260921001 (NU1605 verified at restore) |
| Target OS | Windows 10 1809+; primary target Windows 11 IoT Enterprise LTSC 2024 (build 26100) | Windows App SDK supported-releases table |
| MSIX | Release configuration packages; Debug runs unpackaged (`WindowsPackageType=None`) | single-project MSIX |

Why not the Windows App SDK 2.x line (2.6.4, current stable as of 2026-10)? 2.x has the
same OS floor and is a valid drop-in upgrade, but this repository has no Windows build
environment to validate a major runtime bump, and the 1.8 line is the servicing baseline
this app was authored against. The upgrade is a one-line package bump, documented in
[BUILD-WINUI.md](BUILD-WINUI.md).

Windows 11 IoT Enterprise LTSC 2024 (build 26100) is inside every supported range: it is a
Windows 11 24H2 LTSC SKU, and the Windows App SDK supports Windows 11 24H2 with LTSC
mainstream servicing through 2029-10-09.

## The bridge protocol (v1)

The frontend never touches the engine directly. It spawns one long-lived backend process
(`wt-bridge.ps1`) that imports the module once and reuses the session for the whole window
life:

- **stdout is the protocol channel only** — one JSON object per line, UTF-8, LF-terminated.
  Nothing else is ever written to stdout; diagnostics (host banner, stderr lines) go to a
  separate channel and never appear in protocol frames.
- **Requests**: `{ "id": "<client-generated>", "op": "<allowlisted op>", "args": {...} }`.
  The allowlist is a closed table in `BridgeProtocol.ps1`; a request whose op is not a key
  is refused before anything runs. Args are validated typed parameters — no command string
  is ever built from user input.
- **Frames**: `hello` (handshake), `result`, `error`, `progress`, `notice`.
- **Bounds**: 8 MiB max frame, 8 pending requests, 500 task events, per-operation timeouts.
- **Cancellation**: `cancel` requests a cooperative stop at the operation's next safe
  boundary; a mutation is never aborted mid-flight.
- **Crash detection**: process exit fails every pending request and raises `Exited`; the UI
  reports the exit code instead of hanging on timeouts.

The client half (`BridgeSession.cs`) implements the same contract with stale-response
protection (a late answer is dropped, never mis-delivered), per-request deadlines, and a
clean shutdown that asks the backend to `quit`, waits for it to drain tasks, and only kills
after a grace period.

The handshake proves version agreement: client and backend both speak protocol 1, and a
mismatch fails startup with `ProtocolMismatch`.

## Engine guarantees preserved

The frontend never re-implements journal or verification rules. It calls the engine's
public API through the bridge and renders the engine's structured answers:

- Dependency/conflict previews (`preview.get`, `plan.get`).
- Reviewed-state revalidation at apply time (`apply.batch` re-checks; the review dialog
  states this).
- Durable baseline capture before mutation, journal locking, read-back verification and
  compensation — all inside `Invoke-WtTweak` / `Undo-WtTweak`, untouched by the frontend.
- External-tool outcomes are separate from reversible tweaks: the licensing workspace says
  so before acting, and the engine writes no journal record for MAS activation.
- Pending selections, running operations, results and history are four distinct state
  slots in the view models and are never merged.

## Elevation

Opening the window and browsing diagnostics never require elevation (`asInvoker` in
app.manifest). Privileged operations (slmgr, restore point, restart) are refused by the
backend with `RequiresElevation` when the backend session is not elevated. The user can
then relaunch the app itself elevated via the header button: the current copy shuts its
backend down cleanly (never killing a mutation), starts an elevated child with `Verb =
RunAs` (the OS shows the UAC prompt), and exits. The child discovers the engine from the
same root, starts a fresh backend session, and the handshake proves the elevation. No
unrestricted command endpoint exists: the allowlist is the only operation surface in both
processes.

## Localization

The frontend keeps no translation of its own — it renders whatever the engine's merged
string tables say (`strings.get`). The handshake serves the key list so a missing table
entry is detectable instead of rendering empty. `Strings.{en,vi}.gui.psd1` add the
frontend vocabulary; tests enforce that every frontend key exists in every merged table.

## Integration status (honest)

Implemented end to end:

- Overview (environment, catalog counts, pending, interrupted).
- Tweaks with search, category filter, supported-only filter, details pane, staging.
- Review (pending list, per-item preview with conflicts, dry run, apply, result table).
- History (history, journal, interrupted operations, restore).
- Diagnostics (report, directory scan, monitoring cycle, devices, power, privacy,
  quarantine, setup plans — raw structured answers rendered read-only).
- Licensing (status, activation methods, external-tool download/remove/activate, slmgr).

Bridge-supported but **not yet surfaced in the window** (exist in the terminal UI and in
the bridge allowlist, and are not claimed as done here): presets (`preset.list`/`load`),
sanity scan and recommendations UIs, choice groups, monitoring dashboards/metrics
(`dashboard.*`, `metrics.range`), and restore-point creation. The `restart.invoke` op is
not exposed either: the cancellable restart countdown stays a console-TUI feature; the
window performs applies without auto-restart and reports any restart requirement the
engine returns. The bridge's closed allowlist is what these would call, so no engine work
is needed to add them.

Not done at all: no telemetry, no decorative animation, no fake metrics — the window
renders only what the engine reports.

## See also

- [BUILD-WINUI.md](BUILD-WINUI.md) — prerequisites, build, packaging, run.
- [VALIDATION.md](VALIDATION.md) — what was executed and what still needs a Windows host.
- [`docs/KEYBOARD.md`](KEYBOARD.md) — the terminal interface's keys (the window preserves
  the non-conflicting essentials: arrows, Tab/Shift+Tab, Enter, Escape, search, F5).
